#!/usr/bin/env bash
# =============================================================================
#  coding-vm/setup.sh — Coding VM Service Installer
#
#  Configures coding-vm with AI-assisted development tooling pointing at
#  the Ollama instance on ai-vm. No inference workloads run on this VM —
#  it is purely a configuration and tooling node.
#
#  TOOLS CONFIGURED
#  ─────────────────
#  Tool         Config location                  Notes
#  ─────────────────────────────────────────────────────────────────────────
#  OpenCode     ~/.config/opencode/config.json   CLI AI coding assistant
#  Continue     ~/.continue/config.json          VS Code / JetBrains extension
#
#  MODELS CONFIGURED (served by Ollama on ai-vm)
#  ─────────────────────────────────────────────
#  qwen2.5-coder:32b    Primary coding model (chat and edit)
#  qwen2.5-coder:1.5b   Tab autocomplete (low latency)
#  deepseek-coder-v2:16b Alternative reasoning model
#  nomic-embed-text     Embeddings for codebase indexing
#
#  MODEL PULLING
#  ─────────────
#  This script attempts to pull the coding models directly to Ollama on
#  ai-vm via the HTTP API. Pulls run in the background. If Ollama is not
#  yet reachable, a warning is printed and models must be pulled manually.
#
#  NODE EXPORTER
#  ─────────────
#  A single node-exporter container is started via Docker to provide
#  Prometheus metrics for this VM. No Compose file is needed for a single
#  container — it runs directly via  docker run.
#
#  REQUIREMENTS
#  ────────────
#  - Run as root inside coding-vm
#  - AI_VM_IP must be set and ai-vm must be running for model pulls
#
#  USAGE
#  ─────
#    bash deploy_vm.sh coding           (from Proxmox host — recommended)
#    sudo -E bash ~/coding-vm/setup.sh  (from inside the VM)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root:  sudo -E bash setup.sh"

# ---------------------------------------------------------------------------
#  Common VM bootstrap (chrony, journald limits, TRIM, admin tools)
#  Runs once; idempotent on re-runs.
# ---------------------------------------------------------------------------
# shellcheck source=../common/bootstrap.sh
source "$(dirname "$0")/../common/bootstrap.sh"

# ---------------------------------------------------------------------------
#  Config with safe defaults
# ---------------------------------------------------------------------------
AI_VM_IP="${AI_VM_IP:-192.168.1.10}"
CODING_USER="${CODING_USER:-ubuntu}"

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Update apt and install Node.js 20 LTS plus common build tools.
#
# Node.js 20 is installed from the official NodeSource setup script.
# Idempotent: checks the major version before reinstalling.
##
install_base_packages() {
    section "System Update + Node.js"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget git unzip build-essential \
        python3 python3-pip python3-venv

    if node --version 2>/dev/null | grep -q "^v20"; then
        info "Node.js 20 already installed ($(node --version))"
    else
        info "Installing Node.js 20 LTS..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
        info "Node.js $(node --version) installed ✓"
    fi
}

##
# Install OpenCode CLI and write its configuration file.
#
# Attempts npm install first, then falls back to the official curl installer.
# The config file points OpenCode at the qwen2.5-coder:32b model served by
# Ollama on ai-vm.
#
# Arguments: none (reads AI_VM_IP and CODING_USER globals)
#
# Side effects:
#   Creates ~/.config/opencode/config.json for CODING_USER
##
install_opencode() {
    section "OpenCode"

    if ! command -v opencode &>/dev/null; then
        info "Installing OpenCode..."
        npm install -g opencode-ai 2>/dev/null \
            || npm install -g @opencode-ai/cli 2>/dev/null \
            || curl -fsSL https://opencode.ai/install | bash 2>/dev/null \
            || warn "OpenCode install failed — install manually from https://opencode.ai"
    else
        info "OpenCode already installed"
    fi

    # Write config regardless of whether OpenCode installed successfully
    # so it is ready when installed manually
    local config_dir="/home/${CODING_USER}/.config/opencode"
    mkdir -p "$config_dir"

    cat > "${config_dir}/config.json" <<OCFG
{
  "provider": {
    "type": "ollama",
    "baseURL": "http://${AI_VM_IP}:11434"
  },
  "model": "qwen2.5-coder:32b",
  "theme": "dark"
}
OCFG

    chown -R "${CODING_USER}:${CODING_USER}" "$config_dir"
    info "OpenCode config written to ${config_dir}/config.json ✓"
}

##
# Write the Continue extension configuration file.
#
# Continue is a VS Code and JetBrains plugin that reads ~/.continue/config.json
# on startup. This file configures multiple models for different use cases:
#   - Chat/edit model:   qwen2.5-coder:32b
#   - Autocomplete:      qwen2.5-coder:1.5b (fast, low latency)
#   - Embeddings:        nomic-embed-text (for codebase indexing)
#   - Alternative:       deepseek-coder-v2:16b
#
# Arguments: none (reads AI_VM_IP and CODING_USER globals)
#
# Side effects:
#   Creates ~/.continue/config.json for CODING_USER
##
write_continue_config() {
    section "Continue Extension Config"

    local config_dir="/home/${CODING_USER}/.continue"
    mkdir -p "$config_dir"

    cat > "${config_dir}/config.json" <<CCFG
{
  "models": [
    {
      "title": "Qwen2.5 Coder 32B",
      "provider": "ollama",
      "model": "qwen2.5-coder:32b",
      "apiBase": "http://${AI_VM_IP}:11434"
    },
    {
      "title": "DeepSeek Coder V2 16B",
      "provider": "ollama",
      "model": "deepseek-coder-v2:16b",
      "apiBase": "http://${AI_VM_IP}:11434"
    },
    {
      "title": "Llama 3.2 3B (Fast)",
      "provider": "ollama",
      "model": "llama3.2:3b",
      "apiBase": "http://${AI_VM_IP}:11434"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5 Coder 1.5B (Autocomplete)",
    "provider": "ollama",
    "model": "qwen2.5-coder:1.5b",
    "apiBase": "http://${AI_VM_IP}:11434"
  },
  "embeddingsProvider": {
    "provider": "ollama",
    "model": "nomic-embed-text",
    "apiBase": "http://${AI_VM_IP}:11434"
  },
  "contextProviders": [
    { "name": "code" },
    { "name": "docs" },
    { "name": "diff" },
    { "name": "terminal" },
    { "name": "problems" },
    { "name": "folder" },
    { "name": "codebase" }
  ],
  "slashCommands": [
    { "name": "edit",    "description": "Edit selected code" },
    { "name": "comment", "description": "Write comments for selected code" },
    { "name": "share",   "description": "Export conversation as markdown" }
  ]
}
CCFG

    chown -R "${CODING_USER}:${CODING_USER}" "$config_dir"
    info "Continue config written to ${config_dir}/config.json ✓"
}

##
# Trigger model pulls on the Ollama instance running on ai-vm.
#
# Sends pull requests to the Ollama API over HTTP. Pulls run asynchronously
# on ai-vm — this function only triggers them. Each model is pulled in a
# background subshell to run in parallel.
#
# If ai-vm is unreachable (not yet deployed or network issue), prints a
# warning with the manual pull command and continues.
##
pull_coding_models() {
    section "Pulling Coding Models on AI VM"

    info "Testing Ollama connection at ${AI_VM_IP}:11434..."
    if ! curl -s --connect-timeout 5 "http://${AI_VM_IP}:11434/api/tags" > /dev/null; then
        warn "Ollama not reachable at ${AI_VM_IP}:11434"
        warn "Pull models manually after ai-vm is running:"
        warn "  curl -X POST http://${AI_VM_IP}:11434/api/pull -d '{\"name\":\"qwen2.5-coder:32b\"}'"
        return 0
    fi

    info "Ollama reachable — triggering model pulls (run in background on ai-vm)..."

    local models=("qwen2.5-coder:32b" "qwen2.5-coder:1.5b" "nomic-embed-text")
    for model in "${models[@]}"; do
        curl -s -X POST "http://${AI_VM_IP}:11434/api/pull" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${model}\"}" &
        info "Pull triggered: $model"
    done

    info "Model pulls running in background on ai-vm. Check progress:"
    info "  ssh ubuntu@${AI_VM_IP} 'docker exec ollama ollama list'"
}

##
# Install Docker and start a node-exporter container for Prometheus metrics.
#
# Uses a single  docker run  command rather than a Compose file since only
# one container is needed on this VM.
# Idempotent: the  --name  flag causes docker run to fail if the container
# already exists; the  2>/dev/null || true  suppresses that error.
##
install_node_exporter() {
    section "Docker + Node Exporter"

    if ! command -v docker &>/dev/null; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable --now docker
        info "Docker installed ✓"
    fi

    docker run -d \
        --restart unless-stopped \
        --name node-exporter \
        --pid host \
        -p 9100:9100 \
        -v /proc:/host/proc:ro \
        -v /sys:/host/sys:ro \
        prom/node-exporter:latest \
        --path.procfs=/host/proc \
        --path.sysfs=/host/sys \
        2>/dev/null || info "node-exporter already running"

    info "node-exporter running on :9100 ✓"
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

install_base_packages
install_opencode
write_continue_config
pull_coding_models
install_node_exporter

# ---------------------------------------------------------------------------
#  Post-install summary
# ---------------------------------------------------------------------------
cat <<EOF

${GREEN}════════════════════════════════════════════════════════${NC}
  Coding VM is configured.

  AI coding tools connected to Ollama at http://${AI_VM_IP}:11434

  OpenCode config:  ~/.config/opencode/config.json
    Usage:  opencode   (run in any project directory)

  Continue config:  ~/.continue/config.json
    Usage:  Install the "Continue" extension in VS Code or JetBrains
            It reads the config file automatically on startup

  Models (served by ai-vm):
    qwen2.5-coder:32b    — primary chat + edit model
    qwen2.5-coder:1.5b   — tab autocomplete
    nomic-embed-text     — codebase embeddings
    deepseek-coder-v2:16b — alternative reasoning model
${GREEN}════════════════════════════════════════════════════════${NC}
EOF
