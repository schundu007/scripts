#!/usr/bin/env bash
#===============================================================================
# Azure AKS Elasticsearch Deployment Script
# Deploys: AKS Cluster, Nginx Ingress, Cert-Manager, Elasticsearch 8.x
# Prerequisites: Azure CLI, kubectl, helm installed and authenticated
#===============================================================================
set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration - Modify these values
#-------------------------------------------------------------------------------
SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:-}"  # Set via env or modify here
AKS_RG="${AKS_RG:-osdu-mvp-es-rg}"
AKS_CLUSTER="${AKS_CLUSTER:-osdu-mvp-es-aks}"
AKS_ACR="${AKS_ACR:-osdumvpesacr}"
AKS_PIP="${AKS_PIP:-osdu-mvp-es-pip}"
DNS_LABEL="${DNS_LABEL:-osdues}"
LOCATION="${LOCATION:-centralus}"
NAMESPACE="${NAMESPACE:-elasticsearch}"
CONTACT_EMAIL="${CONTACT_EMAIL:-admin@example.com}"  # For Let's Encrypt

# Versions
ES_VERSION="8.12.2"
CERT_MANAGER_VERSION="v1.14.4"
INGRESS_NGINX_VERSION="4.10.0"

# AKS Node Configuration
NODE_COUNT=3
NODE_VM_SIZE="Standard_D4s_v3"  # Upgraded for ES requirements
K8S_VERSION="1.29"

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
    kubectl wait --for=condition=ready pod -l "$label" -n "$ns" --timeout="${timeout}s"
}

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
validate_prerequisites() {
    section "Validating Prerequisites"
    
    for cmd in az kubectl helm; do
        check_command "$cmd"
        ok "$cmd found"
    done
    
    if [[ -z "$SUBSCRIPTION" ]]; then
        err "AZURE_SUBSCRIPTION_ID environment variable not set"
        echo "Usage: AZURE_SUBSCRIPTION_ID=<sub-id> $0"
        exit 1
    fi
    
    if [[ ! -f "$HOME/.ssh/id_rsa.pub" ]] && [[ ! -f "$HOME/.ssh/id_ed25519.pub" ]]; then
        err "SSH public key not found in ~/.ssh/"
        exit 1
    fi
    
    # Determine SSH key path
    SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
    [[ -f "$HOME/.ssh/id_ed25519.pub" ]] && SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    
    ok "All prerequisites validated"
}

#-------------------------------------------------------------------------------
# Azure Resource Group
#-------------------------------------------------------------------------------
create_resource_group() {
    section "Resource Group: $AKS_RG"
    
    if az group show --name "$AKS_RG" &>/dev/null; then
        ok "Resource group $AKS_RG already exists"
    else
        log "Creating resource group..."
        az group create --name "$AKS_RG" --location "$LOCATION" -o none
        ok "Resource group created"
    fi
}

#-------------------------------------------------------------------------------
# Azure Container Registry
#-------------------------------------------------------------------------------
create_container_registry() {
    section "Container Registry: $AKS_ACR"
    
    if az acr show --name "$AKS_ACR" &>/dev/null; then
        ok "ACR $AKS_ACR already exists"
    else
        log "Creating container registry..."
        az acr create \
            --resource-group "$AKS_RG" \
            --name "$AKS_ACR" \
            --sku Basic \
            -o none
        ok "Container registry created"
    fi
}

#-------------------------------------------------------------------------------
# Register Azure Providers
#-------------------------------------------------------------------------------
register_providers() {
    section "Registering Azure Providers"
    
    local providers=("Microsoft.OperationsManagement" "Microsoft.OperationalInsights" "Microsoft.ContainerService")
    
    for provider in "${providers[@]}"; do
        local status
        status=$(az provider show -n "$provider" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
        
        if [[ "$status" == "Registered" ]]; then
            ok "$provider already registered"
        else
            log "Registering $provider..."
            az provider register -n "$provider" --wait
            ok "$provider registered"
        fi
    done
}

#-------------------------------------------------------------------------------
# AKS Cluster
#-------------------------------------------------------------------------------
create_aks_cluster() {
    section "AKS Cluster: $AKS_CLUSTER"
    
    if az aks show --resource-group "$AKS_RG" --name "$AKS_CLUSTER" &>/dev/null; then
        ok "AKS cluster $AKS_CLUSTER already exists"
    else
        log "Creating AKS cluster (this may take 5-10 minutes)..."
        az aks create \
            --resource-group "$AKS_RG" \
            --name "$AKS_CLUSTER" \
            --node-count "$NODE_COUNT" \
            --node-vm-size "$NODE_VM_SIZE" \
            --kubernetes-version "$K8S_VERSION" \
            --enable-managed-identity \
            --enable-addons monitoring \
            --enable-cluster-autoscaler \
            --min-count 3 \
            --max-count 10 \
            --network-plugin azure \
            --network-policy azure \
            --generate-ssh-keys \
            --attach-acr "$AKS_ACR" \
            --zones 1 2 3 \
            -o none
        ok "AKS cluster created"
    fi
    
    log "Getting cluster credentials..."
    az aks get-credentials --resource-group "$AKS_RG" --name "$AKS_CLUSTER" --overwrite-existing
    
    log "Cluster nodes:"
    kubectl get nodes -o wide
}

#-------------------------------------------------------------------------------
# Public IP
#-------------------------------------------------------------------------------
create_public_ip() {
    section "Public IP: $AKS_PIP"
    
    AKS_NODE_RG=$(az aks show --resource-group "$AKS_RG" --name "$AKS_CLUSTER" --query nodeResourceGroup -o tsv)
    log "Node resource group: $AKS_NODE_RG"
    
    if az network public-ip show --resource-group "$AKS_NODE_RG" --name "$AKS_PIP" &>/dev/null; then
        ok "Public IP $AKS_PIP already exists"
    else
        log "Creating public IP..."
        az network public-ip create \
            --resource-group "$AKS_NODE_RG" \
            --name "$AKS_PIP" \
            --dns-name "$DNS_LABEL" \
            --sku Standard \
            --allocation-method Static \
            --zone 1 2 3 \
            -o none
        ok "Public IP created"
    fi
    
    AKS_PUBLIC_IP=$(az network public-ip show --resource-group "$AKS_NODE_RG" --name "$AKS_PIP" --query ipAddress -o tsv)
    DNS_FQDN=$(az network public-ip show --resource-group "$AKS_NODE_RG" --name "$AKS_PIP" --query dnsSettings.fqdn -o tsv)
    
    log "Public IP: $AKS_PUBLIC_IP"
    log "DNS FQDN: $DNS_FQDN"
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
            --set controller.service.loadBalancerIP="$AKS_PUBLIC_IP" \
            --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"="$DNS_LABEL" \
            --set controller.service.externalTrafficPolicy=Local \
            --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
            --set controller.metrics.enabled=true \
            --set controller.podAnnotations."prometheus\.io/scrape"=true \
            --set controller.podAnnotations."prometheus\.io/port"=10254
        ok "Nginx Ingress installed"
    fi
    
    log "Waiting for ingress controller..."
    sleep 30
    kubectl get services nginx-ingress-ingress-nginx-controller -n "$NAMESPACE"
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
    
    # Create Elasticsearch credentials secret
    ES_PASSWORD=$(openssl rand -base64 24)
    
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
            --set volumeClaimTemplate.storageClassName=managed-premium \
            --set volumeClaimTemplate.resources.requests.storage=100Gi \
            --set nodeSelector."kubernetes\.io/os"=linux \
            --set antiAffinity=hard \
            --set esJavaOpts="-Xmx2g -Xms2g" \
            --set secret.enabled=true \
            --set secret.password="$ES_PASSWORD" \
            --set protocol=https \
            --set createCert=true
        ok "Elasticsearch installed"
    fi
    
    log "Waiting for Elasticsearch pods (this may take 2-3 minutes)..."
    sleep 60
    wait_for_pods "$NAMESPACE" "app=elasticsearch-master" 300
    
    kubectl get pods -n "$NAMESPACE" -l app=elasticsearch-master
}

#-------------------------------------------------------------------------------
# Ingress for Elasticsearch
#-------------------------------------------------------------------------------
create_ingress() {
    section "Creating Ingress for Elasticsearch"
    
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
    - $DNS_FQDN
    secretName: elasticsearch-tls
  rules:
  - host: $DNS_FQDN
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
    ok "Ingress created"
}

#-------------------------------------------------------------------------------
# Wait for Certificate
#-------------------------------------------------------------------------------
wait_for_certificate() {
    section "Waiting for TLS Certificate"
    
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
    
    err "Certificate not ready after $max_attempts attempts"
    kubectl describe certificate elasticsearch-tls -n "$NAMESPACE"
    exit 1
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
    section "Deployment Complete"
    
    echo -e "${G}Elasticsearch Cluster Details:${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Cluster URL:    ${C}https://$DNS_FQDN${N}"
    echo -e "  Username:       ${C}elastic${N}"
    echo -e "  Password:       ${C}$ES_PASSWORD${N}"
    echo ""
    echo -e "${Y}Save these credentials securely!${N}"
    echo ""
    echo "Test connectivity:"
    echo "  curl -k -u elastic:\$ES_PASSWORD https://$DNS_FQDN"
    echo ""
    echo "Port-forward for local access:"
    echo "  kubectl port-forward svc/elasticsearch-master 9200:9200 -n $NAMESPACE"
    echo ""
    echo "View pods:"
    echo "  kubectl get pods -n $NAMESPACE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Azure AKS Elasticsearch Deployment"
    echo "  $(date)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    az account set --subscription "$SUBSCRIPTION"
    log "Using subscription: $(az account show --query name -o tsv)"
    
    validate_prerequisites
    register_providers
    create_resource_group
    create_container_registry
    create_aks_cluster
    create_public_ip
    create_namespace
    install_nginx_ingress
    install_cert_manager
    install_elasticsearch
    create_ingress
    wait_for_certificate
    print_summary
}

# Run
main "$@"
