#!/usr/bin/env bash
#===============================================================================
# Azure DevOps Infrastructure Pipeline Deployment Script
# Deploys: ADO Project, Service Connections, Variable Groups, Pipelines
# Author: Sudhakar Chundu
# Prerequisites: Azure CLI, az devops extension
# Last Updated: December 2025
#===============================================================================
set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration - Set via environment variables or modify defaults
#-------------------------------------------------------------------------------
# Required
ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-}"
ADO_ORGANIZATION="${ADO_ORGANIZATION:-}"
ADO_PROJECT="${ADO_PROJECT:-}"
ADO_PAT="${ADO_PAT:-}"

# Optional with defaults
ENVIRONMENT="${ENVIRONMENT:-dev}"
LOCATION="${LOCATION:-centralus}"
LOCATION_PAIR="${LOCATION_PAIR:-eastus2}"
DNS_NAME="${DNS_NAME:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"

# Resource naming (uses schundu prefix for public sharing)
RESOURCE_PREFIX="${RESOURCE_PREFIX:-schundu}"
SERVICE_CONNECTION_NAME="${SERVICE_CONNECTION_NAME:-${RESOURCE_PREFIX}-${ENVIRONMENT}}"

# Versions (Latest stable as of December 2025)
K8S_VERSION="${K8S_VERSION:-1.32}"
ES_VERSION="${ES_VERSION:-8.17.0}"

# Pipeline agent
AGENT_POOL="${AGENT_POOL:-Azure Pipelines}"
VM_IMAGE="${VM_IMAGE:-ubuntu-latest}"

#-------------------------------------------------------------------------------
# Colors & Logging
#-------------------------------------------------------------------------------
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1;34m' N='\033[0m'
log()     { echo -e "${C}[INFO]${N} $*"; }
ok()      { echo -e "${G}[OK]${N} $*"; }
warn()    { echo -e "${Y}[WARN]${N} $*"; }
err()     { echo -e "${R}[ERROR]${N} $*" >&2; }
section() { echo -e "\n${B}━━━ $* ━━━${N}\n"; }

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
validate_prerequisites() {
    section "Validating Prerequisites"
    
    # Check required commands
    for cmd in az jq; do
        command -v "$cmd" &>/dev/null || { err "$cmd is required"; exit 1; }
        ok "$cmd found"
    done
    
    # Check required variables
    local missing=()
    [[ -z "$ARM_SUBSCRIPTION_ID" ]] && missing+=("ARM_SUBSCRIPTION_ID")
    [[ -z "$ADO_ORGANIZATION" ]] && missing+=("ADO_ORGANIZATION")
    [[ -z "$ADO_PROJECT" ]] && missing+=("ADO_PROJECT")
    [[ -z "$ADO_PAT" ]] && missing+=("ADO_PAT")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required environment variables:"
        for var in "${missing[@]}"; do echo "  - $var"; done
        echo ""
        show_usage
        exit 1
    fi
    
    # Validate Azure login
    if ! az account show &>/dev/null; then
        log "Logging into Azure..."
        az login --output none
    fi
    
    # Set subscription
    az account set --subscription "$ARM_SUBSCRIPTION_ID"
    log "Using subscription: $(az account show --query name -o tsv)"
    
    # Install/update Azure DevOps extension
    az extension add --name azure-devops --upgrade --yes 2>/dev/null || true
    
    # Configure ADO PAT
    export AZURE_DEVOPS_EXT_PAT="$ADO_PAT"
    
    ok "All prerequisites validated"
}

show_usage() {
    cat << EOF
Usage: $0 [command]

Commands:
    deploy      Deploy infrastructure and pipelines (default)
    cleanup     Remove all created resources
    help        Show this help message

Required Environment Variables:
    ARM_SUBSCRIPTION_ID   Azure subscription ID
    ADO_ORGANIZATION      Azure DevOps organization name
    ADO_PROJECT           Azure DevOps project name
    ADO_PAT               Azure DevOps Personal Access Token

Optional Environment Variables:
    ENVIRONMENT           Environment name (default: dev)
    LOCATION              Azure region (default: centralus)
    LOCATION_PAIR         Paired region for DR (default: eastus2)
    RESOURCE_PREFIX       Resource naming prefix (default: schundu)
    GIT_BRANCH            Git branch for pipelines (default: main)

Example:
    ARM_SUBSCRIPTION_ID="xxx" \\
    ADO_ORGANIZATION="myorg" \\
    ADO_PROJECT="myproject" \\
    ADO_PAT="xxx" \\
    ENVIRONMENT="prod" \\
    $0 deploy
EOF
}

#-------------------------------------------------------------------------------
# Azure DevOps Project
#-------------------------------------------------------------------------------
create_ado_project() {
    section "Azure DevOps Project: $ADO_PROJECT"
    
    local org_url="https://dev.azure.com/${ADO_ORGANIZATION}"
    
    # Check if project exists
    if az devops project show --project "$ADO_PROJECT" --org "$org_url" &>/dev/null; then
        ok "Project already exists"
    else
        log "Creating project..."
        az devops project create \
            --name "$ADO_PROJECT" \
            --org "$org_url" \
            --source-control git \
            --visibility private \
            --output none
        ok "Project created"
    fi
    
    # Set defaults for subsequent commands
    az devops configure --defaults organization="$org_url" project="$ADO_PROJECT"
    
    # Get project ID for later use
    PROJECT_ID=$(az devops project show --project "$ADO_PROJECT" --query id -o tsv)
    log "Project ID: $PROJECT_ID"
}

#-------------------------------------------------------------------------------
# Service Connection
#-------------------------------------------------------------------------------
create_service_connection() {
    section "Service Connection: $SERVICE_CONNECTION_NAME"
    
    # Check if service connection exists
    local existing=$(az devops service-endpoint list --query "[?name=='$SERVICE_CONNECTION_NAME'].id" -o tsv 2>/dev/null || echo "")
    
    if [[ -n "$existing" ]]; then
        ok "Service connection already exists (ID: $existing)"
        SERVICE_ENDPOINT_ID="$existing"
        return
    fi
    
    # Get service principal credentials from environment or create new
    if [[ -z "${ARM_CLIENT_ID:-}" ]] || [[ -z "${ARM_CLIENT_SECRET:-}" ]] || [[ -z "${ARM_TENANT_ID:-}" ]]; then
        warn "Service principal credentials not provided"
        log "Creating new service principal..."
        
        local sp_name="sp-${RESOURCE_PREFIX}-${ENVIRONMENT}"
        local sp_output=$(az ad sp create-for-rbac \
            --name "$sp_name" \
            --role Contributor \
            --scopes "/subscriptions/$ARM_SUBSCRIPTION_ID" \
            --output json)
        
        ARM_CLIENT_ID=$(echo "$sp_output" | jq -r '.appId')
        ARM_CLIENT_SECRET=$(echo "$sp_output" | jq -r '.password')
        ARM_TENANT_ID=$(echo "$sp_output" | jq -r '.tenant')
        
        ok "Service principal created: $sp_name"
        warn "Save these credentials securely - secret shown only once!"
        echo "  Client ID: $ARM_CLIENT_ID"
        echo "  Tenant ID: $ARM_TENANT_ID"
    fi
    
    export AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY="$ARM_CLIENT_SECRET"
    
    log "Creating service connection..."
    local result=$(az devops service-endpoint azurerm create \
        --name "$SERVICE_CONNECTION_NAME" \
        --azure-rm-tenant-id "$ARM_TENANT_ID" \
        --azure-rm-subscription-id "$ARM_SUBSCRIPTION_ID" \
        --azure-rm-subscription-name "$(az account show --subscription $ARM_SUBSCRIPTION_ID --query name -o tsv)" \
        --azure-rm-service-principal-id "$ARM_CLIENT_ID" \
        --output json)
    
    SERVICE_ENDPOINT_ID=$(echo "$result" | jq -r '.id')
    
    # Allow all pipelines to use this service connection
    az devops service-endpoint update \
        --id "$SERVICE_ENDPOINT_ID" \
        --enable-for-all true \
        --output none
    
    ok "Service connection created (ID: $SERVICE_ENDPOINT_ID)"
}

#-------------------------------------------------------------------------------
# Repositories
#-------------------------------------------------------------------------------
create_repositories() {
    section "Creating Repositories"
    
    # Define repositories to create
    local repos=(
        "infra-provisioning"
        "k8s-manifests"
        "app-services"
        "shared-libraries"
    )
    
    for repo in "${repos[@]}"; do
        if az repos show --repository "$repo" &>/dev/null 2>&1; then
            ok "Repository exists: $repo"
        else
            log "Creating repository: $repo"
            az repos create --name "$repo" --output none
            ok "Created: $repo"
        fi
    done
}

#-------------------------------------------------------------------------------
# Variable Groups
#-------------------------------------------------------------------------------
create_variable_groups() {
    section "Creating Variable Groups"
    
    local org_url="https://dev.azure.com/${ADO_ORGANIZATION}"
    
    # Infrastructure Variables
    local infra_vars_name="Infrastructure Variables"
    if az pipelines variable-group list --query "[?name=='$infra_vars_name'].id" -o tsv 2>/dev/null | grep -q .; then
        ok "Variable group exists: $infra_vars_name"
    else
        log "Creating: $infra_vars_name"
        az pipelines variable-group create \
            --name "$infra_vars_name" \
            --authorize true \
            --variables \
            AGENT_POOL="$AGENT_POOL" \
            VM_IMAGE="$VM_IMAGE" \
            ARM_SUBSCRIPTION_ID="$ARM_SUBSCRIPTION_ID" \
            LOCATION="$LOCATION" \
            LOCATION_PAIR="$LOCATION_PAIR" \
            RESOURCE_PREFIX="$RESOURCE_PREFIX" \
            SERVICE_CONNECTION_NAME="$SERVICE_CONNECTION_NAME" \
            --output none
        ok "Created: $infra_vars_name"
    fi
    
    # Environment-specific Variables
    local env_vars_name="Environment Variables - ${ENVIRONMENT}"
    if az pipelines variable-group list --query "[?name=='$env_vars_name'].id" -o tsv 2>/dev/null | grep -q .; then
        ok "Variable group exists: $env_vars_name"
    else
        log "Creating: $env_vars_name"
        az pipelines variable-group create \
            --name "$env_vars_name" \
            --authorize true \
            --variables \
            ENVIRONMENT="$ENVIRONMENT" \
            TF_VAR_environment="$ENVIRONMENT" \
            TF_VAR_location="$LOCATION" \
            TF_VAR_location_pair="$LOCATION_PAIR" \
            TF_VAR_resource_prefix="$RESOURCE_PREFIX" \
            TF_VAR_kubernetes_version="$K8S_VERSION" \
            TF_VAR_elasticsearch_version="$ES_VERSION" \
            TF_VAR_aks_node_count="3" \
            TF_VAR_aks_node_vm_size="Standard_D4s_v5" \
            GIT_BRANCH="$GIT_BRANCH" \
            --output none
        ok "Created: $env_vars_name"
    fi
    
    # Terraform Backend Variables
    local tf_vars_name="Terraform Backend Variables"
    if az pipelines variable-group list --query "[?name=='$tf_vars_name'].id" -o tsv 2>/dev/null | grep -q .; then
        ok "Variable group exists: $tf_vars_name"
    else
        log "Creating: $tf_vars_name"
        az pipelines variable-group create \
            --name "$tf_vars_name" \
            --authorize true \
            --variables \
            TF_STATE_RESOURCE_GROUP="${RESOURCE_PREFIX}-tfstate-rg" \
            TF_STATE_STORAGE_ACCOUNT="${RESOURCE_PREFIX}tfstate${ENVIRONMENT}" \
            TF_STATE_CONTAINER="tfstate" \
            TF_STATE_KEY="${ENVIRONMENT}.terraform.tfstate" \
            --output none
        ok "Created: $tf_vars_name"
    fi
}

#-------------------------------------------------------------------------------
# Pipeline YAML Templates
#-------------------------------------------------------------------------------
create_pipeline_templates() {
    section "Creating Pipeline Templates"
    
    local templates_dir="/tmp/pipeline-templates"
    mkdir -p "$templates_dir"
    
    # Infrastructure Pipeline
    cat > "$templates_dir/infra-pipeline.yml" << 'YAML'
# Infrastructure Deployment Pipeline
# Deploys Azure infrastructure using Terraform

trigger:
  branches:
    include:
      - main
      - develop
  paths:
    include:
      - 'terraform/**'

pr:
  branches:
    include:
      - main

variables:
  - group: 'Infrastructure Variables'
  - group: 'Environment Variables - $(ENVIRONMENT)'
  - group: 'Terraform Backend Variables'

stages:
  - stage: Validate
    displayName: 'Validate Terraform'
    jobs:
      - job: Validate
        pool:
          vmImage: $(VM_IMAGE)
        steps:
          - task: TerraformInstaller@1
            displayName: 'Install Terraform'
            inputs:
              terraformVersion: 'latest'
          
          - task: TerraformTaskV4@4
            displayName: 'Terraform Init'
            inputs:
              provider: 'azurerm'
              command: 'init'
              workingDirectory: '$(System.DefaultWorkingDirectory)/terraform'
              backendServiceArm: '$(SERVICE_CONNECTION_NAME)'
              backendAzureRmResourceGroupName: '$(TF_STATE_RESOURCE_GROUP)'
              backendAzureRmStorageAccountName: '$(TF_STATE_STORAGE_ACCOUNT)'
              backendAzureRmContainerName: '$(TF_STATE_CONTAINER)'
              backendAzureRmKey: '$(TF_STATE_KEY)'
          
          - task: TerraformTaskV4@4
            displayName: 'Terraform Validate'
            inputs:
              provider: 'azurerm'
              command: 'validate'
              workingDirectory: '$(System.DefaultWorkingDirectory)/terraform'

  - stage: Plan
    displayName: 'Plan Infrastructure'
    dependsOn: Validate
    condition: succeeded()
    jobs:
      - job: Plan
        pool:
          vmImage: $(VM_IMAGE)
        steps:
          - task: TerraformInstaller@1
            inputs:
              terraformVersion: 'latest'
          
          - task: TerraformTaskV4@4
            displayName: 'Terraform Init'
            inputs:
              provider: 'azurerm'
              command: 'init'
              workingDirectory: '$(System.DefaultWorkingDirectory)/terraform'
              backendServiceArm: '$(SERVICE_CONNECTION_NAME)'
              backendAzureRmResourceGroupName: '$(TF_STATE_RESOURCE_GROUP)'
              backendAzureRmStorageAccountName: '$(TF_STATE_STORAGE_ACCOUNT)'
              backendAzureRmContainerName: '$(TF_STATE_CONTAINER)'
              backendAzureRmKey: '$(TF_STATE_KEY)'
          
          - task: TerraformTaskV4@4
            displayName: 'Terraform Plan'
            inputs:
              provider: 'azurerm'
              command: 'plan'
              workingDirectory: '$(System.DefaultWorkingDirectory)/terraform'
              environmentServiceNameAzureRM: '$(SERVICE_CONNECTION_NAME)'
              commandOptions: '-out=tfplan'
          
          - task: PublishPipelineArtifact@1
            displayName: 'Publish Plan'
            inputs:
              targetPath: '$(System.DefaultWorkingDirectory)/terraform/tfplan'
              artifact: 'tfplan'

  - stage: Apply
    displayName: 'Apply Infrastructure'
    dependsOn: Plan
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      - deployment: Apply
        pool:
          vmImage: $(VM_IMAGE)
        environment: '$(ENVIRONMENT)'
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self
                
                - task: DownloadPipelineArtifact@2
                  inputs:
                    artifact: 'tfplan'
                    path: '$(System.DefaultWorkingDirectory)/terraform'
                
                - task: TerraformInstaller@1
                  inputs:
                    terraformVersion: 'latest'
                
                - task: TerraformTaskV4@4
                  displayName: 'Terraform Init'
                  inputs:
                    provider: 'azurerm'
                    command: 'init'
                    workingDirectory: '$(System.DefaultWorkingDirectory)/terraform'
                    backendServiceArm: '$(SERVICE_CONNECTION_NAME)'
                    backendAzureRmResourceGroupName: '$(TF_STATE_RESOURCE_GROUP)'
                    backendAzureRmStorageAccountName: '$(TF_STATE_STORAGE_ACCOUNT)'
                    backendAzureRmContainerName: '$(TF_STATE_CONTAINER)'
                    backendAzureRmKey: '$(TF_STATE_KEY)'
                
                - task: TerraformTaskV4@4
                  displayName: 'Terraform Apply'
                  inputs:
                    provider: 'azurerm'
                    command: 'apply'
                    workingDirectory: '$(System.DefaultWorkingDirectory)/terraform'
                    environmentServiceNameAzureRM: '$(SERVICE_CONNECTION_NAME)'
                    commandOptions: 'tfplan'
YAML

    # Application Build Pipeline
    cat > "$templates_dir/app-pipeline.yml" << 'YAML'
# Application Build and Deploy Pipeline
# Builds container images and deploys to AKS

trigger:
  branches:
    include:
      - main
      - develop
  paths:
    include:
      - 'src/**'
      - 'Dockerfile'

pr:
  branches:
    include:
      - main

variables:
  - group: 'Infrastructure Variables'
  - group: 'Environment Variables - $(ENVIRONMENT)'
  - name: imageRepository
    value: '$(RESOURCE_PREFIX)-app'
  - name: dockerfilePath
    value: '$(Build.SourcesDirectory)/Dockerfile'
  - name: tag
    value: '$(Build.BuildId)'

stages:
  - stage: Build
    displayName: 'Build and Push'
    jobs:
      - job: Build
        pool:
          vmImage: $(VM_IMAGE)
        steps:
          - task: Docker@2
            displayName: 'Build Image'
            inputs:
              command: 'build'
              repository: '$(imageRepository)'
              dockerfile: '$(dockerfilePath)'
              tags: |
                $(tag)
                latest
          
          - task: Docker@2
            displayName: 'Push to ACR'
            inputs:
              containerRegistry: '$(SERVICE_CONNECTION_NAME)'
              repository: '$(imageRepository)'
              command: 'push'
              tags: |
                $(tag)
                latest

  - stage: Deploy
    displayName: 'Deploy to AKS'
    dependsOn: Build
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      - deployment: Deploy
        pool:
          vmImage: $(VM_IMAGE)
        environment: '$(ENVIRONMENT)'
        strategy:
          runOnce:
            deploy:
              steps:
                - task: KubernetesManifest@1
                  displayName: 'Deploy to Kubernetes'
                  inputs:
                    action: 'deploy'
                    connectionType: 'azureResourceManager'
                    azureSubscriptionConnection: '$(SERVICE_CONNECTION_NAME)'
                    azureResourceGroup: '$(RESOURCE_PREFIX)-$(ENVIRONMENT)-rg'
                    kubernetesCluster: '$(RESOURCE_PREFIX)-$(ENVIRONMENT)-aks'
                    manifests: |
                      $(Pipeline.Workspace)/manifests/*.yaml
                    containers: |
                      $(containerRegistry)/$(imageRepository):$(tag)
YAML

    log "Pipeline templates created in: $templates_dir"
    ok "Templates ready for upload to repositories"
}

#-------------------------------------------------------------------------------
# Pipelines
#-------------------------------------------------------------------------------
create_pipelines() {
    section "Creating Pipelines"
    
    # Define pipelines with their configurations
    declare -A pipelines=(
        ["infra-deploy"]="infra-provisioning:terraform/azure-pipelines.yml"
        ["app-build"]="app-services:azure-pipelines.yml"
    )
    
    for pipeline_name in "${!pipelines[@]}"; do
        IFS=':' read -r repo yaml_path <<< "${pipelines[$pipeline_name]}"
        
        # Check if pipeline exists
        if az pipelines show --name "$pipeline_name" &>/dev/null 2>&1; then
            ok "Pipeline exists: $pipeline_name"
        else
            log "Creating pipeline: $pipeline_name"
            
            # Note: Pipeline creation requires the YAML file to exist in the repo
            # This creates a placeholder that can be updated later
            az pipelines create \
                --name "$pipeline_name" \
                --repository "$repo" \
                --branch "$GIT_BRANCH" \
                --repository-type tfsgit \
                --skip-first-run true \
                --yaml-path "$yaml_path" \
                --output none 2>/dev/null || warn "Pipeline $pipeline_name requires YAML in repo"
        fi
    done
}

#-------------------------------------------------------------------------------
# Terraform State Backend
#-------------------------------------------------------------------------------
create_terraform_backend() {
    section "Creating Terraform State Backend"
    
    local rg_name="${RESOURCE_PREFIX}-tfstate-rg"
    local sa_name="${RESOURCE_PREFIX}tfstate${ENVIRONMENT}"
    local container_name="tfstate"
    
    # Sanitize storage account name (lowercase, alphanumeric only, max 24 chars)
    sa_name=$(echo "$sa_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]' | cut -c1-24)
    
    # Create resource group
    if az group show --name "$rg_name" &>/dev/null; then
        ok "Resource group exists: $rg_name"
    else
        log "Creating resource group: $rg_name"
        az group create --name "$rg_name" --location "$LOCATION" --output none
        ok "Created: $rg_name"
    fi
    
    # Create storage account
    if az storage account show --name "$sa_name" --resource-group "$rg_name" &>/dev/null; then
        ok "Storage account exists: $sa_name"
    else
        log "Creating storage account: $sa_name"
        az storage account create \
            --name "$sa_name" \
            --resource-group "$rg_name" \
            --location "$LOCATION" \
            --sku Standard_LRS \
            --kind StorageV2 \
            --https-only true \
            --min-tls-version TLS1_2 \
            --allow-blob-public-access false \
            --output none
        ok "Created: $sa_name"
    fi
    
    # Create container
    local account_key=$(az storage account keys list --account-name "$sa_name" --resource-group "$rg_name" --query '[0].value' -o tsv)
    
    if az storage container show --name "$container_name" --account-name "$sa_name" --account-key "$account_key" &>/dev/null; then
        ok "Container exists: $container_name"
    else
        log "Creating container: $container_name"
        az storage container create \
            --name "$container_name" \
            --account-name "$sa_name" \
            --account-key "$account_key" \
            --output none
        ok "Created: $container_name"
    fi
    
    # Enable versioning for state file protection
    az storage account blob-service-properties update \
        --account-name "$sa_name" \
        --resource-group "$rg_name" \
        --enable-versioning true \
        --output none
    
    log "Terraform backend: $sa_name/$container_name"
}

#-------------------------------------------------------------------------------
# Key Vault for Secrets
#-------------------------------------------------------------------------------
create_key_vault() {
    section "Creating Key Vault"
    
    local rg_name="${RESOURCE_PREFIX}-${ENVIRONMENT}-rg"
    local kv_name="${RESOURCE_PREFIX}-${ENVIRONMENT}-kv"
    
    # Sanitize key vault name (alphanumeric and hyphens, 3-24 chars)
    kv_name=$(echo "$kv_name" | tr -cd '[:alnum:]-' | cut -c1-24)
    
    # Create resource group if not exists
    if ! az group show --name "$rg_name" &>/dev/null; then
        az group create --name "$rg_name" --location "$LOCATION" --output none
    fi
    
    # Create key vault
    if az keyvault show --name "$kv_name" &>/dev/null 2>&1; then
        ok "Key Vault exists: $kv_name"
    else
        log "Creating Key Vault: $kv_name"
        az keyvault create \
            --name "$kv_name" \
            --resource-group "$rg_name" \
            --location "$LOCATION" \
            --enable-rbac-authorization true \
            --output none
        ok "Created: $kv_name"
    fi
    
    # Grant service principal access if ARM_CLIENT_ID is set
    if [[ -n "${ARM_CLIENT_ID:-}" ]]; then
        log "Granting Key Vault access to service principal..."
        local sp_object_id=$(az ad sp show --id "$ARM_CLIENT_ID" --query id -o tsv 2>/dev/null || echo "")
        if [[ -n "$sp_object_id" ]]; then
            az role assignment create \
                --role "Key Vault Secrets Officer" \
                --assignee-object-id "$sp_object_id" \
                --assignee-principal-type ServicePrincipal \
                --scope "$(az keyvault show --name $kv_name --query id -o tsv)" \
                --output none 2>/dev/null || true
            ok "Access granted"
        fi
    fi
    
    KEY_VAULT_NAME="$kv_name"
}

#-------------------------------------------------------------------------------
# Cleanup
#-------------------------------------------------------------------------------
cleanup() {
    section "Cleanup Resources"
    
    local org_url="https://dev.azure.com/${ADO_ORGANIZATION}"
    
    echo -e "${Y}This will delete:${N}"
    echo "  - ADO Project: $ADO_PROJECT"
    echo "  - Resource Groups: ${RESOURCE_PREFIX}-*"
    echo "  - Service Principals: sp-${RESOURCE_PREFIX}-*"
    echo ""
    read -rp "Are you sure? Type 'yes' to confirm: " confirm
    [[ "$confirm" != "yes" ]] && { log "Cleanup cancelled"; exit 0; }
    
    # Delete ADO project
    log "Deleting ADO project..."
    az devops project delete --id "$ADO_PROJECT" --org "$org_url" --yes 2>/dev/null || warn "Project not found or already deleted"
    
    # Delete resource groups
    log "Deleting resource groups..."
    for rg in $(az group list --query "[?starts_with(name, '${RESOURCE_PREFIX}')].name" -o tsv 2>/dev/null); do
        log "Deleting: $rg"
        az group delete --name "$rg" --yes --no-wait
    done
    
    # Delete service principals
    log "Deleting service principals..."
    for sp in $(az ad sp list --all --query "[?starts_with(displayName, 'sp-${RESOURCE_PREFIX}')].appId" -o tsv 2>/dev/null); do
        log "Deleting SP: $sp"
        az ad sp delete --id "$sp" 2>/dev/null || true
    done
    
    ok "Cleanup initiated (some deletions may be running in background)"
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
    section "Deployment Summary"
    
    echo -e "${G}Azure DevOps Configuration:${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Organization:       ${C}https://dev.azure.com/${ADO_ORGANIZATION}${N}"
    echo -e "  Project:            ${C}${ADO_PROJECT}${N}"
    echo -e "  Service Connection: ${C}${SERVICE_CONNECTION_NAME}${N}"
    echo -e "  Environment:        ${C}${ENVIRONMENT}${N}"
    echo ""
    echo -e "${G}Azure Resources:${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Subscription:       ${C}${ARM_SUBSCRIPTION_ID}${N}"
    echo -e "  Location:           ${C}${LOCATION}${N}"
    echo -e "  Resource Prefix:    ${C}${RESOURCE_PREFIX}${N}"
    echo -e "  Key Vault:          ${C}${KEY_VAULT_NAME:-N/A}${N}"
    echo ""
    echo -e "${G}Next Steps:${N}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  1. Push Terraform code to 'infra-provisioning' repository"
    echo "  2. Push application code to 'app-services' repository"
    echo "  3. Configure pipeline YAML files in repositories"
    echo "  4. Add secrets to Key Vault: ${KEY_VAULT_NAME:-N/A}"
    echo "  5. Run pipelines from Azure DevOps"
    echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local command="${1:-deploy}"
    
    case "$command" in
        deploy)
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Azure DevOps Infrastructure Pipeline Deployment"
            echo "  Environment: ${ENVIRONMENT:-dev}"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            validate_prerequisites
            create_ado_project
            create_service_connection
            create_repositories
            create_variable_groups
            create_terraform_backend
            create_key_vault
            create_pipeline_templates
            create_pipelines
            print_summary
            ;;
        cleanup)
            validate_prerequisites
            cleanup
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            err "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
