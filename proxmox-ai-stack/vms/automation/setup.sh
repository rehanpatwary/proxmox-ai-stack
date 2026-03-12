#!/usr/bin/env bash
# =============================================================================
#  automation-vm/setup.sh — Automation VM Service Installer
#
#  Installs n8n and Flowise on automation-vm, both backed by Postgres
#  on data-vm. These services together provide workflow automation with
#  native AI/LLM integration.
#
#  SERVICES DEPLOYED
#  ─────────────────
#  Service        Port   Description
#  ──────────────────────────────────────────────────────────────────────────
#  n8n            5678   Workflow automation with 400+ integrations and
#                        native Ollama nodes for AI workflows
#  Flowise        3002   Visual drag-and-drop LLM pipeline builder; agents,
#                        RAG chains, and tool-use flows
#  node-exporter  9100   Prometheus system metrics
#
#  DATABASE DEPENDENCY
#  ───────────────────
#  Both services connect to Postgres on DATA_VM_IP. The  n8n  database must
#  exist before this script runs — it is created by data-vm/setup.sh.
#  deploy_all.sh enforces this ordering with a 10-second pause after data-vm.
#
#  n8n NOTES
#  ─────────
#  - Timezone is set to Asia/Dhaka — change N8N_TIMEZONE if needed
#  - Community nodes are enabled (n8n-nodes-ollama, etc.)
#  - Execution history is pruned after 14 days to control DB growth
#  - N8N_ENCRYPTION_KEY protects stored credentials; never change after setup
#
#  FLOWISE NOTES
#  ─────────────
#  - Shares the  n8n  Postgres database (separate schema)
#  - Default login: admin / first 16 chars of N8N_ENCRYPTION_KEY
#  - OLLAMA_BASE_URL points to ai-vm for model access
#
#  REQUIREMENTS
#  ────────────
#  - Run as root inside automation-vm
#  - DATA_VM_IP must be accessible on port 5432
#  - N8N_ENCRYPTION_KEY and POSTGRES_PASSWORD must be set
#
#  USAGE
#  ─────
#    bash deploy_vm.sh automation       (from Proxmox host — recommended)
#    sudo -E bash ~/automation-vm/setup.sh  (from inside the VM)
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
N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
DATA_VM_IP="${DATA_VM_IP:-192.168.1.30}"
AI_VM_IP="${AI_VM_IP:-192.168.1.10}"
BASE_DOMAIN="${BASE_DOMAIN:-ai.local}"
N8N_HOST="n8n.${BASE_DOMAIN}"

[[ -z "$N8N_ENCRYPTION_KEY" ]] && error "N8N_ENCRYPTION_KEY is empty. Run  bash init_secrets.sh  on the Proxmox host."
[[ -z "$POSTGRES_PASSWORD"  ]] && error "POSTGRES_PASSWORD is empty. Run  bash init_secrets.sh  on the Proxmox host."

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Update apt and install Docker CE.
# Idempotent: skips if Docker is already present.
##
install_docker() {
    section "System Update + Docker"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget gnupg lsb-release

    if command -v docker &>/dev/null; then
        info "Docker already installed ($(docker --version))"
        return 0
    fi

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
}

##
# Write the Docker Compose file defining n8n, Flowise, and node-exporter.
#
# Both n8n and Flowise are configured to use the Postgres instance on
# DATA_VM_IP. Environment variables control timezone, encryption, and
# the Ollama connection endpoint.
##
write_docker_compose() {
    section "Docker Compose"
    mkdir -p /opt/automation-stack

    cat > /opt/automation-stack/docker-compose.yml <<COMPOSE
version: "3.9"

networks:
  auto-net:
    driver: bridge

volumes:
  n8n_data:
  flowise_data:

services:

  # ── n8n ───────────────────────────────────────────────────────────────────
  # Workflow automation platform with native AI/LLM support.
  # DB_TYPE=postgresdb stores all workflow, execution, and credential data
  # in Postgres on data-vm rather than SQLite (required for reliability).
  # N8N_ENCRYPTION_KEY protects stored API keys and passwords — never change
  # this after initial setup; doing so permanently destroys all credentials.
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      # Database — Postgres on data-vm
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: ${DATA_VM_IP}
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n_user
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      # Security — encryption key must never change after first run
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_USER_MANAGEMENT_JWT_SECRET: ${N8N_ENCRYPTION_KEY}
      # Network — tells n8n its public URL for webhook generation
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: 5678
      N8N_PROTOCOL: http
      WEBHOOK_URL: http://${N8N_HOST}
      # Timezone — adjust to your location
      GENERIC_TIMEZONE: Asia/Dhaka
      TZ: Asia/Dhaka
      # Ollama integration — direct API access to ai-vm
      OLLAMA_BASE_URL: http://${AI_VM_IP}:11434
      # Community nodes — enables n8n-nodes-ollama and others
      N8N_COMMUNITY_PACKAGES_ENABLED: "true"
      N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE: "true"
      # Execution history — prune records older than 14 days
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: 336
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - auto-net

  # ── Flowise ───────────────────────────────────────────────────────────────
  # Visual LLM pipeline builder for agents, RAG chains, and tool-use flows.
  # Shares the n8n Postgres database (stored in a separate internal schema).
  # Default credentials: admin / first 16 chars of N8N_ENCRYPTION_KEY.
  flowise:
    image: flowiseai/flowise:latest
    container_name: flowise
    restart: unless-stopped
    ports:
      - "3002:3000"
    environment:
      PORT: 3000
      FLOWISE_USERNAME: admin
      FLOWISE_PASSWORD: ${N8N_ENCRYPTION_KEY:0:16}
      DATABASE_TYPE: postgres
      DATABASE_HOST: ${DATA_VM_IP}
      DATABASE_PORT: 5432
      DATABASE_NAME: n8n
      DATABASE_USER: n8n_user
      DATABASE_PASSWORD: ${POSTGRES_PASSWORD}
      FLOWISE_SECRETKEY_OVERWRITE: ${N8N_ENCRYPTION_KEY}
      OLLAMA_BASE_URL: http://${AI_VM_IP}:11434
      BLOB_STORAGE_PATH: /root/.flowise
      LOG_LEVEL: info
      TZ: Asia/Dhaka
    volumes:
      - flowise_data:/root/.flowise
    networks:
      - auto-net

  # ── Prometheus Node Exporter ──────────────────────────────────────────────
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
    networks:
      - auto-net

COMPOSE
    info "docker-compose.yml written ✓"
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

install_docker
write_docker_compose

section "Starting Stack"
cd /opt/automation-stack
docker compose up -d
sleep 15
docker compose ps

# ---------------------------------------------------------------------------
#  Post-install summary
# ---------------------------------------------------------------------------
VM_IP=$(hostname -I | awk '{print $1}')
FLOWISE_PASSWORD="${N8N_ENCRYPTION_KEY:0:16}"

cat <<EOF

${GREEN}════════════════════════════════════════════════════════${NC}
  Automation VM stack is running.

  Services:
    n8n     → http://${VM_IP}:5678  (create account on first visit)
    Flowise → http://${VM_IP}:3002  (admin / ${FLOWISE_PASSWORD})

  Both services connected to Postgres at ${DATA_VM_IP}:5432.
  Ollama available at http://${AI_VM_IP}:11434.

  N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
  KEEP THIS KEY SAFE — it cannot be recovered and changing it
  destroys all saved credentials in n8n.

  Recommended community node to install in n8n:
    Settings → Community Nodes → Install → n8n-nodes-ollama
${GREEN}════════════════════════════════════════════════════════${NC}
EOF
