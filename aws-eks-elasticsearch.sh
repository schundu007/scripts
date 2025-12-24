#!/usr/bin/env bash
#===============================================================================
# AWS EKS Elasticsearch Deployment Script
# Deploys: EKS Cluster, Nginx Ingress, Cert-Manager, Elasticsearch 8.x
# Prerequisites: AWS CLI v2, kubectl, helm, eksctl installed and configured
#===============================================================================
set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration - Modify these values
#-------------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")}"
CLUSTER_NAME="${CLUSTER_NAME:-es-cluster}"
ECR_REPO="${ECR_REPO:-elasticsearch-custom}"
NAMESPACE="${NAMESPACE:-elasticsearch}"
DOMAIN_NAME="${DOMAIN_NAME:-}"  # Optional: your-domain.com
CONTACT_EMAIL="${CONTACT_EMAIL:-admin@example.com}"

# Versions
ES_VERSION="8.12.2"
CERT_MANAGER_VERSION="v1.14.4"
INGRESS_NGINX_VERSION="4.10.0"
EKS_VERSION="1.29"

# EKS Node Configuration
NODE_INSTANCE_TYPE="m5.xlarge"
NODE_COUNT_MIN=3
NODE_COUNT_MAX=10
NODE_VOLUME_SIZE=100

#-------------------------------------------------------------------------------
# Colors & Helpers
#-------------------------------------------------------------------------------
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
log()  { echo -e "${C}[INFO]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERROR]${N} $*" >&2; }
section() { echo -e "\n${C}=== $* ===${N}\n"; }

check_command() {
    command -v "$1" &>/dev/null || { err "$1 is required but not installed"; exit 1; }
}

wait_for_pods() {
    local ns=$1 label=$2 timeout=${3:-300}
    log "Waiting for pods with label $label in namespace $ns..."
    kubectl wait --for=condition=ready pod -l "$label" -n "$ns" --timeout="${timeout}s" 2>/dev/null || {
        warn "Timeout waiting for pods, checking status..."
        kubectl get pods -n "$ns" -l "$label"
    }
}

retry() {
    local max_attempts=$1; shift
    local delay=$1; shift
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi
        log "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
        sleep "$delay"
        ((attempt++))
    done
    return 1
}

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
validate_prerequisites() {
    section "Validating Prerequisites"
    
    for cmd in aws kubectl helm eksctl jq; do
        check_command "$cmd"
        ok "$cmd found"
    done
    
    # Validate AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        err "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi
    
    if [[ -z "$AWS_ACCOUNT_ID" ]]; then
        err "Could not determine AWS Account ID"
        exit 1
    fi
    
    log "AWS Account: $AWS_ACCOUNT_ID"
    log "AWS Region: $AWS_REGION"
    
    ok "All prerequisites validated"
}

#-------------------------------------------------------------------------------
# ECR Repository
#-------------------------------------------------------------------------------
create_ecr_repository() {
    section "ECR Repository: $ECR_REPO"
    
    if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" &>/dev/null; then
        ok "ECR repository $ECR_REPO already exists"
    else
        log "Creating ECR repository..."
        aws ecr create-repository \
            --repository-name "$ECR_REPO" \
            --region "$AWS_REGION" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 \
            --output text
        ok "ECR repository created"
    fi
}

#-------------------------------------------------------------------------------
# EKS Cluster
#-------------------------------------------------------------------------------
create_eks_cluster() {
    section "EKS Cluster: $CLUSTER_NAME"
    
    if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        ok "EKS cluster $CLUSTER_NAME already exists"
    else
        log "Creating EKS cluster (this may take 15-20 minutes)..."
        
        cat <<EOF | eksctl create cluster -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER_NAME
  region: $AWS_REGION
  version: "$EKS_VERSION"

iam:
  withOIDC: true

vpc:
  nat:
    gateway: HighlyAvailable
  clusterEndpoints:
    publicAccess: true
    privateAccess: true

addons:
  - name: vpc-cni
    attachPolicyARNs:
      - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
    wellKnownPolicies:
      ebsCSIController: true

managedNodeGroups:
  - name: es-nodes
    instanceType: $NODE_INSTANCE_TYPE
    minSize: $NODE_COUNT_MIN
    maxSize: $NODE_COUNT_MAX
    desiredCapacity: $NODE_COUNT_MIN
    volumeSize: $NODE_VOLUME_SIZE
    volumeType: gp3
    volumeEncrypted: true
    amiFamily: AmazonLinux2
    labels:
      role: elasticsearch
    tags:
      Environment: production
      Application: elasticsearch
    iam:
      withAddonPolicies:
        ebs: true
        cloudWatch: true
EOF
        ok "EKS cluster created"
    fi
    
    log "Updating kubeconfig..."
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
    
    log "Cluster nodes:"
    kubectl get nodes -o wide
}

#-------------------------------------------------------------------------------
# Storage Class
#-------------------------------------------------------------------------------
create_storage_class() {
    section "Creating GP3 Storage Class"
    
    if kubectl get storageclass gp3 &>/dev/null; then
        ok "Storage class gp3 already exists"
    else
        cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  fsType: ext4
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
        ok "Storage class gp3 created"
        
        # Remove default from gp2 if exists
        kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
    fi
}

#-------------------------------------------------------------------------------
# AWS Load Balancer Controller
#-------------------------------------------------------------------------------
install_aws_lb_controller() {
    section "Installing AWS Load Balancer Controller"
    
    local policy_name="AWSLoadBalancerControllerIAMPolicy"
    local sa_name="aws-load-balancer-controller"
    
    # Check if policy exists
    if ! aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" &>/dev/null; then
        log "Creating IAM policy..."
        curl -sL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json -o /tmp/iam_policy.json
        aws iam create-policy \
            --policy-name "$policy_name" \
            --policy-document file:///tmp/iam_policy.json \
            --output text
        ok "IAM policy created"
    else
        ok "IAM policy already exists"
    fi
    
    # Create service account with IAM role
    if ! kubectl get serviceaccount "$sa_name" -n kube-system &>/dev/null; then
        log "Creating IAM service account..."
        eksctl create iamserviceaccount \
            --cluster "$CLUSTER_NAME" \
            --namespace kube-system \
            --name "$sa_name" \
            --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" \
            --approve \
            --region "$AWS_REGION"
        ok "IAM service account created"
    else
        ok "IAM service account already exists"
    fi
    
    # Install controller via Helm
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    
    if helm status aws-load-balancer-controller -n kube-system &>/dev/null; then
        ok "AWS Load Balancer Controller already installed"
    else
        helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
            --namespace kube-system \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=false \
            --set serviceAccount.name="$sa_name" \
            --set region="$AWS_REGION" \
            --set vpcId="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
        ok "AWS Load Balancer Controller installed"
    fi
    
    wait_for_pods "kube-system" "app.kubernetes.io/name=aws-load-balancer-controller" 120
}

#-------------------------------------------------------------------------------
# Namespace
#-------------------------------------------------------------------------------
create_namespace() {
    section "Namespace: $NAMESPACE"
    
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        ok "Namespace $NAMESPACE already exists"
    else
        kubectl create namespace "$NAMESPACE"
        ok "Namespace created"
    fi
    
    kubectl config set-context --current --namespace="$NAMESPACE"
}

#-------------------------------------------------------------------------------
# Nginx Ingress Controller
#-------------------------------------------------------------------------------
install_nginx_ingress() {
    section "Installing Nginx Ingress Controller"
    
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    if helm status nginx-ingress -n "$NAMESPACE" &>/dev/null; then
        ok "Nginx Ingress already installed"
    else
        helm install nginx-ingress ingress-nginx/ingress-nginx \
            --namespace "$NAMESPACE" \
            --version "$INGRESS_NGINX_VERSION" \
            --set controller.replicaCount=2 \
            --set controller.nodeSelector."kubernetes\.io/os"=linux \
            --set controller.admissionWebhooks.patch.nodeSelector."kubernetes\.io/os"=linux \
            --set controller.service.type=LoadBalancer \
            --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
            --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
            --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"=true \
            --set controller.service.externalTrafficPolicy=Local \
            --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
            --set controller.metrics.enabled=true \
            --set controller.podAnnotations."prometheus\.io/scrape"=true \
            --set controller.podAnnotations."prometheus\.io/port"=10254
        ok "Nginx Ingress installed"
    fi
    
    log "Waiting for NLB to be provisioned..."
    sleep 60
    
    # Get Load Balancer hostname
    NLB_HOSTNAME=""
    for i in {1..30}; do
        NLB_HOSTNAME=$(kubectl get svc nginx-ingress-ingress-nginx-controller -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [[ -n "$NLB_HOSTNAME" ]]; then
            break
        fi
        log "Waiting for NLB hostname... ($i/30)"
        sleep 10
    done
    
    if [[ -z "$NLB_HOSTNAME" ]]; then
        err "Failed to get NLB hostname"
        kubectl get svc nginx-ingress-ingress-nginx-controller -n "$NAMESPACE"
        exit 1
    fi
    
    ok "NLB Hostname: $NLB_HOSTNAME"
}

#-------------------------------------------------------------------------------
# Cert-Manager
#-------------------------------------------------------------------------------
install_cert_manager() {
    section "Installing Cert-Manager $CERT_MANAGER_VERSION"
    
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    if helm status cert-manager -n "$NAMESPACE" &>/dev/null; then
        ok "Cert-Manager already installed"
    else
        helm install cert-manager jetstack/cert-manager \
            --namespace "$NAMESPACE" \
            --version "$CERT_MANAGER_VERSION" \
            --set installCRDs=true \
            --set nodeSelector."kubernetes\.io/os"=linux \
            --set webhook.nodeSelector."kubernetes\.io/os"=linux \
            --set cainjector.nodeSelector."kubernetes\.io/os"=linux
        ok "Cert-Manager installed"
    fi
    
    wait_for_pods "$NAMESPACE" "app.kubernetes.io/instance=cert-manager" 120
    
    log "Creating ClusterIssuer for Let's Encrypt..."
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $CONTACT_EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
          podTemplate:
            spec:
              nodeSelector:
                kubernetes.io/os: linux
EOF
    ok "ClusterIssuer created"
}

#-------------------------------------------------------------------------------
# Elasticsearch
#-------------------------------------------------------------------------------
install_elasticsearch() {
    section "Installing Elasticsearch $ES_VERSION"
    
    helm repo add elastic https://helm.elastic.co
    helm repo update
    
    # Generate Elasticsearch password
    ES_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    
    if kubectl get secret elasticsearch-credentials -n "$NAMESPACE" &>/dev/null; then
        log "Elasticsearch credentials secret already exists"
        ES_PASSWORD=$(kubectl get secret elasticsearch-credentials -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
    else
        kubectl create secret generic elasticsearch-credentials \
            --namespace "$NAMESPACE" \
            --from-literal=username=elastic \
            --from-literal=password="$ES_PASSWORD"
        ok "Elasticsearch credentials secret created"
    fi
    
    if helm status elasticsearch -n "$NAMESPACE" &>/dev/null; then
        ok "Elasticsearch already installed"
    else
        helm install elasticsearch elastic/elasticsearch \
            --namespace "$NAMESPACE" \
            --version "$ES_VERSION" \
            --set replicas=3 \
            --set minimumMasterNodes=2 \
            --set clusterHealthCheckParams="wait_for_status=yellow&timeout=1s" \
            --set resources.requests.cpu=1000m \
            --set resources.requests.memory=2Gi \
            --set resources.limits.cpu=2000m \
            --set resources.limits.memory=4Gi \
            --set volumeClaimTemplate.accessModes[0]=ReadWriteOnce \
            --set volumeClaimTemplate.storageClassName=gp3 \
            --set volumeClaimTemplate.resources.requests.storage=100Gi \
            --set nodeSelector."kubernetes\.io/os"=linux \
            --set antiAffinity=hard \
            --set esJavaOpts="-Xmx2g -Xms2g" \
            --set secret.enabled=true \
            --set secret.password="$ES_PASSWORD" \
            --set protocol=https \
            --set createCert=true \
            --set podManagementPolicy=Parallel
        ok "Elasticsearch installed"
    fi
    
    log "Waiting for Elasticsearch pods (this may take 3-5 minutes)..."
    sleep 90
    wait_for_pods "$NAMESPACE" "app=elasticsearch-master" 600
    
    kubectl get pods -n "$NAMESPACE" -l app=elasticsearch-master
}

#-------------------------------------------------------------------------------
# Ingress for Elasticsearch
#-------------------------------------------------------------------------------
create_ingress() {
    section "Creating Ingress for Elasticsearch"
    
    # Determine hostname to use
    local es_host
    if [[ -n "$DOMAIN_NAME" ]]; then
        es_host="es.$DOMAIN_NAME"
    else
        es_host="$NLB_HOSTNAME"
    fi
    
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: elasticsearch-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-passthrough: "false"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - $es_host
    secretName: elasticsearch-tls
  rules:
  - host: $es_host
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: elasticsearch-master
            port:
              number: 9200
EOF
    ok "Ingress created for host: $es_host"
}

#-------------------------------------------------------------------------------
# Wait for Certificate (optional - only if using custom domain)
#-------------------------------------------------------------------------------
wait_for_certificate() {
    section "Checking TLS Certificate Status"
    
    if [[ -z "$DOMAIN_NAME" ]]; then
        warn "No custom domain configured. Skipping Let's Encrypt certificate."
        warn "Using self-signed certificate from Elasticsearch."
        return 0
    fi
    
    local max_attempts=60
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        local status
        status=$(kubectl get certificate elasticsearch-tls -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [[ "$status" == "True" ]]; then
            ok "TLS certificate is ready"
            kubectl get certificate -n "$NAMESPACE"
            return 0
        fi
        
        ((attempt++))
        log "Waiting for certificate... (attempt $attempt/$max_attempts)"
        sleep 10
    done
    
    warn "Certificate not ready after $max_attempts attempts"
    kubectl describe certificate elasticsearch-tls -n "$NAMESPACE" || true
}

#-------------------------------------------------------------------------------
# Verify Elasticsearch
#-------------------------------------------------------------------------------
verify_elasticsearch() {
    section "Verifying Elasticsearch Cluster"
    
    log "Checking cluster health via port-forward..."
    
    # Start port-forward in background
    kubectl port-forward svc/elasticsearch-master 9200:9200 -n "$NAMESPACE" &
    local pf_pid=$!
    sleep 5
    
    # Test connection
    if curl -sk -u "elastic:$ES_PASSWORD" https://localhost:9200/_cluster/health?pretty; then
        ok "Elasticsearch cluster is healthy"
    else
        warn "Could not verify cluster health"
    fi
    
    # Kill port-forward
    kill $pf_pid 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
    section "Deployment Complete"
    
    local es_host
    if [[ -n "$DOMAIN_NAME" ]]; then
        es_host="es.$DOMAIN_NAME"
    else
        es_host="$NLB_HOSTNAME"
    fi
    
    echo -e "${G}Elasticsearch Cluster Details:${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  AWS Region:     ${C}$AWS_REGION${N}"
    echo -e "  EKS Cluster:    ${C}$CLUSTER_NAME${N}"
    echo -e "  NLB Hostname:   ${C}$NLB_HOSTNAME${N}"
    echo ""
    echo -e "  Elasticsearch:"
    echo -e "    URL:          ${C}https://$es_host${N}"
    echo -e "    Username:     ${C}elastic${N}"
    echo -e "    Password:     ${C}$ES_PASSWORD${N}"
    echo ""
    echo -e "${Y}Save these credentials securely!${N}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Test connectivity (via port-forward):"
    echo "  kubectl port-forward svc/elasticsearch-master 9200:9200 -n $NAMESPACE"
    echo "  curl -sk -u elastic:\$ES_PASSWORD https://localhost:9200/_cluster/health?pretty"
    echo ""
    echo "Test via NLB (may take a few minutes for DNS propagation):"
    echo "  curl -sk -u elastic:\$ES_PASSWORD https://$NLB_HOSTNAME/_cluster/health?pretty"
    echo ""
    echo "View pods:"
    echo "  kubectl get pods -n $NAMESPACE"
    echo ""
    echo "View logs:"
    echo "  kubectl logs -f -l app=elasticsearch-master -n $NAMESPACE"
    echo ""
    
    if [[ -z "$DOMAIN_NAME" ]]; then
        echo -e "${Y}Note: No custom domain configured.${N}"
        echo "To use a custom domain:"
        echo "  1. Create a CNAME record pointing to: $NLB_HOSTNAME"
        echo "  2. Re-run with DOMAIN_NAME=yourdomain.com"
        echo ""
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

#-------------------------------------------------------------------------------
# Cleanup Function (optional)
#-------------------------------------------------------------------------------
cleanup() {
    section "Cleanup Resources"
    
    read -rp "Are you sure you want to delete all resources? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "Cleanup cancelled"
        return
    fi
    
    log "Deleting Helm releases..."
    helm uninstall elasticsearch -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall cert-manager -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall nginx-ingress -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
    
    log "Deleting namespace..."
    kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
    
    log "Deleting EKS cluster..."
    eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
    
    ok "Cleanup complete"
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy    Deploy EKS cluster and Elasticsearch (default)"
    echo "  cleanup   Delete all resources"
    echo "  help      Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  AWS_REGION       AWS region (default: us-west-2)"
    echo "  CLUSTER_NAME     EKS cluster name (default: es-cluster)"
    echo "  DOMAIN_NAME      Custom domain for TLS (optional)"
    echo "  CONTACT_EMAIL    Email for Let's Encrypt (default: admin@example.com)"
    echo ""
    echo "Example:"
    echo "  AWS_REGION=us-east-1 DOMAIN_NAME=example.com $0 deploy"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local command="${1:-deploy}"
    
    case "$command" in
        deploy)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  AWS EKS Elasticsearch Deployment"
            echo "  $(date)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            validate_prerequisites
            create_ecr_repository
            create_eks_cluster
            create_storage_class
            install_aws_lb_controller
            create_namespace
            install_nginx_ingress
            install_cert_manager
            install_elasticsearch
            create_ingress
            wait_for_certificate
            verify_elasticsearch
            print_summary
            ;;
        cleanup)
            cleanup
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            err "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Run
main "$@"
