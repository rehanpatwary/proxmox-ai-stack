#!/usr/bin/env bash
# =============================================================================
#  deploy_lxc_stack.sh — LXC Stack Integration Wrapper
#
#  Wraps the community-scripts LXC deployer (lxc-stack.sh) and integrates
#  it with the existing VM stack so that:
#    - Services already running in VMs are not re-deployed as LXC containers
#    - LXC containers that need Ollama or Postgres are pointed at the VMs
#    - Network and storage config flows from config.env automatically
#
#  INTEGRATION MECHANISM
#  ─────────────────────
#  1. Pre-marks VM services in the deploy state file so lxc-stack.sh skips them
#  2. Exports VM IPs and secrets as environment variables that community scripts
#     read during container setup
#  3. Passes BRIDGE, GATEWAY, STORAGE from config.env to the LXC deployer
#
#  VM SERVICES SKIPPED (pre-marked as deployed)
#  ─────────────────────────────────────────────
#  ollama, open-webui, anythingllm, flowise, n8n, grafana, prometheus,
#  postgresql, qdrant, loki
#
#  ENVIRONMENT VARIABLES EXPORTED TO LXC CONTAINERS
#  ─────────────────────────────────────────────────
#  OLLAMA_BASE_URL    http://AI_VM_IP:11434
#  DATABASE_HOST      DATA_VM_IP
#  DATABASE_PASSWORD  POSTGRES_PASSWORD
#  GRAFANA_URL        http://MONITORING_VM_IP:3003
#
#  VMID ALLOCATION
#  ───────────────
#  LXC containers start at VMID 400 (configurable via START_VMID in config.env).
#  Your VMs use 200–204. There is no conflict.
#
#  REQUIREMENTS
#  ────────────
#  - Run as root on the Proxmox HOST
#  - lxc-stack.sh must be present alongside this script
#  - config.env must be populated (init_secrets.sh run)
#
#  USAGE
#  ─────
#    bash deploy_lxc_stack.sh               interactive menu
#    bash deploy_lxc_stack.sh --all         deploy all LXC services
#    bash deploy_lxc_stack.sh --phase 4     deploy phase 4 (Business/Finance)
#    bash deploy_lxc_stack.sh --phase 9     deploy phase 9 (Security/SSO)
#    bash deploy_lxc_stack.sh --dry-run     preview without changes
#    bash deploy_lxc_stack.sh --list        list all services (VMs marked done)
#    bash deploy_lxc_stack.sh --status      show deployment status
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
#  Resolve paths relative to this script (not $PWD)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"
LXC_SCRIPT="${SCRIPT_DIR}/lxc-stack.sh"

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
#  Guards
# ---------------------------------------------------------------------------
[[ ! -f "$CONFIG"     ]] && error "config.env not found at $CONFIG"
[[ ! -f "$LXC_SCRIPT" ]] && error "lxc-stack.sh not found at $LXC_SCRIPT"
[[ $EUID -ne 0        ]] && error "Must run as root on the Proxmox host"

source "$CONFIG"

[[ -z "${POSTGRES_PASSWORD:-}" ]] && \
    error "Secrets not initialised. Run:  bash init_secrets.sh"

# ---------------------------------------------------------------------------
#  Deploy state file — shared with lxc-stack.sh
# ---------------------------------------------------------------------------
DEPLOY_STATE="/root/.proxmox-ai-deploy-state"
mkdir -p "$(dirname "$DEPLOY_STATE")"
touch "$DEPLOY_STATE"

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Pre-mark VM-deployed services in the lxc-stack deploy state file.
#
# The community-scripts deployer (lxc-stack.sh) reads DEPLOY_STATE and skips
# any service whose name appears in it. By writing VM service names here, we
# prevent duplicate LXC containers from being created for services already
# running in the VM layer.
#
# Idempotent: only writes a name if it is not already in the file.
##
mark_vm_services_as_deployed() {
    section "Pre-marking VM services (will be skipped by LXC deployer)"

    # Services running in the VM layer that must not be deployed as LXC
    local vm_services=(
        ollama          # ai-vm  :11434
        open-webui      # ai-vm  :3000
        anythingllm     # ai-vm  :3001
        qdrant          # ai-vm  :6333
        flowise         # automation-vm :3002
        n8n             # automation-vm :5678
        grafana         # monitoring-vm :3003
        prometheus      # monitoring-vm :9090
        postgresql      # data-vm :5432
        loki            # monitoring-vm (if deployed)
    )

    for svc in "${vm_services[@]}"; do
        if grep -qx "$svc" "$DEPLOY_STATE" 2>/dev/null; then
            echo -e "  ${YELLOW}–${NC} already marked: $svc"
        else
            echo "$svc" >> "$DEPLOY_STATE"
            echo -e "  ${GREEN}✓${NC} marked as deployed: $svc  ${CYAN}(running in VM)${NC}"
        fi
    done
}

##
# Export VM service endpoints as environment variables for LXC containers.
#
# Many community-scripts containers read these variables during setup to
# configure service connections. Exporting them here makes the values
# available to every subprocess, including lxc-stack.sh and the containers
# it creates.
#
# Variables exported:
#   OLLAMA_BASE_URL / OLLAMA_HOST / OLLAMA_PORT
#   DATABASE_HOST / DATABASE_PORT / DATABASE_USER / DATABASE_PASSWORD
#   POSTGRES_HOST / POSTGRES_PORT / POSTGRES_PASSWORD
#   DB_HOST / DB_PORT / DB_PASSWORD
#   GRAFANA_URL / PROMETHEUS_URL
##
export_vm_endpoints() {
    section "Exporting VM service endpoints"

    # Ollama — multiple variable names to cover different community scripts
    export OLLAMA_BASE_URL="http://${AI_VM_IP}:11434"
    export OLLAMA_HOST="${AI_VM_IP}"
    export OLLAMA_PORT="11434"

    # Postgres — multiple naming conventions used across different scripts
    export DATABASE_HOST="${DATA_VM_IP}"
    export DATABASE_PORT="5432"
    export DATABASE_USER="postgres"
    export DATABASE_PASSWORD="${POSTGRES_PASSWORD}"
    export POSTGRES_HOST="${DATA_VM_IP}"
    export POSTGRES_PORT="5432"
    export POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
    export DB_HOST="${DATA_VM_IP}"
    export DB_PORT="5432"
    export DB_PASSWORD="${POSTGRES_PASSWORD}"

    # Monitoring
    export GRAFANA_URL="http://${MONITORING_VM_IP}:3003"
    export PROMETHEUS_URL="http://${MONITORING_VM_IP}:9090"

    info "Ollama   → ${OLLAMA_BASE_URL}"
    info "Postgres → ${DATA_VM_IP}:5432"
    info "Grafana  → ${GRAFANA_URL}"
}

##
# Export network and storage config from config.env to lxc-stack.sh variables.
#
# The community-scripts deployer reads these env vars to configure each
# container's network and select the correct storage pool.
##
export_network_config() {
    section "Applying network config from config.env"

    export BRIDGE="${BRIDGE}"
    export GATEWAY="${GATEWAY}"
    export DNS="${NAMESERVER}"
    export STORAGE="${STORAGE}"
    export START_VMID="${START_VMID:-400}"    # LXC VMIDs start at 400
    export NETWORK_MODE="${NETWORK_MODE:-dhcp}"

    info "Bridge:  ${BRIDGE}"
    info "Gateway: ${GATEWAY}"
    info "Storage: ${STORAGE}"
    info "VMID range starts at: ${START_VMID}"

    [[ "$NETWORK_MODE" == "static" ]] && \
        info "Static IP mode: ${STATIC_SUBNET:-10.0.3}.x"
}

# ---------------------------------------------------------------------------
#  Main — set up integration, then hand off to lxc-stack.sh
# ---------------------------------------------------------------------------

mark_vm_services_as_deployed
export_vm_endpoints
export_network_config

section "Launching LXC Stack Deployer"
echo ""
echo -e "  ${CYAN}VM-deployed services pre-marked — deployer will skip them.${NC}"
echo -e "  ${CYAN}All VM endpoints exported to containers.${NC}"
echo ""

# exec replaces this process with lxc-stack.sh — all exports remain in scope
# All CLI arguments (--phase, --all, --dry-run, etc.) are passed through unchanged
exec bash "$LXC_SCRIPT" "$@"
