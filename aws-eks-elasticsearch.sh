#!/usr/bin/env bash
#===============================================================================
# AWS EKS Elasticsearch Deployment Script
# Deploys: EKS Cluster, Nginx Ingress, Cert-Manager, Elasticsearch 8.x
# Prerequisites: AWS CLI v2, kubectl, helm, eksctl installed
# Last Updated: December 2025
#===============================================================================
set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")}"
CLUSTER_NAME="${CLUSTER_NAME:-schundu-es-cluster}"
ECR_REPO="${ECR_REPO:-schundu-elasticsearch}"
NAMESPACE="${NAMESPACE:-elasticsearch}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
CONTACT_EMAIL="${CONTACT_EMAIL:-admin@example.com}"

# Latest Stable Versions (as of December 2025)
ES_VERSION="8.17.0"
CERT_MANAGER_VERSION="v1.17.2"
INGRESS_NGINX_VERSION="4.14.1"
AWS_LB_CONTROLLER_VERSION="v2.10.0"
EKS_VERSION="1.32"

# EKS Node Configuration
NODE_INSTANCE_TYPE="m6i.xlarge"
NODE_COUNT_MIN=3
NODE_COUNT_MAX=10
NODE_VOLUME_SIZE=100

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
log()  { echo -e "${C}[INFO]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERROR]${N} $*" >&2; }
section() { echo -e "\n${C}=== $* ===${N}\n"; }
check_command() { command -v "$1" &>/dev/null || { err "$1 required"; exit 1; }; }
wait_for_pods() { kubectl wait --for=condition=ready pod -l "$2" -n "$1" --timeout="${3:-300}s" 2>/dev/null || kubectl get pods -n "$1" -l "$2"; }

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
validate_prerequisites() {
    section "Validating Prerequisites"
    for cmd in aws kubectl helm eksctl jq; do check_command "$cmd"; ok "$cmd found"; done
    aws sts get-caller-identity &>/dev/null || { err "AWS credentials not configured"; exit 1; }
    [[ -z "$AWS_ACCOUNT_ID" ]] && { err "Could not get AWS Account ID"; exit 1; }
    log "Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION"
    ok "All prerequisites validated"
}

#-------------------------------------------------------------------------------
# ECR Repository
#-------------------------------------------------------------------------------
create_ecr_repository() {
    section "ECR Repository: $ECR_REPO"
    if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" &>/dev/null; then
        ok "Exists"
    else
        aws ecr create-repository --repository-name "$ECR_REPO" --region "$AWS_REGION" --image-scanning-configuration scanOnPush=true --encryption-configuration encryptionType=AES256 --output text
        ok "Created"
    fi
}

#-------------------------------------------------------------------------------
# EKS Cluster
#-------------------------------------------------------------------------------
create_eks_cluster() {
    section "EKS Cluster: $CLUSTER_NAME"
    if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        ok "Exists"
    else
        log "Creating cluster (15-20 min)..."
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
    version: latest
    attachPolicyARNs:
      - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: aws-ebs-csi-driver
    version: latest
    wellKnownPolicies:
      ebsCSIController: true
managedNodeGroups:
  - name: schundu-es-nodes
    instanceType: $NODE_INSTANCE_TYPE
    minSize: $NODE_COUNT_MIN
    maxSize: $NODE_COUNT_MAX
    desiredCapacity: $NODE_COUNT_MIN
    volumeSize: $NODE_VOLUME_SIZE
    volumeType: gp3
    volumeEncrypted: true
    amiFamily: AmazonLinux2023
    labels:
      role: elasticsearch
    tags:
      Environment: production
    iam:
      withAddonPolicies:
        ebs: true
        cloudWatch: true
EOF
        ok "Created"
    fi
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
    kubectl get nodes -o wide
}

#-------------------------------------------------------------------------------
# Storage Class
#-------------------------------------------------------------------------------
create_storage_class() {
    section "Creating GP3 Storage Class"
    if kubectl get storageclass gp3 &>/dev/null; then
        ok "Exists"
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
        ok "Created"
        kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
    fi
}

#-------------------------------------------------------------------------------
# AWS Load Balancer Controller
#-------------------------------------------------------------------------------
install_aws_lb_controller() {
    section "Installing AWS Load Balancer Controller $AWS_LB_CONTROLLER_VERSION"
    local policy_name="AWSLoadBalancerControllerIAMPolicy"
    local sa_name="aws-load-balancer-controller"
    
    if ! aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" &>/dev/null; then
        log "Creating IAM policy..."
        curl -sL "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${AWS_LB_CONTROLLER_VERSION}/docs/install/iam_policy.json" -o /tmp/iam_policy.json
        aws iam create-policy --policy-name "$policy_name" --policy-document file:///tmp/iam_policy.json --output text
        ok "IAM policy created"
    fi
    
    if ! kubectl get serviceaccount "$sa_name" -n kube-system &>/dev/null; then
        eksctl create iamserviceaccount --cluster "$CLUSTER_NAME" --namespace kube-system --name "$sa_name" --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" --approve --region "$AWS_REGION"
        ok "Service account created"
    fi
    
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    
    if helm status aws-load-balancer-controller -n kube-system &>/dev/null; then
        ok "Already installed"
    else
        helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
            --namespace kube-system \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=false \
            --set serviceAccount.name="$sa_name" \
            --set region="$AWS_REGION" \
            --set vpcId="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
        ok "Installed"
    fi
    wait_for_pods "kube-system" "app.kubernetes.io/name=aws-load-balancer-controller" 120
}

#-------------------------------------------------------------------------------
# Namespace
#-------------------------------------------------------------------------------
create_namespace() {
    section "Namespace: $NAMESPACE"
    kubectl get namespace "$NAMESPACE" &>/dev/null && ok "Exists" || { kubectl create namespace "$NAMESPACE"; ok "Created"; }
    kubectl config set-context --current --namespace="$NAMESPACE"
}

#-------------------------------------------------------------------------------
# Nginx Ingress (Note: ingress-nginx retiring March 2026, consider Gateway API)
#-------------------------------------------------------------------------------
install_nginx_ingress() {
    section "Installing Nginx Ingress $INGRESS_NGINX_VERSION"
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    if helm status nginx-ingress -n "$NAMESPACE" &>/dev/null; then
        ok "Already installed"
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
            --set controller.metrics.enabled=true
        ok "Installed"
    fi
    
    log "Waiting for NLB..."
    sleep 60
    NLB_HOSTNAME=""
    for i in {1..30}; do
        NLB_HOSTNAME=$(kubectl get svc nginx-ingress-ingress-nginx-controller -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        [[ -n "$NLB_HOSTNAME" ]] && break
        log "Waiting for NLB hostname... ($i/30)"
        sleep 10
    done
    [[ -z "$NLB_HOSTNAME" ]] && { err "Failed to get NLB hostname"; exit 1; }
    ok "NLB: $NLB_HOSTNAME"
}

#-------------------------------------------------------------------------------
# Cert-Manager
#-------------------------------------------------------------------------------
install_cert_manager() {
    section "Installing Cert-Manager $CERT_MANAGER_VERSION"
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    if helm status cert-manager -n "$NAMESPACE" &>/dev/null; then
        ok "Already installed"
    else
        helm install cert-manager jetstack/cert-manager \
            --namespace "$NAMESPACE" \
            --version "$CERT_MANAGER_VERSION" \
            --set crds.enabled=true \
            --set nodeSelector."kubernetes\.io/os"=linux \
            --set webhook.nodeSelector."kubernetes\.io/os"=linux \
            --set cainjector.nodeSelector."kubernetes\.io/os"=linux
        ok "Installed"
    fi
    wait_for_pods "$NAMESPACE" "app.kubernetes.io/instance=cert-manager" 120
    
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
          ingressClassName: nginx
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
    
    ES_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    if kubectl get secret elasticsearch-credentials -n "$NAMESPACE" &>/dev/null; then
        ES_PASSWORD=$(kubectl get secret elasticsearch-credentials -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
    else
        kubectl create secret generic elasticsearch-credentials --namespace "$NAMESPACE" --from-literal=username=elastic --from-literal=password="$ES_PASSWORD"
        ok "Credentials secret created"
    fi
    
    if helm status elasticsearch -n "$NAMESPACE" &>/dev/null; then
        ok "Already installed"
    else
        helm install elasticsearch elastic/elasticsearch \
            --namespace "$NAMESPACE" \
            --version "$ES_VERSION" \
            --set replicas=3 \
            --set minimumMasterNodes=2 \
            --set resources.requests.cpu=1000m \
            --set resources.requests.memory=2Gi \
            --set resources.limits.cpu=2000m \
            --set resources.limits.memory=4Gi \
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
        ok "Installed"
    fi
    log "Waiting for ES pods..."
    sleep 90
    wait_for_pods "$NAMESPACE" "app=elasticsearch-master" 600
}

#-------------------------------------------------------------------------------
# Ingress
#-------------------------------------------------------------------------------
create_ingress() {
    section "Creating Ingress"
    local es_host="${DOMAIN_NAME:+es.$DOMAIN_NAME}"
    es_host="${es_host:-$NLB_HOSTNAME}"
    
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: elasticsearch-ingress
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
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
    ok "Created for: $es_host"
}

#-------------------------------------------------------------------------------
# Wait for Certificate
#-------------------------------------------------------------------------------
wait_for_certificate() {
    section "Checking TLS Certificate"
    [[ -z "$DOMAIN_NAME" ]] && { warn "No custom domain. Using self-signed cert."; return 0; }
    for i in {1..60}; do
        [[ $(kubectl get certificate elasticsearch-tls -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == "True" ]] && { ok "Ready"; return 0; }
        log "Waiting... ($i/60)"
        sleep 10
    done
    warn "Certificate may still be provisioning"
}

#-------------------------------------------------------------------------------
# Verify
#-------------------------------------------------------------------------------
verify_elasticsearch() {
    section "Verifying Elasticsearch"
    kubectl port-forward svc/elasticsearch-master 9200:9200 -n "$NAMESPACE" &
    local pf_pid=$!
    sleep 5
    curl -sk -u "elastic:$ES_PASSWORD" https://localhost:9200/_cluster/health?pretty && ok "Cluster healthy" || warn "Verify manually"
    kill $pf_pid 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
    section "Deployment Complete"
    local es_host="${DOMAIN_NAME:+es.$DOMAIN_NAME}"
    es_host="${es_host:-$NLB_HOSTNAME}"
    
    echo -e "${G}Elasticsearch Cluster:${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Region:   ${C}$AWS_REGION${N}"
    echo -e "  Cluster:  ${C}$CLUSTER_NAME${N}"
    echo -e "  NLB:      ${C}$NLB_HOSTNAME${N}"
    echo -e "  ES URL:   ${C}https://$es_host${N}"
    echo -e "  User:     ${C}elastic${N}"
    echo -e "  Password: ${C}$ES_PASSWORD${N}"
    echo -e "\n${Y}Save credentials securely!${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test: kubectl port-forward svc/elasticsearch-master 9200:9200 -n $NAMESPACE"
    echo "      curl -sk -u elastic:\$ES_PASSWORD https://localhost:9200/_cluster/health"
}

#-------------------------------------------------------------------------------
# Cleanup
#-------------------------------------------------------------------------------
cleanup() {
    section "Cleanup"
    read -rp "Delete all resources? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { log "Cancelled"; return; }
    helm uninstall elasticsearch cert-manager nginx-ingress -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
    kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
    eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
    ok "Cleanup complete"
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
    echo "Usage: $0 [deploy|cleanup|help]"
    echo ""
    echo "Environment Variables:"
    echo "  AWS_REGION     Region (default: us-west-2)"
    echo "  CLUSTER_NAME   Cluster name (default: schundu-es-cluster)"
    echo "  DOMAIN_NAME    Custom domain (optional)"
    echo "  CONTACT_EMAIL  Let's Encrypt email"
    echo ""
    echo "Example: AWS_REGION=us-east-1 $0 deploy"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local cmd="${1:-deploy}"
    case "$cmd" in
        deploy)
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  AWS EKS Elasticsearch Deployment"
            echo "  Versions: K8s $EKS_VERSION | ES $ES_VERSION | cert-manager $CERT_MANAGER_VERSION"
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
        cleanup) cleanup ;;
        help|--help|-h) show_help ;;
        *) err "Unknown: $cmd"; show_help; exit 1 ;;
    esac
}

main "$@"
