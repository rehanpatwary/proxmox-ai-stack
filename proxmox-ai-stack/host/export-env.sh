#!/usr/bin/env bash
# =============================================================================
#  export_env.sh — Manual Environment Export Helper
#
#  Prints a block of  export KEY='VALUE'  statements for a specific VM,
#  sourced from config.env. Use this when you are already inside a VM and
#  need to run setup.sh manually without going through deploy_vm.sh.
#
#  USAGE PATTERNS
#  ──────────────
#  Pattern A — print exports, copy-paste into VM terminal:
#    On Proxmox host:    bash export_env.sh ai
#    Copy output.
#    On ai-vm terminal:  <paste>
#                        sudo -E bash ~/ai-vm/setup.sh
#
#  Pattern B — one-liner from Proxmox host:
#    ssh ubuntu@192.168.1.10 "$(bash export_env.sh ai) && sudo -E bash ~/ai-vm/setup.sh"
#
#  Pattern C — save to file, copy to VM, source it there:
#    bash export_env.sh ai > /tmp/ai_env.sh
#    scp /tmp/ai_env.sh ubuntu@192.168.1.10:~/
#    ssh ubuntu@192.168.1.10
#    source ~/ai_env.sh && sudo -E bash ~/ai-vm/setup.sh
#
#  WHY sudo -E
#  ───────────
#  The -E flag tells sudo to preserve the current user's environment variables
#  when switching to root. Without it, all the exported values are dropped
#  and setup.sh cannot read them.
#
#  VALID VM NAMES:  ai | data | automation | monitoring | coding
# =============================================================================
source "$(dirname "$0")/config.env"

# ---------------------------------------------------------------------------
#  Argument validation
# ---------------------------------------------------------------------------
VM_NAME="${1:-}"

if [[ -z "$VM_NAME" ]]; then
    echo "Usage: bash export_env.sh <vm>"
    echo "       vm = ai | data | automation | monitoring | coding"
    exit 1
fi

# Validate the VM name is recognised (purely informational — the export block
# does not change per-VM, but validation catches typos early)
case "$VM_NAME" in
    ai | data | automation | monitoring | coding) ;;
    *) echo "Unknown VM: '$VM_NAME'. Valid names: ai | data | automation | monitoring | coding"
       exit 1 ;;
esac

# ---------------------------------------------------------------------------
#  Output the export block
#
# Values are single-quoted to prevent any special characters in secrets
# (e.g. $, !, @, #) from being interpreted by the shell that receives
# this output.
# ---------------------------------------------------------------------------
cat <<EXPORTS
# ── Proxmox AI Stack — Environment for: ${VM_NAME} ───────────────
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
EXPORTS
