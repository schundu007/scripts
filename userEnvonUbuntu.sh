#!/usr/bin/env bash
#===============================================================================
# Ubuntu Dev Environment Setup | Usage: ./ubuntu-dev-setup.sh [--minimal|--help]
#===============================================================================
set -euo pipefail

# Versions (modify as needed)
TF_VER="1.7.5" GO_VER="1.22.1"

# Colors & helpers
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
log() { echo -e "${C}[*]${N} $*"; }
ok()  { echo -e "${G}[✓]${N} $*"; }
err() { echo -e "${R}[✗]${N} $*" >&2; }
has() { command -v "$1" &>/dev/null; }
arch() { [[ $(uname -m) == "x86_64" ]] && echo "amd64" || echo "arm64"; }

[[ $EUID -eq 0 ]] && err "Don't run as root" && exit 1

# Backup existing configs
backup_configs() {
    local bkp="$HOME/backup/dotfiles_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$bkp"
    for f in .bashrc .bash_profile .profile; do [[ -f "$HOME/$f" ]] && cp "$HOME/$f" "$bkp/"; done
    ok "Backups: $bkp"
}

# SSH key setup (Ed25519)
setup_ssh() {
    local key="$HOME/.ssh/id_ed25519"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    if [[ -f "$key" ]]; then
        log "SSH key exists: $key"
    else
        ssh-keygen -t ed25519 -C "${USER}@$(hostname)" -N '' -f "$key"
        ok "SSH key generated"
    fi
    echo -e "\n${Y}Public key:${N}" && cat "${key}.pub"
}

# System update & essentials
install_essentials() {
    log "Updating system..."
    sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get autoremove -y
    sudo apt-get install -y apt-transport-https ca-certificates curl wget git jq unzip zip make \
        build-essential libssl-dev net-tools software-properties-common gnupg lsb-release \
        tree htop tmux python3 python3-pip python3-venv direnv
    ok "Essentials installed"
}

# Docker
install_docker() {
    has docker && { ok "Docker: $(docker --version)"; return; }
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(arch) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"
    ok "Docker installed (re-login for group)"
}

# kubectl
install_kubectl() {
    has kubectl && { ok "kubectl installed"; return; }
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    sudo apt-get update -y && sudo apt-get install -y kubectl
    ok "kubectl installed"
}

# Helm
install_helm() {
    has helm && { ok "Helm: $(helm version --short)"; return; }
    curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg >/dev/null
    echo "deb [arch=$(arch) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm.list >/dev/null
    sudo apt-get update -y && sudo apt-get install -y helm
    helm repo add stable https://charts.helm.sh/stable 2>/dev/null || true
    ok "Helm installed"
}

# Terraform
install_terraform() {
    has terraform && { ok "Terraform: $(terraform version | head -1)"; return; }
    wget -q "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_$(arch).zip" -O /tmp/tf.zip
    sudo unzip -o /tmp/tf.zip -d /usr/local/bin/ && rm /tmp/tf.zip
    ok "Terraform $TF_VER installed"
}

# Go
install_go() {
    has go && { ok "Go: $(go version)"; return; }
    wget -q "https://go.dev/dl/go${GO_VER}.linux-$(arch).tar.gz" -O /tmp/go.tar.gz
    sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz
    ok "Go $GO_VER installed"
}

# Azure CLI
install_az() {
    has az && { ok "Azure CLI: $(az version -o tsv --query '\"azure-cli\"')"; return; }
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    az extension add --name azure-devops -y 2>/dev/null || true
    ok "Azure CLI installed"
}

# AWS CLI
install_aws() {
    has aws && { ok "AWS CLI: $(aws --version | cut -d' ' -f1)"; return; }
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/aws.zip
    unzip -q /tmp/aws.zip -d /tmp && sudo /tmp/aws/install && rm -rf /tmp/aws.zip /tmp/aws
    ok "AWS CLI installed"
}

# bash-git-prompt
install_gitprompt() {
    local dir="$HOME/.bash-git-prompt"
    [[ -d "$dir" ]] && { cd "$dir" && git pull -q; } || git clone --depth=1 https://github.com/magicmonty/bash-git-prompt.git "$dir"
    ok "bash-git-prompt ready"
}

# Shell configuration
configure_shell() {
    touch "$HOME/.hushlogin"
    cat > "$HOME/.bashrc_devops" << 'EOF'
# DevOps Environment Config
HISTCONTROL=ignoreboth:erasedups; HISTSIZE=100000; HISTFILESIZE=200000
shopt -s histappend cdspell checkwinsize; set -o noclobber

# Aliases
alias h='history' c='clear' ll='ls -alF' ..='cd ..' ...='cd ../..'
alias k='kubectl' kgp='kubectl get pods' kgs='kubectl get svc' kga='kubectl get all'
alias d='docker' dc='docker compose' dps='docker ps' di='docker images'
alias tf='terraform' tfi='terraform init' tfp='terraform plan' tfa='terraform apply'
alias gs='git status' ga='git add' gc='git commit' gp='git push' gl='git pull'

# Paths
export EDITOR=vim PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin"
[[ -d "/usr/local/go" ]] && export GOPATH=$HOME/go

# Hooks & completions
command -v direnv &>/dev/null && eval "$(direnv hook bash)"
command -v kubectl &>/dev/null && source <(kubectl completion bash) && complete -o default -F __start_kubectl k
command -v helm &>/dev/null && source <(helm completion bash)
[[ -f "$HOME/.bash-git-prompt/gitprompt.sh" ]] && GIT_PROMPT_ONLY_IN_REPO=1 && source "$HOME/.bash-git-prompt/gitprompt.sh"

# Functions
mkcd() { mkdir -p "$1" && cd "$1"; }
kctx() { kubectl config use-context "$1"; }
kns() { kubectl config set-context --current --namespace="$1"; }
EOF
    grep -q "bashrc_devops" "$HOME/.bashrc" || echo '[[ -f "$HOME/.bashrc_devops" ]] && source "$HOME/.bashrc_devops"' >> "$HOME/.bashrc"
    ok "Shell configured (~/.bashrc_devops)"
}

# Summary
summary() {
    echo -e "\n${C}=== Installation Summary ===${N}"
    has docker && echo "  Docker:    $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
    has kubectl && echo "  kubectl:   installed"
    has helm && echo "  Helm:      $(helm version --short 2>/dev/null)"
    has terraform && echo "  Terraform: $(terraform version -json 2>/dev/null | jq -r '.terraform_version')"
    has go && echo "  Go:        $(go version 2>/dev/null | cut -d' ' -f3)"
    has az && echo "  Azure CLI: $(az version -o tsv --query '\"azure-cli\"' 2>/dev/null)"
    has aws && echo "  AWS CLI:   $(aws --version 2>/dev/null | cut -d'/' -f2 | cut -d' ' -f1)"
    echo -e "\n${Y}Run: source ~/.bashrc${N}"
}

# Main
main() {
    [[ "${1:-}" == "--help" ]] && echo "Usage: $0 [--minimal]" && exit 0
    echo -e "${C}=== Ubuntu Dev Setup ===${N}\n"
    backup_configs; setup_ssh; install_essentials; install_gitprompt
    [[ "${1:-}" != "--minimal" ]] && { install_docker; install_kubectl; install_helm; install_terraform; install_go; install_az; install_aws; }
    configure_shell; summary
}

main "$@"
