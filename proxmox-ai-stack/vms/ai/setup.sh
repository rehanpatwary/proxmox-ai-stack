#!/usr/bin/env bash
# =============================================================================
#  vms/ai/setup.sh — Full AI VM Stack Installer
#
#  Installs the complete Open WebUI ecosystem plus the Ollama inference engine
#  on ai-vm. All services run as Docker containers on a shared bridge network.
#
#  SERVICES DEPLOYED
#  ─────────────────
#  Service                Port    Description
#  ─────────────────────────────────────────────────────────────────────────
#  Ollama                11434   GPU-accelerated LLM inference engine
#  Open WebUI             3000   Full-featured AI chat interface
#  AnythingLLM            3001   RAG / document Q&A workspace
#  Qdrant                 6333   Vector database for embeddings
#  Whisper                8000   OpenAI-compatible speech-to-text API
#  Open Terminal          8080   AI-controlled sandboxed Linux terminal
#  MCPO                   8081   MCP-to-OpenAPI proxy (bridges stdio MCP → HTTP)
#  OpenAPI Filesystem     8082   File read/write/list via OpenAPI
#  OpenAPI Memory         8083   Persistent knowledge graph via OpenAPI
#  OpenAPI Git            8084   Git repo operations via OpenAPI
#  OpenAPI SQL            8085   Natural-language SQL queries via OpenAPI
#  SearXNG                8086   Self-hosted web search (RAG web search backend)
#  Nginx                  80/443  Reverse proxy — routes all subdomains
#  node-exporter          9100   Prometheus system metrics
#  nvidia-exporter        9445   Prometheus GPU metrics
#
#  ARCHITECTURE
#  ────────────
#
#  ┌─────────────────────────────────────────────────────────────────────┐
#  │  Open WebUI (chat interface)                                         │
#  │    │                                                                  │
#  │    ├── Ollama :11434        (LLM inference, GPU)                     │
#  │    ├── Whisper :8000        (voice → text, GPU)                      │
#  │    ├── SearXNG :8086        (web search for RAG)                     │
#  │    ├── Open Terminal :8080  (AI runs shell commands)                  │
#  │    │                                                                  │
#  │    └── Tool Servers (OpenAPI endpoints):                              │
#  │         ├── MCPO :8081      (gateway to all MCP servers)             │
#  │         │    ├── mcp-server-time        (current time/timezone)      │
#  │         │    ├── mcp-server-fetch       (fetch URLs)                 │
#  │         │    ├── mcp-server-sequentialthinking (step reasoning)      │
#  │         │    ├── mcp-server-brave-search (web search via Brave API)  │
#  │         │    └── mcp-server-git         (git operations)             │
#  │         ├── openapi-filesystem :8082    (file operations)            │
#  │         ├── openapi-memory :8083        (knowledge graph)            │
#  │         ├── openapi-git :8084           (git repos)                  │
#  │         └── openapi-sql :8085           (database queries)           │
#  └─────────────────────────────────────────────────────────────────────┘
#
#  TOOL SERVER TYPES
#  ─────────────────
#  Open WebUI supports two types of external tool integrations:
#
#  1. OpenAPI Servers  — HTTP servers exposing a /openapi.json schema.
#     Open WebUI fetches the schema and turns every endpoint into a callable
#     tool. These run as standalone Docker containers.
#     Register at: Admin → Settings → Tools → Add Tool Server → OpenAPI
#
#  2. MCP via MCPO  — Most community MCP servers use stdio (stdin/stdout).
#     MCPO (MCP-to-OpenAPI proxy) wraps them in HTTP, generating OpenAPI docs
#     automatically. One MCPO container runs multiple MCP servers at once.
#     Register at: Admin → Settings → Tools → Add Tool Server → OpenAPI
#     (MCPO exposes each MCP server under its own sub-path)
#
#  3. Open Terminal  — Gives the AI a real sandboxed Linux shell. The AI can
#     run commands, install packages, write and execute scripts, and manage
#     files. Configured as a separate integration type in Open WebUI.
#     Register at: Admin → Settings → Integrations → Open Terminal
#
#  INSTALLATION ORDER
#  ──────────────────
#  1. System packages (curl, git, build tools)
#  2. NVIDIA driver 535
#  3. Docker CE + Compose plugin
#  4. NVIDIA Container Toolkit (SSH-safe GPG workaround applied)
#  5. Python 3 + uv (for MCPO and OpenAPI server runtime)
#  6. Node.js 20 (for npx-based MCP servers)
#  7. Directory structure under /opt/ai-stack/
#  8. MCPO config.json (defines all MCP servers to proxy)
#  9. SearXNG settings.yml
#  10. docker-compose.yml (all services)
#  11. Nginx virtual host configs (one per service subdomain)
#  12. Open WebUI env vars (pre-configures tool server connections)
#  13. Start stack via  docker compose up -d
#  14. Pull default model (llama3.2:3b)
#
#  REQUIREMENTS
#  ────────────
#  - Run as root inside ai-vm
#  - RTX 4090 passed through from Proxmox (00_gpu_passthrough.sh ran + rebooted)
#  - ANYTHINGLLM_JWT_SECRET, POSTGRES_PASSWORD, MCPO_API_KEY must be set
#  - DATA_VM_IP reachable on port 5432 (data-vm running)
#
#  OPTIONAL SECRETS (enhance capabilities if set)
#  ───────────────
#  BRAVE_API_KEY    — enables Brave Search MCP server (free tier: 2000 req/mo)
#                     get at: https://api.search.brave.com/
#
#  IDEMPOTENT
#  ──────────
#  Each function checks whether its work is already done before proceeding.
#  Safe to re-run after partial failures.
#
#  USAGE
#  ─────
#  Via host/deploy-vm.sh (recommended — handles SSH, SCP, env injection):
#    bash host/deploy-vm.sh ai
#
#  Manually on the VM:
#    source <(bash export-env.sh ai)   # run on Proxmox host, paste output on VM
#    sudo -E bash ~/ai/setup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# error() must be defined before sourcing bootstrap (used for root check below).
# bootstrap.sh defines info/section/warn; it skips redefining if already present.
RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}  →${NC} $*"; }

[[ $EUID -ne 0 ]] && error "Run as root:  sudo -E bash setup.sh"

# ── Bootstrap (system hygiene: NTP, journald, TRIM, admin tools) ─────────────
# shellcheck source=../common/bootstrap.sh
source "${SCRIPT_DIR}/../common/bootstrap.sh"

# ── Load installers ──────────────────────────────────────────────────────────
# shellcheck source=./install-nvidia.sh
source "${SCRIPT_DIR}/install-nvidia.sh"
# shellcheck source=./install-docker.sh
source "${SCRIPT_DIR}/install-docker.sh"
# shellcheck source=./generate-compose.sh
source "${SCRIPT_DIR}/generate-compose.sh"

# Generate MCPO API key if not injected via ENV_BLOCK
MCPO_API_KEY="${MCPO_API_KEY:-$(openssl rand -hex 16)}"
BRAVE_API_KEY="${BRAVE_API_KEY:-}"   # optional — enables Brave Search MCP server

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Update apt package lists, upgrade installed packages, and install base tools.
#
# Installs: curl wget git unzip gnupg lsb-release software-properties-common
# python3 python3-pip python3-venv build-essential
# These are prerequisites for Docker, NVIDIA, uv, and Node.js installations.
##
install_base_packages() {
    section "System Update + Base Packages"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget git unzip \
        apt-transport-https ca-certificates gnupg lsb-release \
        software-properties-common \
        python3 python3-pip python3-venv \
        build-essential
    info "Base packages installed ✓"
}

##
# Install uv — the fast Python package and tool runner used by MCPO.
#
# uv is used instead of pip for running MCP servers because it:
#   - Installs packages in isolated environments (no conflicts)
#   - Uses  uvx <package>  to run tools without a permanent install
#   - Starts up significantly faster than pip-installed tools
#
# Idempotent: skips if uv is already in /usr/local/bin.
##
install_uv() {
    section "uv (Python tool runner)"

    if command -v uv &>/dev/null; then
        info "uv already installed ($(uv --version))"
        return 0
    fi

    info "Installing uv..."
    curl -fsSL https://astral.sh/uv/install.sh | sh
    # The installer puts uv in ~/.cargo/bin or ~/.local/bin; make it global
    local uv_path
    uv_path=$(find /root/.cargo/bin /root/.local/bin -name uv 2>/dev/null | head -1 || true)
    if [[ -n "$uv_path" ]]; then
        ln -sf "$uv_path" /usr/local/bin/uv
        info "uv linked to /usr/local/bin/uv ✓"
    fi
    uv --version && info "uv installed ✓"
}

##
# Install Node.js 20 LTS from the official NodeSource repository.
#
# Required by npx-based MCP servers (e.g. @modelcontextprotocol/server-memory,
# @modelcontextprotocol/server-filesystem). MCPO launches these via  npx  when
# the MCP server is an npm package.
#
# Idempotent: checks the major version before reinstalling.
##
install_nodejs() {
    section "Node.js 20 LTS"

    if node --version 2>/dev/null | grep -q "^v20"; then
        info "Node.js 20 already installed ($(node --version))"
        return 0
    fi

    info "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
    info "Node.js $(node --version) installed ✓"
}

##
# Create the full directory structure used by all services.
#
# Layout:
#   /opt/ai-stack/
#   ├── ollama/           (not used directly — Docker volume handles data)
#   ├── openwebui/        (Open WebUI data volume mount)
#   ├── anythingllm/      (AnythingLLM storage)
#   ├── qdrant/storage    (Qdrant vector data)
#   ├── whisper/          (Whisper model cache)
#   ├── open-terminal/    (Open Terminal persistent home dir)
#   ├── mcpo/             (MCPO config.json)
#   ├── openapi-servers/  (shared workspace for OpenAPI tool servers)
#   │   └── workspace/    (AI-accessible files: read/write by filesystem server)
#   ├── searxng/          (SearXNG settings.yml and limiter config)
#   ├── memory/           (OpenAPI memory server knowledge graph data)
#   └── nginx/
#       ├── conf.d/       (virtual host config files)
#       └── certs/        (TLS certificates, if used)
##
create_directories() {
    section "Directory Structure"
    mkdir -p /opt/ai-stack/{ollama,openwebui,anythingllm,qdrant/storage,whisper}
    mkdir -p /opt/ai-stack/{open-terminal,mcpo}
    mkdir -p /opt/ai-stack/openapi-servers/workspace
    mkdir -p /opt/ai-stack/{searxng,memory}
    mkdir -p /opt/ai-stack/nginx/{conf.d,certs}

    # Open Terminal workspace: readable/writable by the AI terminal user
    chmod 777 /opt/ai-stack/openapi-servers/workspace
    info "Directory tree created ✓"
}

##
# Write the MCPO configuration file defining all MCP servers to proxy.
#
# MCPO (MCP-to-OpenAPI proxy) starts each MCP server as a subprocess and
# exposes it via an HTTP endpoint. The config follows Claude Desktop format.
#
# Each entry in mcpServers defines:
#   command  — executable to run (uvx for Python packages, npx for npm)
#   args     — arguments passed to the MCP server binary
#   env      — environment variables scoped to that server process
#
# MCPO generates OpenAPI docs for each server at:
#   http://localhost:8081/<server-name>/docs
#
# In Open WebUI, register each server as a separate tool at:
#   http://<ai-vm-ip>:8081/<server-name>
#
# MCP SERVERS INCLUDED:
#   time        — current time and timezone conversion
#   fetch       — HTTP fetching, web content extraction (Markdown output)
#   thinking    — sequential step-by-step reasoning aid
#   filesystem  — file read/write/list within /workspace (sandboxed)
#   memory      — persistent entity/relation knowledge graph
#   git         — git log, diff, branch, commit operations on /workspace
#   brave-search — web search via Brave Search API (requires BRAVE_API_KEY)
#
# Arguments: none (reads global BRAVE_API_KEY)
#
# Side effects:
#   Writes /opt/ai-stack/mcpo/config.json
##
write_mcpo_config() {
    section "MCPO Config"

    # Build the Brave Search server block conditionally
    local brave_block=""
    if [[ -n "$BRAVE_API_KEY" ]]; then
        brave_block=',
    "brave-search": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-brave-search"],
      "env": {
        "BRAVE_API_KEY": "'"${BRAVE_API_KEY}"'"
      }
    }'
        info "Brave Search MCP server enabled ✓"
    else
        warn "BRAVE_API_KEY not set — Brave Search MCP server skipped"
        warn "Get a free key at https://api.search.brave.com/ and add it to config.env"
    fi

    cat > /opt/ai-stack/mcpo/config.json <<MCPOCONF
{
  "mcpServers": {

    "time": {
      "command": "uvx",
      "args": ["mcp-server-time", "--local-timezone=Asia/Dhaka"],
      "comment": "Returns current time and converts between timezones"
    },

    "fetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"],
      "comment": "Fetches URLs and extracts content as Markdown. Use for web browsing."
    },

    "thinking": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"],
      "comment": "Helps models break complex problems into sequential reasoning steps"
    },

    "filesystem": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/workspace"
      ],
      "comment": "File operations (read/write/list) sandboxed to /workspace inside container"
    },

    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "comment": "Persistent knowledge graph — create entities, add relations, store observations"
    },

    "git": {
      "command": "uvx",
      "args": ["mcp-server-git", "--repository", "/workspace"],
      "comment": "Git operations (log, diff, commit, branch) on /workspace"
    }${brave_block}

  }
}
MCPOCONF

    info "MCPO config written to /opt/ai-stack/mcpo/config.json ✓"
    step "MCP servers: time, fetch, thinking, filesystem, memory, git$([ -n "$BRAVE_API_KEY" ] && echo ', brave-search')"
}

##
# Write the SearXNG configuration for self-hosted web search.
#
# SearXNG is used by Open WebUI for the RAG web search feature.
# It aggregates results from multiple search engines without sending
# user queries to third-party APIs.
#
# Key settings:
#   use_default_settings: true  — inherits all defaults, only overrides shown
#   server.secret_key          — required for session signing
#   search.formats             — json enabled for API access by Open WebUI
#   engines                    — Google, Bing, DuckDuckGo, Brave, Startpage
#
# Side effects:
#   Writes /opt/ai-stack/searxng/settings.yml
#   Writes /opt/ai-stack/searxng/limiter.toml (disables rate limiting for LAN)
##
write_searxng_config() {
    section "SearXNG Config"

    local secret_key
    secret_key=$(openssl rand -hex 32)

    cat > /opt/ai-stack/searxng/settings.yml <<SEARXNG
# SearXNG configuration for Open WebUI RAG web search integration
# Full settings reference: https://docs.searxng.org/admin/settings/index.html

use_default_settings: true

server:
  # secret_key: required — signs session cookies; change on each deploy
  secret_key: "${secret_key}"
  limiter: false          # disabled — this instance is LAN-only
  image_proxy: false      # not needed for LLM text search
  method: "GET"

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"
  formats:
    - html
    - json                # json format is required for Open WebUI API access

engines:
  # Google — high quality, requires no key for basic searches
  - name: google
    engine: google
    categories: general
    weight: 2
    disabled: false

  # DuckDuckGo — privacy-first, no API key required
  - name: duckduckgo
    engine: duckduckgo
    categories: general
    weight: 1
    disabled: false

  # Bing — broad coverage
  - name: bing
    engine: bing
    categories: general
    weight: 1
    disabled: false

  # Startpage — Google results without tracking
  - name: startpage
    engine: startpage
    categories: general
    weight: 1
    disabled: false

  # Wikipedia — authoritative for factual queries
  - name: wikipedia
    engine: wikipedia
    categories: general
    weight: 2
    disabled: false

ui:
  static_use_hash: true
  default_theme: simple
  center_alignment: true

outgoing:
  request_timeout: 6.0   # seconds per engine
  max_request_timeout: 15.0
SEARXNG

    # Disable the rate limiter entirely for LAN use
    cat > /opt/ai-stack/searxng/limiter.toml <<LIMITER
[botdetection.ip_limit]
link_token = false
LIMITER

    info "SearXNG config written ✓"
}

##
# Write the Nginx virtual host configuration for all services.
#
# Each service gets a server block listening on port 80.
# WebSocket upgrade headers are included for services that use real-time
# connections (Open WebUI, AnythingLLM, Open Terminal).
# client_max_body_size is set generously for file upload workflows.
#
# Services and their subdomains:
#   chat.<domain>       → Open WebUI         :3000
#   docs.<domain>       → AnythingLLM        :3001
#   ollama.<domain>     → Ollama API         :11434
#   terminal.<domain>   → Open Terminal      :8080
#   mcpo.<domain>       → MCPO               :8081
#   search.<domain>     → SearXNG            :8086
#   qdrant.<domain>     → Qdrant dashboard   :6333
##
write_nginx_config() {
    section "Nginx Config"

    cat > /opt/ai-stack/nginx/conf.d/ai.conf <<NGINX
# =============================================================================
#  Nginx virtual hosts — Proxmox AI Stack
#  Reload without downtime: docker exec nginx nginx -s reload
# =============================================================================

# ── Open WebUI ──────────────────────────────────────────────────────────────
server {
    listen 80;
    server_name chat.${BASE_DOMAIN};
    client_max_body_size 100M;

    location / {
        proxy_pass         http://open-webui:8080;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}

# ── AnythingLLM ─────────────────────────────────────────────────────────────
server {
    listen 80;
    server_name docs.${BASE_DOMAIN};
    client_max_body_size 200M;

    location / {
        proxy_pass         http://anythingllm:3001;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
    }
}

# ── Ollama API ──────────────────────────────────────────────────────────────
# Restrict to internal IPs before exposing externally
server {
    listen 80;
    server_name ollama.${BASE_DOMAIN};

    location / {
        proxy_pass         http://ollama:11434;
        proxy_set_header   Host \$host;
        proxy_read_timeout 600s;   # long timeout for model inference
    }
}

# ── Open Terminal ────────────────────────────────────────────────────────────
server {
    listen 80;
    server_name terminal.${BASE_DOMAIN};

    location / {
        proxy_pass         http://open-terminal:8000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_read_timeout 3600s;  # keep terminal sessions alive
    }
}

# ── MCPO (MCP proxy) ─────────────────────────────────────────────────────────
# OpenAPI docs: http://mcpo.<domain>/docs
# Each MCP server: http://mcpo.<domain>/<server-name>/docs
server {
    listen 80;
    server_name mcpo.${BASE_DOMAIN};

    location / {
        proxy_pass       http://mcpo:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 60s;
    }
}

# ── SearXNG ──────────────────────────────────────────────────────────────────
server {
    listen 80;
    server_name search.${BASE_DOMAIN};

    location / {
        proxy_pass       http://searxng:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

# ── Qdrant Dashboard ─────────────────────────────────────────────────────────
server {
    listen 80;
    server_name qdrant.${BASE_DOMAIN};

    location / {
        proxy_pass http://qdrant:6333;
        proxy_set_header Host \$host;
    }
}
NGINX
    info "Nginx config written ✓"
}

##
# Write the Docker Compose .env file used for secret interpolation.
#
# Docker Compose reads this file automatically when run in the same directory,
# substituting \${VARIABLE} references in docker-compose.yml. This keeps
# secrets out of the compose file itself while still making them available
# to container environment blocks.
##
write_env_file() {
    section "Environment File"
    cat > /opt/ai-stack/.env <<ENV
ANYTHINGLLM_JWT_SECRET=${ANYTHINGLLM_JWT_SECRET}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
DATA_VM_IP=${DATA_VM_IP}
BASE_DOMAIN=${BASE_DOMAIN}
MCPO_API_KEY=${MCPO_API_KEY}
ENV
    chmod 600 /opt/ai-stack/.env   # restrict read access
    info ".env file written ✓"
}

##
# Persist the MCPO API key to a readable file so it can be retrieved later.
#
# The key is needed when registering tool servers in Open WebUI manually
# and when adding tool servers to new users. Printed in the post-install
# summary and saved to /opt/ai-stack/mcpo-api-key.txt.
##
save_api_key() {
    echo "$MCPO_API_KEY" > /opt/ai-stack/mcpo-api-key.txt
    chmod 600 /opt/ai-stack/mcpo-api-key.txt
    info "MCPO API key saved to /opt/ai-stack/mcpo-api-key.txt ✓"
}

##
# Start all services via Docker Compose and verify they are running.
#
# Services start in parallel; --wait is intentionally not used because some
# containers (Whisper model download) take longer than Docker's health check
# timeout allows. A fixed sleep gives time for the core services to start.
##
start_stack() {
    section "Starting All Services"
    cd /opt/ai-stack
    docker compose up -d
    info "Waiting 20s for services to initialise..."
    sleep 20
    echo ""
    docker compose ps
    info "Stack started ✓"
}

##
# Pull a small default model into Ollama for immediate verification.
#
# llama3.2:3b starts quickly and verifies the GPU passthrough is working.
# Additional models (qwen2.5-coder:32b, nomic-embed-text, etc.) should be
# pulled separately after confirming the stack is healthy.
##
pull_default_model() {
    section "Pulling Default Model"
    info "Pulling llama3.2:3b for verification..."
    docker exec ollama ollama pull llama3.2:3b \
        && info "llama3.2:3b pulled ✓" \
        || warn "Pull failed — retry: docker exec ollama ollama pull llama3.2:3b"
}

# ── Run installation in order ────────────────────────────────────────────────
install_base_packages
install_uv
install_nodejs
install_nvidia_driver
install_docker
install_nvidia_container_toolkit
create_directories
write_mcpo_config
write_searxng_config
write_docker_compose
write_nginx_config
write_env_file
save_api_key
start_stack
pull_default_model

# ── Post-install summary ──────────────────────────────────────────────────────
VM_IP=$(hostname -I | awk '{print $1}')
info "AI stack is running on ${VM_IP}"
info "Open WebUI    → http://${VM_IP}:3000"
info "AnythingLLM   → http://${VM_IP}:3001"
info "Ollama API    → http://${VM_IP}:11434"
info "MCPO Proxy    → http://${VM_IP}:8081/docs"
info "SearXNG       → http://${VM_IP}:8086"
info "MCPO_API_KEY  → $(cat /opt/ai-stack/mcpo-api-key.txt 2>/dev/null || echo "${MCPO_API_KEY}")"
info "Next: open http://${VM_IP}:3000, create admin account, verify tool servers (green)"
