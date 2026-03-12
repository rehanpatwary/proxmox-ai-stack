#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# Proxmox AI & Business Automation Stack - Automated Deployment Pipeline
# ==========================================================================
# Deploys a complete AI, Agentic AI, and Business Automation stack
# on Proxmox VE using community-scripts.github.io/ProxmoxVE
#
# Usage:
#   chmod +x proxmox-ai-business-deploy.sh
#   ./proxmox-ai-business-deploy.sh              # Interactive menu
#   ./proxmox-ai-business-deploy.sh --all        # Deploy everything
#   ./proxmox-ai-business-deploy.sh --phase 1    # Deploy Phase 1 only
#   ./proxmox-ai-business-deploy.sh --list       # List all apps
#   ./proxmox-ai-business-deploy.sh --status     # Check deployment status
#
# Prerequisites:
#   - Run as root on Proxmox VE host
#   - Internet connectivity
#   - Sufficient storage (recommend 500GB+ on target storage)
#
# Network: All CTs get DHCP by default. Set NETWORK_MODE=static for static IPs.
# ==========================================================================

# ========================= CONFIGURATION =========================

BASE_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"
SCRIPT_LOG="/var/log/proxmox-ai-deploy.log"
DEPLOY_STATE="/root/.proxmox-ai-deploy-state"
START_VMID="${START_VMID:-400}"

# Network config
NETWORK_MODE="${NETWORK_MODE:-dhcp}"       # dhcp or static
STATIC_SUBNET="${STATIC_SUBNET:-10.0.3}"   # Used if NETWORK_MODE=static
BRIDGE="${BRIDGE:-vmbr0}"
DNS="${DNS:-1.1.1.1}"
GATEWAY="${GATEWAY:-10.0.3.1}"

# Storage
STORAGE="${STORAGE:-local-lvm}"

# Deploy behavior
AUTO_START="${AUTO_START:-1}"               # Start CTs after creation
PAUSE_BETWEEN="${PAUSE_BETWEEN:-10}"       # Seconds between deployments
DRY_RUN="${DRY_RUN:-0}"                    # 1 = show what would be done

# ========================= COLOR HELPERS =========================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$SCRIPT_LOG"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*" | tee -a "$SCRIPT_LOG"; }
err()  { echo -e "${RED}[✗]${NC} $*" | tee -a "$SCRIPT_LOG"; }
info() { echo -e "${BLUE}[→]${NC} $*" | tee -a "$SCRIPT_LOG"; }
header() {
  echo "" | tee -a "$SCRIPT_LOG"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════${NC}" | tee -a "$SCRIPT_LOG"
  echo -e "${CYAN}${BOLD}  $*${NC}" | tee -a "$SCRIPT_LOG"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════${NC}" | tee -a "$SCRIPT_LOG"
}

# ========================= APP DEFINITIONS =========================
# Format: "VMID|NAME|SCRIPT_NAME|TYPE|CPU|RAM|DISK|PHASE|CATEGORY|DESCRIPTION"

declare -a APPS=(
  # ── Phase 1: Infrastructure ──
  "400|docker|docker|ct|2|2048|20|1|Infrastructure|Docker container runtime"
  "401|postgresql|postgresql|ct|2|2048|20|1|Infrastructure|PostgreSQL database"
  "402|redis|redis|ct|1|1024|8|1|Infrastructure|Redis in-memory cache"
  "403|mariadb|mariadb|ct|2|2048|20|1|Infrastructure|MariaDB database"
  "404|nginx-proxy|nginxproxymanager|ct|1|1024|8|1|Infrastructure|Nginx Proxy Manager (SSL/reverse proxy)"
  "405|vaultwarden|vaultwarden|ct|1|1024|8|1|Infrastructure|Bitwarden password manager"
  "406|adguard|adguard|ct|1|512|4|1|Infrastructure|AdGuard DNS ad blocker"
  "407|wireguard|wireguard|ct|1|512|4|1|Infrastructure|WireGuard VPN"

  # ── Phase 2: AI & LLM Stack ──
  "410|ollama|ollama|ct|4|8192|60|2|AI|Ollama LLM inference engine"
  "411|open-webui|openwebui|ct|2|2048|16|2|AI|ChatGPT-style UI for Ollama"
  "412|flowise|flowiseai|ct|2|2048|12|2|AI-Agents|FlowiseAI - drag-and-drop AI agent builder"
  "413|litellm|litellm|ct|2|2048|10|2|AI|LiteLLM unified LLM API proxy"
  "414|searxng|searxng|ct|2|2048|8|2|AI|SearXNG metasearch (for RAG pipelines)"
  "415|qdrant|qdrant|ct|2|4096|20|2|AI|Qdrant vector database"
  "416|jupyter|jupyternotebook|ct|2|4096|20|2|AI|Jupyter Notebook for data science"
  "417|comfyui|comfyui|ct|4|8192|60|2|AI|ComfyUI - AI image generation"
  "418|libretranslate|libretranslate|ct|2|2048|10|2|AI|Self-hosted AI translation"
  "419|apache-tika|apache-tika|ct|2|2048|10|2|AI|Content detection and extraction"

  # ── Phase 3: Automation & Agentic ──
  "420|n8n|n8n|ct|2|2048|10|3|Automation|n8n workflow automation (AI nodes)"
  "421|node-red|node-red|ct|1|1024|8|3|Automation|Node-RED flow-based automation"
  "422|semaphore|semaphore|ct|2|2048|10|3|Automation|Ansible UI for server automation"
  "423|cronicle|cronicle|ct|1|1024|8|3|Automation|Multi-server task scheduler"
  "424|coolify|coolify|ct|2|2048|30|3|Automation|Self-hosted PaaS (Heroku alternative)"
  "425|changedetection|changedetection|ct|1|1024|8|3|Automation|Website change monitoring"

  # ── Phase 4: Business & ERP ──
  "430|odoo|odoo|ct|4|4096|40|4|Business|Odoo ERP (CRM/Accounting/HR/Inventory)"
  "431|invoice-ninja|invoiceninja|ct|2|2048|12|4|Finance|Invoice Ninja invoicing platform"
  "432|actual-budget|actualbudget|ct|1|1024|8|4|Finance|Actual Budget personal finance"
  "433|firefly|firefly|ct|2|2048|12|4|Finance|Firefly III finance manager"
  "434|ghostfolio|ghostfolio|ct|2|2048|10|4|Finance|Ghostfolio investment tracker"
  "435|kimai|kimai|ct|2|2048|10|4|Business|Kimai time tracking"
  "436|wallos|wallos|ct|1|1024|8|4|Finance|Wallos subscription tracker"
  "437|monica|monica|ct|2|2048|10|4|CRM|Monica personal CRM"
  "438|openproject|openproject|ct|4|4096|30|4|Business|OpenProject project management"
  "439|vikunja|vikunja|ct|2|2048|10|4|Business|Vikunja task management"
  "440|planka|planka|ct|1|1024|8|4|Business|Planka kanban board"
  "441|dolibarr|dolibarr|ct|2|2048|20|4|Business|Dolibarr ERP/CRM"

  # ── Phase 5: Documents & Knowledge ──
  "450|paperless|paperless-ngx|ct|2|2048|20|5|Documents|Paperless-ngx document management"
  "451|paperless-ai|paperless-ai|ct|2|2048|10|5|Documents|AI classification for Paperless"
  "452|stirling-pdf|stirling-pdf|ct|2|2048|8|5|Documents|Stirling PDF tools"
  "453|bookstack|bookstack|ct|2|2048|12|5|Knowledge|BookStack wiki/knowledge base"
  "454|outline|outline|ct|2|2048|12|5|Knowledge|Outline team knowledge base"
  "455|onlyoffice|onlyoffice|ct|2|4096|20|5|Documents|OnlyOffice document suite"
  "456|excalidraw|excalidraw|ct|1|1024|8|5|Documents|Excalidraw whiteboard"
  "457|drawio|drawio|ct|1|1024|8|5|Documents|Draw.io diagram editor"
  "458|trilium|trilium|ct|1|1024|8|5|Knowledge|Trilium personal knowledge base"
  "459|docmost|docmost|ct|2|2048|10|5|Knowledge|Docmost collaborative wiki"

  # ── Phase 6: Communication & Collaboration ──
  "460|mattermost|mattermost|ct|2|4096|20|6|Communication|Mattermost team messaging"
  "461|listmonk|listmonk|ct|1|1024|8|6|Communication|Listmonk newsletter manager"
  "462|ntfy|ntfy|ct|1|512|4|6|Communication|Ntfy push notifications"
  "463|element|elementsynapse|ct|2|2048|16|6|Communication|Element + Matrix encrypted chat"

  # ── Phase 7: Monitoring & Analytics ──
  "470|grafana|grafana|ct|2|2048|12|7|Monitoring|Grafana dashboards"
  "471|prometheus|prometheus|ct|2|2048|16|7|Monitoring|Prometheus metrics"
  "472|loki|loki|ct|2|2048|12|7|Monitoring|Loki log aggregation"
  "473|uptime-kuma|uptimekuma|ct|1|1024|8|7|Monitoring|Uptime Kuma service monitor"
  "474|umami|umami|ct|1|1024|8|7|Analytics|Umami web analytics"
  "475|homepage|homepage|ct|1|1024|8|7|Dashboard|Homepage app dashboard"
  "476|homarr|homarr|ct|1|1024|8|7|Dashboard|Homarr customizable dashboard"

  # ── Phase 8: Workspace & Storage ──
  "480|nextcloud-vm|nextcloud-vm|vm|4|4096|60|8|Workspace|Nextcloud files/calendar/office"
  "481|syncthing|syncthing|ct|1|1024|20|8|Storage|Syncthing peer-to-peer file sync"
  "482|minio|minio|ct|2|2048|50|8|Storage|MinIO S3-compatible storage"
  "483|duplicati|duplicati|ct|1|1024|8|8|Backup|Duplicati encrypted backup"
  "484|pbs|proxmox-backup-server|ct|2|2048|100|8|Backup|Proxmox Backup Server"

  # ── Phase 9: Security & Identity ──
  "490|keycloak|keycloak|ct|2|4096|16|9|Security|Keycloak SSO/identity management"
  "491|authelia|authelia|ct|1|1024|8|9|Security|Authelia authentication proxy"
  "492|headscale|headscale|ct|1|512|4|9|Security|Headscale (self-hosted Tailscale)"
  "493|crowdsec|bunkerweb|ct|2|2048|10|9|Security|BunkerWeb WAF/security"

  # ── Phase 10: Dev & Code ──
  "495|forgejo|forgejo|ct|2|2048|20|10|Dev|Forgejo Git hosting (Gitea fork)"
  "496|jenkins|jenkins|ct|2|4096|20|10|Dev|Jenkins CI/CD"
  "497|dockge|dockge|ct|1|1024|8|10|Dev|Dockge Docker Compose manager"
  "498|sonarqube|sonarqube|ct|4|4096|30|10|Dev|SonarQube code quality analysis"
  "499|it-tools|alpine-it-tools|ct|1|512|4|10|Dev|IT Tools collection"
)

# ========================= FUNCTIONS =========================

check_root() {
  [[ $EUID -eq 0 ]] || { err "Must run as root on Proxmox host."; exit 1; }
}

check_proxmox() {
  command -v pct >/dev/null 2>&1 || { err "pct not found. Are you on a Proxmox host?"; exit 1; }
  command -v pvesm >/dev/null 2>&1 || { err "pvesm not found."; exit 1; }
}

check_storage() {
  if ! pvesm status | awk '{print $1}' | grep -qx "$STORAGE"; then
    err "Storage '$STORAGE' not found."
    echo "Available storage:"
    pvesm status
    exit 1
  fi
}

init_state() {
  mkdir -p "$(dirname "$DEPLOY_STATE")"
  touch "$DEPLOY_STATE"
  mkdir -p "$(dirname "$SCRIPT_LOG")"
  touch "$SCRIPT_LOG"
}

is_deployed() {
  local name="$1"
  grep -qx "$name" "$DEPLOY_STATE" 2>/dev/null
}

mark_deployed() {
  local name="$1"
  echo "$name" >> "$DEPLOY_STATE"
}

vmid_in_use() {
  local vmid="$1"
  pct status "$vmid" >/dev/null 2>&1 || qm status "$vmid" >/dev/null 2>&1
}

parse_app() {
  local entry="$1"
  IFS='|' read -r A_VMID A_NAME A_SCRIPT A_TYPE A_CPU A_RAM A_DISK A_PHASE A_CAT A_DESC <<< "$entry"
}

get_next_free_vmid() {
  local vmid="$1"
  while vmid_in_use "$vmid"; do
    ((vmid++))
  done
  echo "$vmid"
}

deploy_ct() {
  local vmid="$1" name="$2" script="$3" cpu="$4" ram="$5" disk="$6"

  if is_deployed "$name"; then
    warn "[$name] Already deployed (skipping)"
    return 0
  fi

  vmid=$(get_next_free_vmid "$vmid")

  header "Deploying: $name (CT $vmid)"
  info "Script: $script | CPU: $cpu | RAM: ${ram}MB | Disk: ${disk}GB"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "[DRY RUN] Would deploy $name as CT $vmid"
    return 0
  fi

  # The community scripts are interactive by default.
  # We run them and pipe 'yes' to accept defaults.
  # Users should review settings after deployment.
  local script_url="${BASE_URL}/ct/${script}.sh"

  info "Downloading and executing: $script_url"

  # Export variables that the scripts read as defaults
  export var_cpu="$cpu"
  export var_ram="$ram"
  export var_disk="$disk"
  export var_brg="$BRIDGE"
  export var_net="dhcp"
  export CTID="$vmid"

  if bash -c "$(wget -qLO - "$script_url")" 2>&1 | tee -a "$SCRIPT_LOG"; then
    log "[$name] Deployed successfully as CT $vmid"
    mark_deployed "$name"
  else
    err "[$name] Deployment FAILED — check $SCRIPT_LOG"
    return 1
  fi

  sleep "$PAUSE_BETWEEN"
}

deploy_vm() {
  local vmid="$1" name="$2" script="$3" cpu="$4" ram="$5" disk="$6"

  if is_deployed "$name"; then
    warn "[$name] Already deployed (skipping)"
    return 0
  fi

  vmid=$(get_next_free_vmid "$vmid")

  header "Deploying: $name (VM $vmid)"
  info "Script: $script | CPU: $cpu | RAM: ${ram}MB | Disk: ${disk}GB"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "[DRY RUN] Would deploy $name as VM $vmid"
    return 0
  fi

  local script_url="${BASE_URL}/vm/${script}.sh"
  info "Downloading and executing: $script_url"

  if bash -c "$(wget -qLO - "$script_url")" 2>&1 | tee -a "$SCRIPT_LOG"; then
    log "[$name] Deployed successfully as VM $vmid"
    mark_deployed "$name"
  else
    err "[$name] Deployment FAILED — check $SCRIPT_LOG"
    return 1
  fi

  sleep "$PAUSE_BETWEEN"
}

deploy_app() {
  local entry="$1"
  parse_app "$entry"

  if [[ "$A_TYPE" == "vm" ]]; then
    deploy_vm "$A_VMID" "$A_NAME" "$A_SCRIPT" "$A_CPU" "$A_RAM" "$A_DISK"
  else
    deploy_ct "$A_VMID" "$A_NAME" "$A_SCRIPT" "$A_CPU" "$A_RAM" "$A_DISK"
  fi
}

deploy_phase() {
  local phase="$1"
  local phase_name=""
  case $phase in
    1) phase_name="Infrastructure" ;;
    2) phase_name="AI & LLM Stack" ;;
    3) phase_name="Automation & Agentic AI" ;;
    4) phase_name="Business, Finance & CRM" ;;
    5) phase_name="Documents & Knowledge" ;;
    6) phase_name="Communication & Collaboration" ;;
    7) phase_name="Monitoring & Analytics" ;;
    8) phase_name="Workspace & Storage" ;;
    9) phase_name="Security & Identity" ;;
    10) phase_name="Dev & Code" ;;
  esac

  header "PHASE $phase: $phase_name"

  local count=0
  local failed=0
  for entry in "${APPS[@]}"; do
    parse_app "$entry"
    if [[ "$A_PHASE" == "$phase" ]]; then
      if deploy_app "$entry"; then
        ((count++))
      else
        ((failed++))
      fi
    fi
  done

  echo ""
  log "Phase $phase complete: $count deployed, $failed failed"
}

deploy_all() {
  header "FULL STACK DEPLOYMENT"
  info "Deploying all ${#APPS[@]} applications across 10 phases"
  echo ""

  for phase in $(seq 1 10); do
    deploy_phase "$phase"
  done

  show_summary
}

show_list() {
  header "Available Applications (${#APPS[@]} total)"
  printf "\n${BOLD}%-6s %-20s %-14s %-6s %-5s %-6s %-7s %s${NC}\n" \
    "VMID" "NAME" "CATEGORY" "TYPE" "CPU" "RAM" "DISK" "DESCRIPTION"
  printf "%-6s %-20s %-14s %-6s %-5s %-6s %-7s %s\n" \
    "────" "────────────────────" "──────────────" "────" "───" "───" "────" "───────────"

  local current_phase=0
  for entry in "${APPS[@]}"; do
    parse_app "$entry"
    if [[ "$A_PHASE" != "$current_phase" ]]; then
      current_phase="$A_PHASE"
      local phase_label=""
      case $current_phase in
        1) phase_label="Infrastructure" ;;
        2) phase_label="AI & LLM" ;;
        3) phase_label="Automation" ;;
        4) phase_label="Business/Finance" ;;
        5) phase_label="Documents" ;;
        6) phase_label="Communication" ;;
        7) phase_label="Monitoring" ;;
        8) phase_label="Workspace" ;;
        9) phase_label="Security" ;;
        10) phase_label="Dev & Code" ;;
      esac
      echo -e "\n${CYAN}── Phase $current_phase: $phase_label ──${NC}"
    fi

    local status=""
    if is_deployed "$A_NAME"; then
      status="${GREEN}[✓]${NC} "
    fi

    printf "${status}%-6s %-20s %-14s %-6s %-5s %-6s %-7s %s\n" \
      "$A_VMID" "$A_NAME" "$A_CAT" "$A_TYPE" "$A_CPU" "${A_RAM}M" "${A_DISK}G" "$A_DESC"
  done
  echo ""
}

show_status() {
  header "Deployment Status"

  local total=${#APPS[@]}
  local deployed=0
  local running=0

  for entry in "${APPS[@]}"; do
    parse_app "$entry"
    if is_deployed "$A_NAME"; then
      ((deployed++))
      if [[ "$A_TYPE" == "ct" ]]; then
        if pct status "$A_VMID" 2>/dev/null | grep -q "running"; then
          ((running++))
          echo -e "  ${GREEN}●${NC} $A_NAME (CT $A_VMID) — running"
        else
          echo -e "  ${YELLOW}○${NC} $A_NAME (CT $A_VMID) — stopped"
        fi
      else
        if qm status "$A_VMID" 2>/dev/null | grep -q "running"; then
          ((running++))
          echo -e "  ${GREEN}●${NC} $A_NAME (VM $A_VMID) — running"
        else
          echo -e "  ${YELLOW}○${NC} $A_NAME (VM $A_VMID) — stopped"
        fi
      fi
    fi
  done

  echo ""
  log "Total: $total | Deployed: $deployed | Running: $running | Remaining: $((total - deployed))"

  # Resource estimate
  local total_cpu=0 total_ram=0 total_disk=0
  for entry in "${APPS[@]}"; do
    parse_app "$entry"
    ((total_cpu += A_CPU))
    ((total_ram += A_RAM))
    ((total_disk += A_DISK))
  done
  echo ""
  info "Full stack resource requirements:"
  echo "  CPU cores: $total_cpu"
  echo "  RAM: $((total_ram / 1024))GB"
  echo "  Disk: ${total_disk}GB"
}

show_summary() {
  header "DEPLOYMENT SUMMARY"

  echo -e "\n${BOLD}Access your services at:${NC}\n"

  for entry in "${APPS[@]}"; do
    parse_app "$entry"
    if is_deployed "$A_NAME"; then
      local ip=""
      if [[ "$A_TYPE" == "ct" ]]; then
        ip=$(pct exec "$A_VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
      fi

      local port=""
      case "$A_SCRIPT" in
        openwebui) port="3000" ;;
        ollama) port="11434" ;;
        flowiseai) port="3000" ;;
        n8n) port="5678" ;;
        nginxproxymanager) port="81" ;;
        grafana) port="3000" ;;
        odoo) port="8069" ;;
        invoiceninja) port="80" ;;
        bookstack) port="80" ;;
        paperless-ngx) port="8000" ;;
        uptimekuma) port="3001" ;;
        homepage) port="3000" ;;
        mattermost) port="8065" ;;
        keycloak) port="8080" ;;
        jenkins) port="8080" ;;
        vaultwarden) port="80" ;;
        *) port="80" ;;
      esac

      if [[ -n "$ip" && "$ip" != "unknown" ]]; then
        echo -e "  ${GREEN}●${NC} ${BOLD}$A_NAME${NC}: http://${ip}:${port}  ($A_DESC)"
      else
        echo -e "  ${GREEN}●${NC} ${BOLD}$A_NAME${NC}: CT $A_VMID  ($A_DESC)"
      fi
    fi
  done

  echo ""
  log "Deployment complete! Check $SCRIPT_LOG for full details."
  echo ""
  echo -e "${YELLOW}IMPORTANT NEXT STEPS:${NC}"
  echo "  1. Set up Nginx Proxy Manager for SSL/reverse proxy"
  echo "  2. Configure Keycloak SSO for unified login"
  echo "  3. Connect Ollama to Open WebUI (set OLLAMA_BASE_URL)"
  echo "  4. Connect FlowiseAI to Ollama for AI agents"
  echo "  5. Connect n8n to your AI stack for automated workflows"
  echo "  6. Set up Grafana dashboards for monitoring"
  echo ""
}

show_interactive_menu() {
  header "Proxmox AI & Business Stack Deployer"
  echo ""
  echo -e "  ${BOLD}1)${NC}  Deploy ALL (full stack - ${#APPS[@]} apps)"
  echo -e "  ${BOLD}2)${NC}  Deploy by Phase (select which phases)"
  echo -e "  ${BOLD}3)${NC}  Deploy single app"
  echo -e "  ${BOLD}4)${NC}  List all apps"
  echo -e "  ${BOLD}5)${NC}  Check deployment status"
  echo -e "  ${BOLD}6)${NC}  Show resource requirements"
  echo -e "  ${BOLD}7)${NC}  Dry run (show what would be deployed)"
  echo -e "  ${BOLD}8)${NC}  Reset deployment state"
  echo -e "  ${BOLD}0)${NC}  Exit"
  echo ""
  read -rp "Select option: " choice

  case $choice in
    1)
      echo ""
      read -rp "Deploy ALL ${#APPS[@]} apps? This will take a while. (y/N): " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] && deploy_all
      ;;
    2)
      echo ""
      echo "Available phases:"
      echo "  1) Infrastructure (Docker, PostgreSQL, Redis, Nginx, etc.)"
      echo "  2) AI & LLM (Ollama, Open WebUI, FlowiseAI, etc.)"
      echo "  3) Automation (n8n, Node-RED, Semaphore, etc.)"
      echo "  4) Business & Finance (Odoo, Invoice Ninja, etc.)"
      echo "  5) Documents & Knowledge (Paperless, BookStack, etc.)"
      echo "  6) Communication (Mattermost, Element, etc.)"
      echo "  7) Monitoring (Grafana, Prometheus, Uptime Kuma)"
      echo "  8) Workspace & Storage (Nextcloud, MinIO, etc.)"
      echo "  9) Security (Keycloak, Authelia, etc.)"
      echo "  10) Dev & Code (Forgejo, Jenkins, etc.)"
      echo ""
      read -rp "Enter phase numbers (comma-separated, e.g. 1,2,3): " phases
      IFS=',' read -ra phase_arr <<< "$phases"
      for p in "${phase_arr[@]}"; do
        deploy_phase "$(echo "$p" | tr -d ' ')"
      done
      show_summary
      ;;
    3)
      echo ""
      show_list
      read -rp "Enter app name to deploy: " app_name
      for entry in "${APPS[@]}"; do
        parse_app "$entry"
        if [[ "$A_NAME" == "$app_name" ]]; then
          deploy_app "$entry"
          break
        fi
      done
      ;;
    4) show_list ;;
    5) show_status ;;
    6) show_status ;;
    7)
      DRY_RUN=1
      deploy_all
      ;;
    8)
      read -rp "Reset deployment state? (y/N): " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$DEPLOY_STATE"
        log "Deployment state reset."
      fi
      ;;
    0) exit 0 ;;
    *) err "Invalid option." ;;
  esac
}

show_resource_estimate() {
  local total_cpu=0 total_ram=0 total_disk=0
  for entry in "${APPS[@]}"; do
    parse_app "$entry"
    ((total_cpu += A_CPU))
    ((total_ram += A_RAM))
    ((total_disk += A_DISK))
  done

  header "Resource Requirements (Full Stack)"
  echo ""
  echo "  Total CPU cores needed:  $total_cpu"
  echo "  Total RAM needed:        $((total_ram / 1024)) GB ($total_ram MB)"
  echo "  Total Disk needed:       ${total_disk} GB"
  echo ""
  echo "  Recommended hardware:"
  echo "    CPU:     16+ cores (can overcommit ~2x)"
  echo "    RAM:     64GB+ (128GB recommended)"
  echo "    Storage: 1TB+ SSD/NVMe"
  echo ""

  # Current system resources
  local sys_cpu=$(nproc)
  local sys_ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
  local sys_disk=$(pvesm status | awk -v s="$STORAGE" '$1==s {printf "%.0f", $4/1024/1024}')

  echo "  Your system:"
  echo "    CPU cores:    $sys_cpu"
  echo "    Total RAM:    ${sys_ram_gb}GB"
  echo "    Storage free: ${sys_disk:-unknown}GB on $STORAGE"
  echo ""
}

# ========================= MAIN =========================

main() {
  check_root
  check_proxmox
  check_storage
  init_state

  case "${1:-}" in
    --all)
      deploy_all
      ;;
    --phase)
      deploy_phase "${2:-1}"
      show_summary
      ;;
    --list)
      show_list
      ;;
    --status)
      show_status
      ;;
    --dry-run)
      DRY_RUN=1
      deploy_all
      ;;
    --resources)
      show_resource_estimate
      ;;
    --summary)
      show_summary
      ;;
    --help|-h)
      echo "Usage: $0 [OPTION]"
      echo ""
      echo "Options:"
      echo "  --all          Deploy entire stack"
      echo "  --phase N      Deploy phase N only (1-10)"
      echo "  --list         List all available apps"
      echo "  --status       Show deployment status"
      echo "  --dry-run      Show what would be deployed"
      echo "  --resources    Show resource requirements"
      echo "  --summary      Show access URLs for deployed apps"
      echo "  --help         Show this help"
      echo ""
      echo "Environment variables:"
      echo "  STORAGE=local-lvm    Target storage"
      echo "  BRIDGE=vmbr0         Network bridge"
      echo "  GATEWAY=10.0.3.1     Default gateway"
      echo "  DNS=1.1.1.1          DNS server"
      echo "  START_VMID=400       Starting VMID"
      echo "  DRY_RUN=1            Preview without deploying"
      echo "  PAUSE_BETWEEN=10     Seconds between deploys"
      echo ""
      ;;
    "")
      show_interactive_menu
      ;;
    *)
      err "Unknown option: $1"
      echo "Use --help for usage."
      exit 1
      ;;
  esac
}

main "$@"
