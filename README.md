# DevOps Automation Scripts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.32-blue.svg)](https://kubernetes.io/)

Production-ready DevOps automation scripts for cloud infrastructure, Kubernetes, and CI/CD pipelines.

**Author:** Sudhakar Chundu | **Updated:** December 2025

---

## Scripts

| Script | Description |
|--------|-------------|
| [ubuntu-dev-setup.sh](#1-ubuntu-dev-environment-setup) | Ubuntu DevOps toolchain setup |
| [raycluster.yaml](#2-raycluster-kubernetes-manifest) | KubeRay cluster for ML workloads |
| [azure-aks-elasticsearch.sh](#3-azure-aks-elasticsearch) | Elasticsearch on Azure AKS |
| [aws-eks-elasticsearch.sh](#4-aws-eks-elasticsearch) | Elasticsearch on AWS EKS |
| [azure-devops-infra-pipeline.sh](#5-azure-devops-pipeline) | Azure DevOps CI/CD setup |

---

## 1. Ubuntu Dev Environment Setup

**File:** `ubuntu-dev-setup.sh`

Installs DevOps tools: Terraform, Go, Docker, kubectl, Helm, AWS CLI, Azure CLI.

```bash
./ubuntu-dev-setup.sh
```

**Features:**
- Multi-arch support (amd64/arm64)
- Ed25519 SSH keys
- Shell completions & aliases (`k`, `tf`, `d`, `gs`)

---

## 2. RayCluster Kubernetes Manifest

**File:** `raycluster.yaml`

```
┌────────────────────────────────────┐
│           RayCluster               │
│  ┌──────┐  ┌──────┐  ┌──────┐     │
│  │ Head │──│Worker│──│Worker│     │
│  └──────┘  └──────┘  └──────┘     │
└────────────────────────────────────┘
```

```bash
kubectl apply -f raycluster.yaml
kubectl port-forward svc/raycluster-complete-head-svc 8265:8265
```

**Specs:** Ray 2.9.3 | KubeRay API v1 | Autoscaling | Prometheus metrics

---

## 3. Azure AKS Elasticsearch

**File:** `azure-aks-elasticsearch.sh`

```
┌─────────────────────────────────┐
│  AKS ──► ES Cluster (3 nodes)  │
│          ↓                      │
│    Ingress + TLS + DNS          │
└─────────────────────────────────┘
```

```bash
export AZURE_SUBSCRIPTION_ID="your-sub-id"
./azure-aks-elasticsearch.sh
```

**Deploys:** AKS 1.32 | ES 8.17.0 | cert-manager v1.17.2 | ingress-nginx 4.14.1

---

## 4. AWS EKS Elasticsearch

**File:** `aws-eks-elasticsearch.sh`

```
┌─────────────────────────────────┐
│  EKS ──► ES Cluster (3 nodes)  │
│          ↓                      │
│    NLB + Ingress + TLS          │
└─────────────────────────────────┘
```

```bash
export AWS_REGION="us-west-2"
./aws-eks-elasticsearch.sh deploy

# Cleanup
./aws-eks-elasticsearch.sh cleanup
```

**Deploys:** EKS 1.32 | ES 8.17.0 | AWS LB Controller v2.10.0 | gp3 storage

---

## 5. Azure DevOps Pipeline

**File:** `azure-devops-infra-pipeline.sh`

```
ADO Project ──► Repos + Pipelines + Variables
     ↓
Azure ──► TF State Storage + Key Vault
```

```bash
export ARM_SUBSCRIPTION_ID="your-sub-id"
export ADO_ORGANIZATION="your-org"
export ADO_PROJECT="my-project"
export ADO_PAT="your-pat-token"

./azure-devops-infra-pipeline.sh deploy
```

---

## Version Matrix

| Component | Version |
|-----------|---------|
| Kubernetes | 1.32 |
| Elasticsearch | 8.17.0 |
| cert-manager | v1.17.2 |
| ingress-nginx | 4.14.1 |
| Ray | 2.9.3 |
| Terraform | 1.7.5+ |

---

## Prerequisites

```bash
# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# kubectl & Helm
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## Quick Start

```bash
git clone https://github.com/schundu007/scripts.git
cd scripts
chmod +x *.sh

# Ubuntu setup
./ubuntu-dev-setup.sh

# Azure Elasticsearch
AZURE_SUBSCRIPTION_ID="xxx" ./azure-aks-elasticsearch.sh

# AWS Elasticsearch
AWS_REGION="us-west-2" ./aws-eks-elasticsearch.sh deploy
```

---

## License

MIT License - see [LICENSE](LICENSE)

---

**GitHub:** [@schundu007](https://github.com/schundu007) | **LinkedIn:** [Sudhakar Chundu](https://linkedin.com/in/sudhakar-chundu)
