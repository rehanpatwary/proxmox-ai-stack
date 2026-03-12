#!/usr/bin/env bash
# =============================================================================
#  wire_lxc_to_vms.sh — Post-Deploy LXC Configuration Patcher
#
#  Community-scripts LXC containers write their configuration to files at
#  install time and do not re-read environment variables at runtime. This
#  script runs after LXC containers are deployed and patches each container's
#  config files to point at the correct VM service IPs.
#
#  WHAT IT PATCHES
#  ───────────────
#  Container     Config file               Connected to
#  ──────────────────────────────────────────────────────────────────────────
#  paperless-ai  .env                      Ollama on ai-vm
#  flowise       .env (if LXC)             Postgres + Ollama
#  monica        .env + artisan cache      Postgres on data-vm
#  bookstack     .env + artisan cache      Postgres on data-vm
#  outline       .env                      Postgres on data-vm
#  mattermost    config.json               Postgres on data-vm
#  keycloak      keycloak.conf             Postgres on data-vm
#
#  ADDITIONAL ACTIONS
#  ──────────────────
#  - Creates missing Postgres databases (outline, mattermost, keycloak, etc.)
#  - Prints the Nginx Proxy Manager routing table
#  - Lists Uptime Kuma monitor URLs
#
#  IDEMPOTENT
#  ──────────
#  Each patch uses sed in-place to replace specific config keys. Running the
#  script multiple times is safe — the replacement is idempotent.
#
#  DRY RUN
#  ───────
#  Pass --dry-run to print what would be done without modifying anything.
#
#  REQUIREMENTS
#  ────────────
#  - Run as root on the Proxmox HOST (uses pct exec to reach containers)
#  - Target containers must be running
#  - psql must be available on the host or reachable for DB creation
#
#  USAGE
#  ─────
#    bash wire_lxc_to_vms.sh --dry-run   preview
#    bash wire_lxc_to_vms.sh             apply
#    # Then restart affected containers:
#    pct restart <CTID>
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34d'; NC='\033[0m'
BLUE='\033[0;34m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

DRY_RUN="${1:-}"

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Execute a command inside a named LXC container via  pct exec.
#
# Looks up the container ID by matching the NAME column in  pct list.
# Prints a warning and returns 0 (does not abort) if the container is not
# found or not running.
#
# Arguments:
#   $1     - ct_name  Container name as shown in  pct list
#   $2..n  - command  Command string to execute inside the container
#
# Returns:
#   0 if command ran (or container skipped), non-zero on execution error
##
ct_exec() {
    local ct_name="$1"; shift
    local cmd="$*"
    local ctid

    ctid=$(pct list 2>/dev/null | awk -v name="$ct_name" '$3==name {print $1}' | head -1)

    if [[ -z "$ctid" ]]; then
        warn "Container '$ct_name' not found in  pct list  — skipping"
        return 0
    fi

    if ! pct status "$ctid" | grep -q "running"; then
        warn "Container '$ct_name' (CT $ctid) is not running — skipping"
        return 0
    fi

    info "  [$ct_name] CT $ctid: $cmd"
    [[ "$DRY_RUN" == "--dry-run" ]] && return 0
    pct exec "$ctid" -- bash -c "$cmd"
}

##
# Get the primary IP address of a named LXC container.
#
# Arguments:
#   $1 - ct_name  Container name
#
# Returns:
#   Prints the IP to stdout, or "unknown" if container not found
##
ct_ip() {
    local ct_name="$1"
    local ctid

    ctid=$(pct list 2>/dev/null | awk -v name="$ct_name" '$3==name {print $1}' | head -1)
    [[ -z "$ctid" ]] && echo "unknown" && return 0

    pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown"
}

##
# Create a Postgres database on data-vm if it does not already exist.
#
# Connects to the Postgres instance at DATA_VM_IP using the superuser
# credentials from config.env. Skips silently if the database exists.
#
# Arguments:
#   $1 - db_name  Database name to create
##
create_db_if_missing() {
    local db_name="$1"

    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        echo "  [dry-run] CREATE DATABASE IF NOT EXISTS $db_name"
        return 0
    fi

    PGPASSWORD="${POSTGRES_PASSWORD}" psql \
        -h "$DATA_VM_IP" -U postgres \
        -tc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" \
        | grep -q 1 \
        && info "  DB '$db_name' already exists" \
        || {
            PGPASSWORD="${POSTGRES_PASSWORD}" psql \
                -h "$DATA_VM_IP" -U postgres \
                -c "CREATE DATABASE ${db_name};"
            info "  Created DB: $db_name ✓"
        }
}

# ---------------------------------------------------------------------------
#  Per-service wiring
# ---------------------------------------------------------------------------

##
# Patch Paperless-AI to use Ollama on ai-vm.
##
wire_paperless_ai() {
    section "Paperless-AI → Ollama (${AI_VM_IP}:11434)"
    ct_exec "paperless-ai" "
        CONFIG_FILE=\$(find /opt /app /home -name '*.env' 2>/dev/null | head -1)
        if [[ -f \"\$CONFIG_FILE\" ]]; then
            sed -i 's|http://localhost:11434|http://${AI_VM_IP}:11434|g' \"\$CONFIG_FILE\"
            sed -i 's|OLLAMA_HOST=.*|OLLAMA_HOST=${AI_VM_IP}|g' \"\$CONFIG_FILE\"
            echo Patched: \$CONFIG_FILE
        fi
    "
}

##
# Patch Flowise (if deployed as LXC) to use Postgres and Ollama on VMs.
# Note: Flowise should normally be in automation-vm; this handles the edge
# case where it was also deployed as an LXC container.
##
wire_flowise() {
    section "Flowise (if LXC) → Postgres + Ollama"
    ct_exec "flowise" "
        ENV=\$(find /root/.flowise /opt/flowise -name '.env' 2>/dev/null | head -1)
        if [[ -f \"\$ENV\" ]]; then
            sed -i 's|DATABASE_HOST=.*|DATABASE_HOST=${DATA_VM_IP}|g' \"\$ENV\"
            sed -i 's|DATABASE_PASSWORD=.*|DATABASE_PASSWORD=${POSTGRES_PASSWORD}|g' \"\$ENV\"
            sed -i 's|OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://${AI_VM_IP}:11434|g' \"\$ENV\"
            echo Patched: \$ENV
        fi
    "
}

##
# Patch Monica CRM to use Postgres on data-vm.
##
wire_monica() {
    section "Monica CRM → Postgres (${DATA_VM_IP}:5432)"
    ct_exec "monica" "
        ENV=\$(find /var/www /opt /home -name '.env' 2>/dev/null | head -1)
        if [[ -f \"\$ENV\" ]]; then
            sed -i 's|DB_HOST=.*|DB_HOST=${DATA_VM_IP}|g' \"\$ENV\"
            sed -i 's|DB_PASSWORD=.*|DB_PASSWORD=${POSTGRES_PASSWORD}|g' \"\$ENV\"
            cd \$(dirname \"\$ENV\") && php artisan config:cache 2>/dev/null || true
            echo Patched: \$ENV
        fi
    "
}

##
# Patch BookStack to use Postgres on data-vm.
##
wire_bookstack() {
    section "BookStack → Postgres (${DATA_VM_IP}:5432)"
    ct_exec "bookstack" "
        ENV=/var/www/bookstack/.env
        if [[ -f \"\$ENV\" ]]; then
            sed -i 's|DB_HOST=.*|DB_HOST=${DATA_VM_IP}|g' \"\$ENV\"
            sed -i 's|DB_PASS=.*|DB_PASS=${POSTGRES_PASSWORD}|g' \"\$ENV\"
            php /var/www/bookstack/artisan config:cache 2>/dev/null || true
            echo Patched: \$ENV
        fi
    "
}

##
# Patch Outline to use Postgres on data-vm.
# Outline uses a full connection URL rather than individual host/password vars.
##
wire_outline() {
    section "Outline → Postgres (${DATA_VM_IP}:5432)"
    ct_exec "outline" "
        ENV=\$(find /opt/outline -name '.env' 2>/dev/null | head -1)
        if [[ -f \"\$ENV\" ]]; then
            sed -i 's|DATABASE_URL=postgresql://.*|DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@${DATA_VM_IP}:5432/outline|g' \"\$ENV\"
            echo Patched: \$ENV
        fi
    "
}

##
# Patch Mattermost to use Postgres on data-vm.
# Uses jq for JSON editing if available; falls back to sed.
##
wire_mattermost() {
    section "Mattermost → Postgres (${DATA_VM_IP}:5432)"
    ct_exec "mattermost" "
        CONFIG=\$(find /opt/mattermost /etc/mattermost -name 'config.json' 2>/dev/null | head -1)
        if [[ -f \"\$CONFIG\" ]]; then
            if command -v jq >/dev/null; then
                tmp=\$(mktemp)
                jq '.SqlSettings.DataSource = \"postgres://postgres:${POSTGRES_PASSWORD}@${DATA_VM_IP}:5432/mattermost?sslmode=disable\"' \
                    \"\$CONFIG\" > \"\$tmp\" && mv \"\$tmp\" \"\$CONFIG\"
            else
                sed -i 's|\"DataSource\":.*|\"DataSource\": \"postgres://postgres:${POSTGRES_PASSWORD}@${DATA_VM_IP}:5432/mattermost?sslmode=disable\",|g' \
                    \"\$CONFIG\"
            fi
            echo Patched: \$CONFIG
        fi
    "
}

##
# Patch Keycloak to use Postgres on data-vm.
##
wire_keycloak() {
    section "Keycloak → Postgres (${DATA_VM_IP}:5432)"
    ct_exec "keycloak" "
        KC_CONF=\$(find /opt /etc/keycloak -name 'keycloak.conf' 2>/dev/null | head -1)
        if [[ -f \"\$KC_CONF\" ]]; then
            sed -i 's|db-url=.*|db-url=jdbc:postgresql://${DATA_VM_IP}:5432/keycloak|g' \"\$KC_CONF\"
            sed -i 's|db-password=.*|db-password=${POSTGRES_PASSWORD}|g' \"\$KC_CONF\"
            echo Patched: \$KC_CONF
        fi
    "
}

##
# Print the Nginx Proxy Manager routing table and the NPM admin URL.
#
# Does not modify anything — provides the operator with the proxy host
# configuration to enter in the NPM web UI.
##
print_npm_routing_table() {
    section "Nginx Proxy Manager — Suggested Proxy Hosts"

    local npm_ctid
    npm_ctid=$(pct list 2>/dev/null | awk '$3=="nginx-proxy" {print $1}' | head -1)

    if [[ -z "$npm_ctid" ]]; then
        warn "nginx-proxy container not found — skipping routing table"
        return 0
    fi

    local npm_ip
    npm_ip=$(pct exec "$npm_ctid" -- hostname -I 2>/dev/null | awk '{print $1}')

    info "NPM admin: http://${npm_ip}:81  (default: admin@example.com / changeme)"
    echo ""
    printf "  %-32s → %s\n" "Subdomain" "Forward to"
    printf "  %-32s   %s\n" "────────────────────────────────" "────────────────────────────────"
    printf "  %-32s → %s\n" "chat.${BASE_DOMAIN}"    "${AI_VM_IP}:3000   (Open WebUI)"
    printf "  %-32s → %s\n" "docs.${BASE_DOMAIN}"    "${AI_VM_IP}:3001   (AnythingLLM)"
    printf "  %-32s → %s\n" "ollama.${BASE_DOMAIN}"  "${AI_VM_IP}:11434  (Ollama API)"
    printf "  %-32s → %s\n" "n8n.${BASE_DOMAIN}"     "${AUTOMATION_VM_IP}:5678"
    printf "  %-32s → %s\n" "flowise.${BASE_DOMAIN}" "${AUTOMATION_VM_IP}:3002"
    printf "  %-32s → %s\n" "grafana.${BASE_DOMAIN}" "${MONITORING_VM_IP}:3003"
    printf "  %-32s → %s\n" "db.${BASE_DOMAIN}"      "${DATA_VM_IP}:5050 (pgAdmin)"
    echo ""
    info "Enable 'Websockets Support' for Open WebUI, AnythingLLM, n8n, and Flowise."
}

##
# Create Postgres databases needed by LXC containers that were deployed.
#
# Only creates a database if the corresponding LXC container is present
# (i.e. was actually deployed). This avoids creating unused databases.
##
create_lxc_databases() {
    section "Creating Postgres databases for LXC containers"

    if ! command -v psql &>/dev/null; then
        warn "psql not found on host — install postgresql-client or create DBs manually"
        return 0
    fi

    # Only create DBs for containers that are actually running
    local services_and_dbs=(
        "outline:outline"
        "mattermost:mattermost"
        "keycloak:keycloak"
        "monica:monica"
        "bookstack:bookstack"
    )

    for entry in "${services_and_dbs[@]}"; do
        local ct_name="${entry%%:*}"
        local db_name="${entry##*:}"
        local ctid
        ctid=$(pct list 2>/dev/null | awk -v name="$ct_name" '$3==name {print $1}' | head -1)
        if [[ -n "$ctid" ]]; then
            create_db_if_missing "$db_name"
        fi
    done
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

[[ "$DRY_RUN" == "--dry-run" ]] && \
    echo -e "${YELLOW}[DRY RUN]${NC} No changes will be made.\n"

wire_paperless_ai
wire_flowise
wire_monica
wire_bookstack
wire_outline
wire_mattermost
wire_keycloak
create_lxc_databases
print_npm_routing_table

# ---------------------------------------------------------------------------
#  Post-run instructions
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "  Wiring complete."
echo ""
echo -e "  ${YELLOW}Restart affected containers to apply config changes:${NC}"
echo "    pct restart <CTID>"
echo ""
echo "  List all containers with their IDs:"
echo "    pct list"
echo ""
echo "  Check deployment status:"
echo "    bash deploy_lxc_stack.sh --status"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
