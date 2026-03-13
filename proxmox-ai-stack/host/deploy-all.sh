#!/usr/bin/env bash
# =============================================================================
#  deploy_all.sh — Full Stack Orchestrator
#
#  Deploys all five VMs in the correct dependency order.
#  Individual VM failures are caught and logged — all VMs are always
#  attempted regardless of whether a previous one failed.
#
#  DEPLOYMENT ORDER
#  ────────────────
#  data → ai → automation → monitoring → coding
#
#  data-vm is first because Postgres must be running before n8n and Flowise
#  (automation-vm) attempt to connect, and before AnythingLLM (ai-vm) starts.
#  monitoring-vm is last because it scrapes the others; it is non-critical
#  for application functionality and safe to deploy out of order.
#
#  FAILURE HANDLING
#  ────────────────
#  Each VM is deployed in an isolated subshell (set -e inside a () block).
#  If the subshell exits non-zero, the exit code is captured and a warning
#  is printed. The parent shell continues to the next VM. A summary table
#  with pass/fail status for each VM is printed at the end.
#  Note: set -e is intentionally NOT set at the top level for this reason.
#
#  TO RETRY A FAILED VM:
#    bash deploy_vm.sh <vm-name>
#
#  REQUIREMENTS
#  ────────────
#  - Run as root on the Proxmox HOST
#  - All VMs must be running (created by 01_create_vms.sh)
#  - config.env must be populated (run init_secrets.sh first)
#  - SSH key in config.env must be in ~/.ssh/ on the local machine
#
#  USAGE
#  ─────
#    bash deploy_all.sh
# =============================================================================

# Note: -e is omitted intentionally so individual VM failures don't abort
# the script. Each VM runs in an isolated subshell with its own set -e.
set -uo pipefail
source "$(dirname "$0")/../config.env"

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# Associative array to collect per-VM results for the summary table
declare -A RESULTS=()

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Poll SSH on a remote host until it becomes available or a 3-minute timeout.
#
# Non-fatal: returns 1 on timeout rather than exiting, so the parent
# deploy_vm function can record a failure and continue.
#
# Arguments:
#   $1 - host  IP address to poll
#
# Returns:
#   0 if SSH becomes available, 1 on timeout
##
wait_for_ssh() {
    local host="$1"
    local max=36
    local count=0

    info "Waiting for SSH on ${host}..."
    while ! ssh $SSH_OPTS "${VM_USER}@${host}" "echo ok" &>/dev/null; do
        count=$((count + 1))
        if [[ $count -ge $max ]]; then
            warn "SSH timeout on ${host} after $((max * 5))s"
            return 1
        fi
        printf "  [%2d/%d] not ready...\r" "$count" "$max"
        sleep 5
    done
    echo ""
    info "SSH ready ✓"
    return 0
}

##
# Build a shell export block containing all config values from config.env.
#
# Outputs export statements with single-quoted values to prevent any
# special characters in secrets from being interpreted by the remote shell.
# This block is prepended to the remote SSH command for each VM.
#
# Arguments: none (reads config.env globals)
# Returns:   Prints the export block to stdout
##
build_env() {
    cat <<ENVEOF
export AI_VM_IP='${AI_VM_IP}'
export CODING_VM_IP='${CODING_VM_IP}'
export DATA_VM_IP='${DATA_VM_IP}'
export AUTOMATION_VM_IP='${AUTOMATION_VM_IP}'
export MONITORING_VM_IP='${MONITORING_VM_IP}'
export POSTGRES_PASSWORD='${POSTGRES_PASSWORD}'
export N8N_ENCRYPTION_KEY='${N8N_ENCRYPTION_KEY}'
export ANYTHINGLLM_JWT_SECRET='${ANYTHINGLLM_JWT_SECRET}'
export GRAFANA_ADMIN_PASSWORD='${GRAFANA_ADMIN_PASSWORD}'
export BASE_DOMAIN='${BASE_DOMAIN}'
export VM_USER='${VM_USER}'
export CODING_USER='${VM_USER}'
ENVEOF
}

##
# Deploy a single VM and record its result in the RESULTS associative array.
#
# Runs the full deploy sequence (SSH wait, SCP, setup.sh) inside an isolated
# subshell. If the subshell exits non-zero, the failure is caught and
# recorded without aborting the parent script.
#
# Arguments:
#   $1 - label   Short name used in the summary table (e.g. "ai")
#   $2 - host    VM IP address
#   $3 - subdir  Local subdirectory containing the VM's setup.sh
#
# Side effects:
#   Sets RESULTS[$label] to a coloured success or failure string
##
deploy_vm() {
    local label="$1"
    local host="$2"
    local subdir="$3"

    section "Deploying: ${label} (${host})"

    # Isolated subshell: set -e applies only here; failures don't escape
    (
        set -e
        wait_for_ssh "$host"
        scp $SSH_OPTS -r "${SCRIPT_DIR}/../vms/${subdir}" "${VM_USER}@${host}:/home/${VM_USER}/"
        scp $SSH_OPTS -r "${SCRIPT_DIR}/../vms/common" "${VM_USER}@${host}:/home/${VM_USER}/"
        local env_block
        env_block="$(build_env)"
        ssh $SSH_OPTS -t "${VM_USER}@${host}" "
            ${env_block}
            cd /home/${VM_USER}/${subdir}
            chmod +x setup.sh
            sudo -E bash setup.sh
        "
    )

    local code=$?
    if [[ $code -eq 0 ]]; then
        RESULTS[$label]="${GREEN}✓ SUCCESS${NC}"
        info "✓ ${label} complete"
    else
        RESULTS[$label]="${RED}✗ FAILED (exit ${code})${NC}"
        warn "✗ ${label} failed — to retry: bash deploy_vm.sh ${label}"
    fi
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

# Validate secrets before touching any VM
if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    echo -e "${RED}[ERROR]${NC} Secrets not initialised. Run:  bash init_secrets.sh"
    exit 1
fi

section "Full Stack Deployment"
info "Order: data → ai → automation → monitoring → coding"
info "Each VM is attempted even if a previous one failed."

# data-vm first: Postgres must be running before n8n, Flowise, and AnythingLLM start
deploy_vm "data"       "$DATA_VM_IP"       "data"
info "Pausing 10s for Postgres to complete initialisation..."
sleep 10

deploy_vm "ai"         "$AI_VM_IP"         "ai"
deploy_vm "automation" "$AUTOMATION_VM_IP" "automation"
deploy_vm "monitoring" "$MONITORING_VM_IP" "monitoring"
deploy_vm "coding"     "$CODING_VM_IP"     "coding"

# ---------------------------------------------------------------------------
#  Summary table
# ---------------------------------------------------------------------------
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "  Deployment Summary"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"

for vm in data ai automation monitoring coding; do
    local_status="${RESULTS[$vm]:-${YELLOW}? NOT RUN${NC}}"
    printf "  %-14s → " "$vm"
    echo -e "$local_status"
done

echo ""
echo -e "${BLUE}  Service Access URLs${NC}"
echo "  ──────────────────────────────────────────────────────"
echo "  Open WebUI     → http://${AI_VM_IP}:3000"
echo "  AnythingLLM    → http://${AI_VM_IP}:3001"
echo "  Ollama API     → http://${AI_VM_IP}:11434"
echo "  Qdrant UI      → http://${AI_VM_IP}:6333/dashboard"
echo "  Whisper API    → http://${AI_VM_IP}:8000"
echo "  pgAdmin        → http://${DATA_VM_IP}:5050"
echo "  n8n            → http://${AUTOMATION_VM_IP}:5678"
echo "  Flowise        → http://${AUTOMATION_VM_IP}:3002"
echo "  Grafana        → http://${MONITORING_VM_IP}:3003"
echo "  Prometheus     → http://${MONITORING_VM_IP}:9090"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
