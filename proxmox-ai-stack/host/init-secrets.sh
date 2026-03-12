#!/usr/bin/env bash
# =============================================================================
#  init_secrets.sh — One-time Secret Initialiser
#
#  Generates cryptographically random secrets and writes them as static
#  string values into config.env. Must be run ONCE before any deployment.
#
#  IDEMPOTENT: Re-running this script is safe. Any secret that already has
#  a non-empty value in config.env is skipped — existing values are never
#  overwritten. This means credentials stay consistent across re-deployments.
#
#  WHY THIS EXISTS
#  ───────────────
#  Shell config files are sourced (not executed as a subprocess), so any
#  $(openssl rand ...) call inside config.env re-runs on every source,
#  producing a new value each time. This breaks services that read the
#  password at connection time versus at server-setup time.
#  init_secrets.sh solves this by generating once and writing static strings.
#
#  USAGE
#  ─────
#    bash init_secrets.sh
#
#  Run from the repo root directory (same level as config.env).
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

##
# Print a green INFO message to stdout.
# Arguments: $@ — message text
##
info() { echo -e "${GREEN}[INFO]${NC} $*"; }

##
# Print a yellow SKIP message to stdout.
# Arguments: $@ — message text
##
skip() { echo -e "${YELLOW}[SKIP]${NC} $* — already set, not overwriting"; }

##
# Print a red ERROR message and exit 1.
# Arguments: $@ — message text
##
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
#  Locate config.env relative to this script, not $PWD
# ---------------------------------------------------------------------------
CONFIG="$(cd "$(dirname "$0")" && pwd)/../config.env"
[[ ! -f "$CONFIG" ]] && error "config.env not found at: $CONFIG"

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Write a secret into config.env only if its current value is empty.
#
# Reads the current value of KEY from config.env by extracting the string
# between the first pair of double-quotes on the matching line.
# If the value is non-empty (already initialised), prints a SKIP message.
# If the value is empty, replaces KEY="" with KEY="VALUE" using sed in-place.
#
# Arguments:
#   $1 - KEY    Variable name as it appears in config.env (e.g. POSTGRES_PASSWORD)
#   $2 - VALUE  The generated secret string to write
#
# Side effects:
#   Modifies config.env in-place if the value was previously empty.
##
set_secret() {
    local key="$1"
    local value="$2"

    # Extract current value — everything between the outer double-quotes
    local current
    current=$(grep "^${key}=" "$CONFIG" | cut -d'"' -f2)

    if [[ -n "$current" ]]; then
        skip "$key"
        return 0
    fi

    # Replace  KEY=""  with  KEY="VALUE"  — sed matches the exact empty form
    sed -i "s|^${key}=\"\"|${key}=\"${value}\"|" "$CONFIG"
    info "$key generated and saved"
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

echo ""
info "Initialising secrets in config.env..."
info "Existing values will not be changed."
echo ""

# Generate and persist each secret.
# openssl rand -hex N produces a N*2 character lowercase hex string.
set_secret "POSTGRES_PASSWORD"      "$(openssl rand -hex 16)"   # 32 chars
set_secret "ANYTHINGLLM_JWT_SECRET" "$(openssl rand -hex 32)"   # 64 chars
set_secret "N8N_ENCRYPTION_KEY"     "$(openssl rand -hex 24)"   # 48 chars

echo ""
info "Current secret values in config.env:"
echo ""
grep -E "^(POSTGRES_PASSWORD|ANYTHINGLLM_JWT_SECRET|N8N_ENCRYPTION_KEY|GRAFANA_ADMIN_PASSWORD)=" \
    "$CONFIG"
echo ""
echo -e "${GREEN}These values are now static strings. Re-running this script will not change them.${NC}"
echo ""
echo "Next step:"
echo "  bash deploy_all.sh          — deploy all VMs at once"
echo "  bash deploy_vm.sh <name>    — deploy a single VM"
