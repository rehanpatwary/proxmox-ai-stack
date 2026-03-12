#!/usr/bin/env bash
# =============================================================================
#  deploy_vm.sh — Single VM Deployment
#
#  Deploys one VM independently of the others. Use this to:
#    - Deploy VMs in a custom order
#    - Redeploy a single VM after a failure
#    - Deploy a VM for the first time without running the full stack
#
#  WHAT IT DOES
#  ────────────
#  1. Resolves the VM name to its IP address and script subdirectory
#  2. Waits for SSH to become available on the VM (up to 3 minutes)
#  3. Copies the VM's script directory to the VM over SCP
#  4. SSHes into the VM and runs setup.sh with all config values exported
#
#  CONFIG PASSING
#  ──────────────
#  Values from config.env are exported as shell variables in the remote SSH
#  session using build_env_block(). Each value is single-quoted to prevent
#  shell interpretation of special characters (e.g. passwords with $, !, etc).
#  The remote setup.sh is invoked with  sudo -E  to preserve the exports
#  when switching to root.
#
#  USAGE
#  ─────
#    bash deploy_vm.sh <vm>               deploy the named VM
#    bash deploy_vm.sh <vm> --dry-run     show what would run, no changes
#    bash deploy_vm.sh <vm> --no-wait     skip SSH readiness check
#
#  VALID VM NAMES:  ai | data | automation | monitoring | coding
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# ---------------------------------------------------------------------------
#  Argument parsing
# ---------------------------------------------------------------------------
VM_NAME=""
DRY_RUN=0
NO_WAIT=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1  ;;
        --no-wait) NO_WAIT=1  ;;
        *)         VM_NAME="$arg" ;;
    esac
done

if [[ -z "$VM_NAME" ]]; then
    echo "Usage: bash deploy_vm.sh <vm> [--dry-run] [--no-wait]"
    echo "       vm = ai | data | automation | monitoring | coding"
    exit 1
fi

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Resolve a VM short name to its IP address and script subdirectory.
#
# Sets globals VM_IP and SUBDIR based on the VM name from config.env.
# Exits 1 with a usage message if the name is not recognised.
#
# Arguments:
#   $1 - vm_name  Short VM name (ai, data, automation, monitoring, coding)
#
# Side effects:
#   Sets global variables VM_IP and SUBDIR
##
resolve_vm() {
    local vm_name="$1"
    case "$vm_name" in
        ai)         VM_IP="$AI_VM_IP";         SUBDIR="ai-vm"         ;;
        data)       VM_IP="$DATA_VM_IP";       SUBDIR="data-vm"       ;;
        automation) VM_IP="$AUTOMATION_VM_IP"; SUBDIR="automation-vm" ;;
        monitoring) VM_IP="$MONITORING_VM_IP"; SUBDIR="monitoring"    ;;
        coding)     VM_IP="$CODING_VM_IP";     SUBDIR="coding-vm"     ;;
        *)
            error "Unknown VM: '$vm_name'. Valid names: ai | data | automation | monitoring | coding"
            ;;
    esac
}

##
# Build a shell export block containing all config values from config.env.
#
# Outputs a multi-line string of  export KEY='VALUE'  statements.
# Single-quoting prevents any special characters in values (e.g. $, !, @)
# from being interpreted by the remote shell.
#
# This block is injected at the start of the remote SSH command so that
# setup.sh receives the full configuration when invoked via  sudo -E.
#
# Arguments: none (reads from config.env globals)
# Returns:   Prints the export block to stdout
##
build_env_block() {
    cat <<ENVBLOCK
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
ENVBLOCK
}

##
# Poll SSH on a remote host until it becomes available or timeout is reached.
#
# Attempts a no-op SSH command every 5 seconds for up to MAX*5 seconds.
# Uses BatchMode=yes to prevent hanging on password prompts.
# Exits 1 after MAX attempts with a timeout error.
#
# Arguments:
#   $1 - host  IP address or hostname to poll
##
wait_for_ssh() {
    local host="$1"
    local max=36    # 36 * 5s = 3 minutes maximum wait
    local count=0

    section "Waiting for SSH on ${host}"

    until ssh $SSH_OPTS "${VM_USER}@${host}" "echo ok" &>/dev/null; do
        count=$((count + 1))
        [[ $count -ge $max ]] && error "Timeout: SSH not available on ${host} after $((max * 5))s"
        printf "  [%2d/%d] not ready yet...\r" "$count" "$max"
        sleep 5
    done

    echo ""
    info "SSH ready ✓"
}

##
# Copy the VM's setup script directory to the remote VM over SCP.
#
# Transfers the entire SUBDIR folder to /home/VM_USER/ on the remote VM.
# Existing files are overwritten, allowing repeated deploys to pick up
# script changes without manual cleanup.
#
# Arguments:
#   $1 - host    Target VM IP address
#   $2 - subdir  Local subdirectory name (e.g. "ai-vm")
##
copy_scripts() {
    local host="$1"
    local subdir="$2"

    section "Copying scripts → ${VM_NAME} (${host})"
    scp $SSH_OPTS -r "${SCRIPT_DIR}/${subdir}/" "${VM_USER}@${host}:/home/${VM_USER}/"
    info "Scripts copied to /home/${VM_USER}/${subdir}/ ✓"
}

##
# SSH into the VM and execute setup.sh with the full config environment.
#
# The env block from build_env_block() is prepended to the remote command
# so all config values are in scope when setup.sh runs under sudo -E.
# -t allocates a pseudo-TTY so output streams correctly in real time.
#
# Arguments:
#   $1 - host    Target VM IP address
#   $2 - subdir  Remote subdirectory where setup.sh was copied
##
run_setup() {
    local host="$1"
    local subdir="$2"
    local env_block

    section "Running setup on ${VM_NAME} (${host})"
    info "Output streamed live:"
    echo ""

    env_block="$(build_env_block)"

    ssh $SSH_OPTS -t "${VM_USER}@${host}" "
${env_block}
cd /home/${VM_USER}/${subdir}
chmod +x setup.sh
sudo -E bash setup.sh
"
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

resolve_vm "$VM_NAME"

# Validate secrets are initialised before attempting any deployment
if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    error "Secrets not initialised. Run:  bash init_secrets.sh"
fi

# Dry run: show what would happen without executing
if [[ $DRY_RUN -eq 1 ]]; then
    section "DRY RUN — would deploy: $VM_NAME"
    echo "  Target IP  : $VM_IP"
    echo "  Script dir : $SCRIPT_DIR/$SUBDIR"
    echo ""
    echo "  Environment that would be exported:"
    build_env_block | sed 's/^/    /'
    exit 0
fi

[[ $NO_WAIT -eq 0 ]] && wait_for_ssh "$VM_IP"

copy_scripts "$VM_IP" "$SUBDIR"
run_setup    "$VM_IP" "$SUBDIR"

echo ""
info "✓ ${VM_NAME} deployment complete"
