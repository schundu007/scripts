#!/usr/bin/env bash
#===============================================================================
# Azure AKS Elasticsearch Deployment Script
# Deploys: AKS Cluster, Nginx Ingress, Cert-Manager, Elasticsearch 8.x
# Prerequisites: Azure CLI, kubectl, helm installed and authenticated
# Last Updated: December 2025
#===============================================================================
set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:-}"
AKS_RG="${AKS_RG:-schundu-es-rg}"
AKS_CLUSTER="${AKS_CLUSTER:-schundu-es-aks}"
AKS_ACR="${AKS_ACR:-schunduacr}"
AKS_PIP="${AKS_PIP:-schundu-es-pip}"
DNS_LABEL="${DNS_LABEL:-schundues}"
LOCATION="${LOCATION:-centralus}"
NAMESPACE="${NAMESPACE:-elasticsearch}"
CONTACT_EMAIL="${CONTACT_EMAIL:-admin@example.com}"

# Latest Stable Versions (as of December 2025)
ES_VERSION="8.17.0"
CERT_MANAGER_VERSION="v1.17.2"
INGRESS_NGINX_VERSION="4.14.1"
K8S_VERSION="1.32"

# AKS Node Configuration
NODE_COUNT=3
NODE_VM_SIZE="Standard_D4s_v5"

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
    for cmd in az kubectl helm; do check_command "$cmd"; ok "$cmd found"; done
    [[ -z "$SUBSCRIPTION" ]] && { err "Set AZURE_SUBSCRIPTION_ID"; exit 1; }
    ok "All prerequisites validated"
}

#-------------------------------------------------------------------------------
# Resource Group
#-------------------------------------------------------------------------------
create_resource_group() {
    section "Resource Group: $AKS_RG"
    az group show --name "$AKS_RG" &>/dev/null && ok "Exists" || { az group create --name "$AKS_RG" --location "$LOCATION" -o none; ok "Created"; }
}

#-------------------------------------------------------------------------------
# Container Registry
#-------------------------------------------------------------------------------
create_container_registry() {
    section "Container Registry: $AKS_ACR"
    az acr show --name "$AKS_ACR" &>/dev/null && ok "Exists" || { az acr create --resource-group "$AKS_RG" --name "$AKS_ACR" --sku Basic -o none; ok "Created"; }
}

#-------------------------------------------------------------------------------
# Register Providers
#-------------------------------------------------------------------------------
register_providers() {
    section "Registering Azure Providers"
    for p in Microsoft.OperationsManagement Microsoft.OperationalInsights Microsoft.ContainerService; do
        [[ $(az provider show -n "$p" --query "registrationState" -o tsv 2>/dev/null) == "Registered" ]] && ok "$p" || { az provider register -n "$p" --wait; ok "$p registered"; }
    done
}

#-------------------------------------------------------------------------------
# AKS Cluster
#-------------------------------------------------------------------------------
create_aks_cluster() {
    section "AKS Cluster: $AKS_CLUSTER"
    if az aks show --resource-group "$AKS_RG" --name "$AKS_CLUSTER" &>/dev/null; then
        ok "Exists"
    else
        log "Creating cluster (5-10 min)..."
        az aks create \
            --resource-group "$AKS_RG" \
            --name "$AKS_CLUSTER" \
            --node-count "$NODE_COUNT" \
            --node-vm-size "$NODE_VM_SIZE" \
            --kubernetes-version "$K8S_VERSION" \
            --enable-managed-identity \
            --enable-addons monitoring \
            --enable-cluster-autoscaler \
            --min-count 3 --max-count 10 \
            --network-plugin azure \
            --network-policy azure \
            --generate-ssh-keys \
            --attach-acr "$AKS_ACR" \
            --zones 1 2 3 \
            --os-sku AzureLinux \
            --tier standard \
            -o none
        ok "Created"
    fi
    az aks get-credentials --resource-group "$AKS_RG" --name "$AKS_CLUSTER" --overwrite-existing
    kubectl get nodes -o wide
}

#-------------------------------------------------------------------------------
# Public IP
#-------------------------------------------------------------------------------
create_public_ip() {
    section "Public IP: $AKS_PIP"
    AKS_NODE_RG=$(az aks show --resource-group "$AKS_RG" --name "$AKS_CLUSTER" --query nodeResourceGroup -o tsv)
    if az network public-ip show --resource-group "$AKS_NODE_RG" --name "$AKS_PIP" &>/dev/null; then
        ok "Exists"
    else
        az network public-ip create --resource-group "$AKS_NODE_RG" --name "$AKS_PIP" --dns-name "$DNS_LABEL" --sku Standard --allocation-method Static --zone 1 2 3 -o none
        ok "Created"
    fi
    AKS_PUBLIC_IP=$(az network public-ip show --resource-group "$AKS_NODE_RG" --name "$AKS_PIP" --query ipAddress -o tsv)
    DNS_FQDN=$(az network public-ip show --resource-group "$AKS_NODE_RG" --name "$AKS_PIP" --query dnsSettings.fqdn -o tsv)
    log "IP: $AKS_PUBLIC_IP | FQDN: $DNS_FQDN"
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
            --set controller.service.loadBalancerIP="$AKS_PUBLIC_IP" \
            --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"="$DNS_LABEL" \
            --set controller.service.externalTrafficPolicy=Local \
            --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
            --set controller.metrics.enabled=true
        ok "Installed"
    fi
    sleep 30
    kubectl get svc nginx-ingress-ingress-nginx-controller -n "$NAMESPACE"
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
    ES_PASSWORD=$(openssl rand -base64 24)
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
            --set volumeClaimTemplate.storageClassName=managed-csi-premium \
            --set volumeClaimTemplate.resources.requests.storage=100Gi \
            --set nodeSelector."kubernetes\.io/os"=linux \
            --set antiAffinity=hard \
            --set esJavaOpts="-Xmx2g -Xms2g" \
            --set secret.enabled=true \
            --set secret.password="$ES_PASSWORD" \
            --set protocol=https \
            --set createCert=true
        ok "Installed"
    fi
    log "Waiting for ES pods..."
    sleep 60
    wait_for_pods "$NAMESPACE" "app=elasticsearch-master" 300
}

#-------------------------------------------------------------------------------
# Ingress
#-------------------------------------------------------------------------------
create_ingress() {
    section "Creating Ingress"
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
    ok "Created"
}

#-------------------------------------------------------------------------------
# Wait for Certificate
#-------------------------------------------------------------------------------
wait_for_certificate() {
    section "Waiting for TLS Certificate"
    for i in {1..60}; do
        [[ $(kubectl get certificate elasticsearch-tls -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == "True" ]] && { ok "Ready"; return 0; }
        log "Waiting... ($i/60)"
        sleep 10
    done
    warn "Certificate may still be provisioning"
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
    section "Deployment Complete"
    echo -e "${G}Elasticsearch Cluster:${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  URL:      ${C}https://$DNS_FQDN${N}"
    echo -e "  User:     ${C}elastic${N}"
    echo -e "  Password: ${C}$ES_PASSWORD${N}"
    echo -e "\n${Y}Save credentials securely!${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test: curl -k -u elastic:\$ES_PASSWORD https://$DNS_FQDN"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Azure AKS Elasticsearch Deployment"
    echo "  Versions: K8s $K8S_VERSION | ES $ES_VERSION | cert-manager $CERT_MANAGER_VERSION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    az account set --subscription "$SUBSCRIPTION"
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

main "$@"
