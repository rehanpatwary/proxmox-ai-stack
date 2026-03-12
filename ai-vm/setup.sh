#!/usr/bin/env bash
# =============================================================================
#  ai-vm/setup.sh — Full AI VM Stack Installer
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
#  Via deploy_vm.sh (recommended — handles SSH, SCP, env injection):
#    bash deploy_vm.sh ai
#
#  Manually on the VM:
#    source <(bash export_env.sh ai)   # run on Proxmox host, paste output on VM
#    sudo -E bash ~/ai-vm/setup.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "${CYAN}  →${NC} $*"; }

[[ $EUID -ne 0 ]] && error "Run as root:  sudo -E bash setup.sh"

# ---------------------------------------------------------------------------
#  Common VM bootstrap (chrony, journald limits, TRIM, admin tools)
#  Runs once; idempotent on re-runs.
# ---------------------------------------------------------------------------
# shellcheck source=../common/bootstrap.sh
source "$(dirname "$0")/../common/bootstrap.sh"

# ---------------------------------------------------------------------------
#  Config — injected by deploy_vm.sh via env exports; safe defaults shown
# ---------------------------------------------------------------------------
ANYTHINGLLM_JWT_SECRET="${ANYTHINGLLM_JWT_SECRET:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
DATA_VM_IP="${DATA_VM_IP:-192.168.1.30}"
BASE_DOMAIN="${BASE_DOMAIN:-ai.local}"
VM_USER="${VM_USER:-ubuntu}"

# MCPO API key — generated here if not provided; used to authenticate all
# tool server calls from Open WebUI to MCPO and OpenAPI servers
MCPO_API_KEY="${MCPO_API_KEY:-$(openssl rand -hex 16)}"

# Brave Search API key — optional; enables Brave Search MCP server
# Get a free key at: https://api.search.brave.com/
BRAVE_API_KEY="${BRAVE_API_KEY:-}"

# ---------------------------------------------------------------------------
#  Guard: abort early if required secrets are missing
# ---------------------------------------------------------------------------
if [[ -z "$POSTGRES_PASSWORD" ]] || [[ -z "$ANYTHINGLLM_JWT_SECRET" ]]; then
    error "Secrets are empty. Run  bash init_secrets.sh  on the Proxmox host first."
fi

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
# Install NVIDIA driver 535 from the graphics-drivers PPA.
#
# Idempotent: checks nvidia-smi before installing.
# A reboot may be required on first install for the GPU to become visible.
##
install_nvidia_driver() {
    section "NVIDIA Driver"

    if nvidia-smi &>/dev/null; then
        local ver
        ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)
        info "NVIDIA driver already installed (version: $ver) ✓"
        return 0
    fi

    info "Installing NVIDIA driver 535..."
    add-apt-repository -y ppa:graphics-drivers/ppa
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-driver-535
    info "Driver installed ✓ (reboot may be required if GPU not yet visible)"
}

##
# Install Docker CE and the Docker Compose plugin from Docker's official repo.
#
# Idempotent: skips if the docker binary already exists.
# Enables the Docker daemon to start on boot via systemd.
##
install_docker() {
    section "Docker CE"

    if command -v docker &>/dev/null; then
        info "Docker already installed ($(docker --version)) ✓"
        return 0
    fi

    info "Installing Docker CE..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    info "Docker installed ✓"
}

##
# Install the NVIDIA Container Toolkit to enable GPU access inside containers.
#
# Idempotent: checks for the nvidia-container-toolkit package.
#
# GPG WORKAROUND:
#   The standard  curl | gpg --dearmor  pipe fails in non-interactive SSH
#   sessions because gpg opens /dev/tty for a passphrase prompt.
#   Fix: save key to a temp file first, then dearmor with --batch --no-tty.
#
# Side effects:
#   Configures the NVIDIA runtime as Docker's default GPU runtime.
#   Restarts Docker to apply the runtime change.
##
install_nvidia_container_toolkit() {
    section "NVIDIA Container Toolkit"

    if dpkg -l | grep -q nvidia-container-toolkit; then
        info "NVIDIA Container Toolkit already installed ✓"
        return 0
    fi

    info "Installing NVIDIA Container Toolkit..."

    # SSH-safe GPG: save key to temp file, dearmor with --batch --no-tty
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        > /tmp/nvidia-gpgkey.asc
    gpg --batch --yes --no-tty \
        --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        /tmp/nvidia-gpgkey.asc
    rm -f /tmp/nvidia-gpgkey.asc

    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    info "NVIDIA Container Toolkit installed ✓"
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
# Write the Docker Compose file defining all services in the AI stack.
#
# Services communicate via the  ai-net  bridge network using container
# name DNS (e.g. 'ollama', 'qdrant'). All persistent data is in named
# Docker volumes, so containers can be recreated without data loss.
#
# GPU ALLOCATION:
#   Ollama, Whisper, and nvidia-exporter receive full GPU access.
#   All other containers are CPU-only.
#
# TOOL SERVER PORTS:
#   8080  Open Terminal
#   8081  MCPO (MCP proxy)
#   8082  OpenAPI Filesystem server
#   8083  OpenAPI Memory/Knowledge Graph server
#   8084  OpenAPI Git server
#   8085  OpenAPI SQL server
#   8086  SearXNG
##
write_docker_compose() {
    section "Docker Compose"

    cat > /opt/ai-stack/docker-compose.yml <<COMPOSE
version: "3.9"

networks:
  ai-net:
    driver: bridge

volumes:
  ollama_data:
  openwebui_data:
  anythingllm_data:
  qdrant_data:
  whisper_cache:
  open_terminal_home:
  memory_data:

services:

  # ════════════════════════════════════════════════════════════════════════════
  #  CORE INFERENCE
  # ════════════════════════════════════════════════════════════════════════════

  # ── Ollama ──────────────────────────────────────────────────────────────────
  # LLM inference engine with OpenAI-compatible REST API.
  # OLLAMA_KEEP_ALIVE=24h keeps loaded models in VRAM between requests to avoid
  # the ~30s reload delay on every new conversation.
  # OLLAMA_MAX_LOADED_MODELS=2 allows one chat model + one embedding model.
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    environment:
      OLLAMA_HOST: 0.0.0.0
      OLLAMA_KEEP_ALIVE: 24h
      OLLAMA_MAX_LOADED_MODELS: "2"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    networks:
      - ai-net

  # ── Whisper ──────────────────────────────────────────────────────────────────
  # OpenAI-compatible speech-to-text API using faster-whisper on CUDA.
  # First start downloads the large-v3 model (~3 GB) — normal delay.
  # Model options: large-v3 (best), medium, small, base (fastest)
  # Open WebUI connects at: http://whisper:8000/v1
  whisper:
    image: fedirz/faster-whisper-server:latest-cuda
    container_name: whisper
    restart: unless-stopped
    ports:
      - "8000:8000"
    volumes:
      - whisper_cache:/root/.cache/huggingface
    environment:
      WHISPER__MODEL: large-v3
      WHISPER__INFERENCE_DEVICE: cuda
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  OPEN WEBUI ECOSYSTEM
  # ════════════════════════════════════════════════════════════════════════════

  # ── Open WebUI ───────────────────────────────────────────────────────────────
  # Primary AI chat interface. Pre-configured to connect to all local services.
  # TOOL_SERVER_CONNECTIONS pre-registers all OpenAPI/MCPO tool servers so
  # users don't need to configure them manually through the UI.
  # OPEN_TERMINAL_CONNECTIONS pre-registers the Open Terminal sandbox.
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "3000:8080"
    volumes:
      - openwebui_data:/app/backend/data
    environment:
      # ── Core ────────────────────────────────────────────────────────────────
      OLLAMA_BASE_URL: http://ollama:11434
      WEBUI_AUTH: "true"
      WEBUI_NAME: "Patwary AI"
      WEBUI_URL: http://chat.${BASE_DOMAIN}

      # ── Voice / STT ─────────────────────────────────────────────────────────
      # Routes microphone input through local Whisper rather than OpenAI's API
      AUDIO_STT_ENGINE: openai
      AUDIO_STT_OPENAI_API_BASE_URL: http://whisper:8000/v1
      AUDIO_STT_OPENAI_API_KEY: sk-placeholder

      # ── RAG Web Search ───────────────────────────────────────────────────────
      # SearXNG provides web search results injected into the context window
      ENABLE_RAG_WEB_SEARCH: "true"
      RAG_WEB_SEARCH_ENGINE: searxng
      SEARXNG_QUERY_URL: http://searxng:8080/search?q=<query>&format=json

      # ── Image Generation ──────────────────────────────────────────────────────
      # Disabled by default — enable if ComfyUI or AUTOMATIC1111 is added
      ENABLE_IMAGE_GENERATION: "false"

      # ── Tool Servers (OpenAPI + MCPO) ────────────────────────────────────────
      # Pre-registers all tool servers so they are available to models immediately.
      # Each entry follows the TOOL_SERVER_CONNECTIONS JSON schema.
      # Models must have Function Calling = Native to use these tools.
      TOOL_SERVER_CONNECTIONS: |
        [
          {
            "type": "openapi",
            "url": "http://mcpo:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "bearer",
            "key": "${MCPO_API_KEY}",
            "config": { "enable": true },
            "info": { "name": "MCP Tools (via MCPO)", "description": "Time, fetch, thinking, filesystem, memory, git, brave-search" }
          },
          {
            "type": "openapi",
            "url": "http://openapi-filesystem:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "none",
            "config": { "enable": true },
            "info": { "name": "Filesystem", "description": "Read, write, and list files in /workspace" }
          },
          {
            "type": "openapi",
            "url": "http://openapi-memory:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "none",
            "config": { "enable": true },
            "info": { "name": "Memory", "description": "Persistent knowledge graph across conversations" }
          },
          {
            "type": "openapi",
            "url": "http://openapi-git:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "none",
            "config": { "enable": true },
            "info": { "name": "Git", "description": "Git operations on /workspace repositories" }
          },
          {
            "type": "openapi",
            "url": "http://openapi-sql:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "none",
            "config": { "enable": true },
            "info": { "name": "SQL", "description": "Natural language SQL queries against connected databases" }
          }
        ]

      # ── Open Terminal ─────────────────────────────────────────────────────────
      # Pre-registers the sandboxed terminal so AI can run shell commands.
      # Auth is via bearer token matched to OPEN_TERMINAL_API_KEY below.
      OPEN_TERMINAL_CONNECTIONS: |
        [
          {
            "name": "AI Sandbox",
            "url": "http://open-terminal:8000",
            "auth_type": "bearer",
            "key": "${MCPO_API_KEY}",
            "config": { "enable": true }
          }
        ]

    depends_on:
      - ollama
      - whisper
      - searxng
    networks:
      - ai-net

  # ── Open Terminal ─────────────────────────────────────────────────────────────
  # Sandboxed Linux environment the AI can control via shell commands.
  # The AI can: install packages, run scripts, process files, build things.
  # /home/user persists between restarts via named volume.
  # Docker socket is mounted so the AI can manage containers if needed.
  # OPEN_TERMINAL_MULTI_USER=true gives each Open WebUI user their own
  # isolated home directory within the container.
  open-terminal:
    image: ghcr.io/open-webui/open-terminal:latest
    container_name: open-terminal
    restart: unless-stopped
    ports:
      - "8080:8000"
    volumes:
      - open_terminal_home:/home/user
      # Share the workspace with OpenAPI filesystem and git servers
      - /opt/ai-stack/openapi-servers/workspace:/home/user/workspace
      # Docker socket: allows the AI to manage containers (trusted env only)
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      OPEN_TERMINAL_API_KEY: "${MCPO_API_KEY}"
      OPEN_TERMINAL_MULTI_USER: "true"
      # Extra pip packages available in the AI's Python environment
      OPEN_TERMINAL_PIP_PACKAGES: "httpx polars pandas numpy requests rich"
      # Extra apt packages available in the sandbox
      OPEN_TERMINAL_PACKAGES: "ffmpeg jq sqlite3 tree"
    networks:
      - ai-net

  # ── MCPO (MCP-to-OpenAPI Proxy) ───────────────────────────────────────────────
  # Reads mcpo/config.json, starts each MCP server as a subprocess, and
  # exposes every tool as an OpenAPI HTTP endpoint.
  # Each MCP server gets its own sub-path: http://mcpo:8000/<server-name>
  # API docs for all servers: http://<ai-vm-ip>:8081/docs
  # Hot-reload is enabled — editing config.json restarts affected servers
  # without downtime.
  # workspace is mounted so filesystem/git MCP servers can access shared files.
  mcpo:
    image: ghcr.io/open-webui/mcpo:main
    container_name: mcpo
    restart: unless-stopped
    ports:
      - "8081:8000"
    volumes:
      - /opt/ai-stack/mcpo/config.json:/app/config/config.json:ro
      - /opt/ai-stack/openapi-servers/workspace:/workspace
    command: >
      mcpo
        --host 0.0.0.0
        --port 8000
        --api-key "${MCPO_API_KEY}"
        --config /app/config/config.json
        --hot-reload
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  OPENAPI TOOL SERVERS (open-webui/openapi-servers)
  #  Native HTTP servers exposing structured tools via standard OpenAPI specs.
  #  Each server's schema is served at /openapi.json and viewable at /docs.
  # ════════════════════════════════════════════════════════════════════════════

  # ── OpenAPI Filesystem Server ─────────────────────────────────────────────────
  # Allows the AI to read, write, create, delete, and list files within /workspace.
  # The /workspace directory is shared with Open Terminal and the MCPO filesystem
  # MCP server, so files created by one tool are visible to the others.
  # Security: path traversal attacks are blocked by path normalization.
  # Destructive operations (delete) require a confirmation token.
  openapi-filesystem:
    image: ghcr.io/open-webui/openapi-servers:filesystem
    container_name: openapi-filesystem
    restart: unless-stopped
    ports:
      - "8082:8000"
    volumes:
      - /opt/ai-stack/openapi-servers/workspace:/workspace
    environment:
      ALLOWED_DIRECTORIES: /workspace
    networks:
      - ai-net

  # ── OpenAPI Memory / Knowledge Graph Server ───────────────────────────────────
  # Provides a persistent structured memory store that survives across
  # conversations. The AI can:
  #   - create_entities   (add named concepts)
  #   - add_observations  (store facts about entities)
  #   - create_relations  (link entities together)
  #   - query_knowledge   (search the graph semantically)
  # Data persists in /data/memory.json via named volume.
  openapi-memory:
    image: ghcr.io/open-webui/openapi-servers:memory
    container_name: openapi-memory
    restart: unless-stopped
    ports:
      - "8083:8000"
    volumes:
      - memory_data:/data
    networks:
      - ai-net

  # ── OpenAPI Git Server ────────────────────────────────────────────────────────
  # Exposes git operations as API endpoints. The AI can:
  #   - read commit history, diffs, branches, tags
  #   - search code within repos
  # Operates on git repos within /workspace (shared with filesystem server).
  openapi-git:
    image: ghcr.io/open-webui/openapi-servers:git
    container_name: openapi-git
    restart: unless-stopped
    ports:
      - "8084:8000"
    volumes:
      - /opt/ai-stack/openapi-servers/workspace:/workspace
    networks:
      - ai-net

  # ── OpenAPI SQL Server ────────────────────────────────────────────────────────
  # Accepts natural-language queries, generates SQL, executes against the
  # connected database, and returns formatted results.
  # Pointed at the Postgres instance on data-vm by default.
  # Change DATABASE_URL to point at a different database if needed.
  openapi-sql:
    image: ghcr.io/open-webui/openapi-servers:sql
    container_name: openapi-sql
    restart: unless-stopped
    ports:
      - "8085:8000"
    environment:
      DATABASE_URL: "postgresql://postgres:${POSTGRES_PASSWORD}@${DATA_VM_IP}:5432/app_db"
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  KNOWLEDGE AND SEARCH
  # ════════════════════════════════════════════════════════════════════════════

  # ── AnythingLLM ────────────────────────────────────────────────────────────────
  # Document-aware chat workspace. Upload PDFs, docs, code — ask questions.
  # Stores embeddings in Qdrant and metadata in Postgres on data-vm.
  anythingllm:
    image: mintplexlabs/anythingllm:latest
    container_name: anythingllm
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - anythingllm_data:/app/server/storage
    environment:
      STORAGE_DIR: /app/server/storage
      JWT_SECRET: ${ANYTHINGLLM_JWT_SECRET}
      LLM_PROVIDER: ollama
      OLLAMA_BASE_PATH: http://ollama:11434
      OLLAMA_MODEL_PREF: llama3.2
      EMBEDDING_ENGINE: ollama
      EMBEDDING_BASE_PATH: http://ollama:11434
      VECTOR_DB: qdrant
      QDRANT_ENDPOINT: http://qdrant:6333
      WHISPER_PROVIDER: local
    depends_on:
      - ollama
      - qdrant
    networks:
      - ai-net

  # ── Qdrant ────────────────────────────────────────────────────────────────────
  # High-performance vector database for embedding storage and similarity search.
  # Used by AnythingLLM. Port 6334 is the gRPC interface.
  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    restart: unless-stopped
    ports:
      - "6333:6333"
      - "6334:6334"
    volumes:
      - qdrant_data:/qdrant/storage
    networks:
      - ai-net

  # ── SearXNG ────────────────────────────────────────────────────────────────────
  # Self-hosted meta search engine. Aggregates Google, Bing, DuckDuckGo, and
  # others without sending personal data to any third party.
  # Open WebUI queries it at /search?q=<query>&format=json for RAG web search.
  # Port 8086 on the host; internally exposed as :8080 to Open WebUI.
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "8086:8080"
    volumes:
      - /opt/ai-stack/searxng:/etc/searxng:ro
    environment:
      SEARXNG_BASE_URL: http://searxng.${BASE_DOMAIN}/
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  REVERSE PROXY
  # ════════════════════════════════════════════════════════════════════════════

  # ── Nginx ──────────────────────────────────────────────────────────────────────
  # Routes subdomain requests to the appropriate containers.
  # Virtual host configs are in /opt/ai-stack/nginx/conf.d/ (one file per service).
  # Reload config without downtime: docker exec nginx nginx -s reload
  nginx:
    image: nginx:alpine
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/ai-stack/nginx/conf.d:/etc/nginx/conf.d:ro
      - /opt/ai-stack/nginx/certs:/etc/nginx/certs:ro
    depends_on:
      - open-webui
      - anythingllm
      - open-terminal
      - mcpo
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  OBSERVABILITY
  # ════════════════════════════════════════════════════════════════════════════

  # ── Prometheus Node Exporter ───────────────────────────────────────────────────
  # Exposes host system metrics (CPU, RAM, disk, network) at :9100/metrics.
  # Scraped by Prometheus on monitoring-vm every 15s.
  # pid: host is required for accurate per-process metrics.
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
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc)($$|/)'
    networks:
      - ai-net

  # ── NVIDIA GPU Exporter ────────────────────────────────────────────────────────
  # Exposes GPU metrics (utilisation, VRAM, temperature, power) at :9445/metrics.
  # Grafana dashboard ID 14574 visualises these. Requires GPU access.
  nvidia-exporter:
    image: mindprince/nvidia_gpu_prometheus_exporter:0.1
    container_name: nvidia-exporter
    restart: unless-stopped
    ports:
      - "9445:9445"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    networks:
      - ai-net

COMPOSE
    info "docker-compose.yml written ✓"
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

# ---------------------------------------------------------------------------
#  Main — execute installation steps in order
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
#  Post-install summary
# ---------------------------------------------------------------------------
VM_IP=$(hostname -I | awk '{print $1}')

cat <<EOF

${GREEN}════════════════════════════════════════════════════════════════════${NC}
  Full AI VM Stack is running!

  ${BLUE}── Core Services ──────────────────────────────────────────────────${NC}
  Open WebUI       → http://${VM_IP}:3000       (chat.${BASE_DOMAIN})
  AnythingLLM      → http://${VM_IP}:3001       (docs.${BASE_DOMAIN})
  Ollama API       → http://${VM_IP}:11434
  Qdrant           → http://${VM_IP}:6333/dashboard
  Whisper STT      → http://${VM_IP}:8000

  ${BLUE}── Open WebUI Ecosystem ───────────────────────────────────────────${NC}
  Open Terminal    → http://${VM_IP}:8080       (terminal.${BASE_DOMAIN})
  MCPO Proxy       → http://${VM_IP}:8081       (mcpo.${BASE_DOMAIN})
    ├── MCP docs   → http://${VM_IP}:8081/docs
    ├── time       → http://${VM_IP}:8081/time/docs
    ├── fetch      → http://${VM_IP}:8081/fetch/docs
    ├── thinking   → http://${VM_IP}:8081/thinking/docs
    ├── filesystem → http://${VM_IP}:8081/filesystem/docs
    ├── memory     → http://${VM_IP}:8081/memory/docs
    └── git        → http://${VM_IP}:8081/git/docs

  ${BLUE}── OpenAPI Tool Servers ────────────────────────────────────────────${NC}
  Filesystem       → http://${VM_IP}:8082/docs
  Memory Graph     → http://${VM_IP}:8083/docs
  Git              → http://${VM_IP}:8084/docs
  SQL              → http://${VM_IP}:8085/docs

  ${BLUE}── Search ──────────────────────────────────────────────────────────${NC}
  SearXNG          → http://${VM_IP}:8086       (search.${BASE_DOMAIN})

  ${BLUE}── API Key (for tool server auth) ─────────────────────────────────${NC}
  MCPO_API_KEY: ${MCPO_API_KEY}
  (also saved to /opt/ai-stack/mcpo-api-key.txt)

  ${BLUE}── GPU ──────────────────────────────────────────────────────────────${NC}
$(nvidia-smi --query-gpu=name,memory.total,driver_version \
    --format=csv,noheader 2>/dev/null \
    | sed 's/^/  /' \
    || echo "  nvidia-smi not available — reboot may be required")

  ${BLUE}── Post-install Steps ───────────────────────────────────────────────${NC}
  1. Open http://${VM_IP}:3000 → create admin account
  2. Settings → Tools → verify tool servers are connected (green)
  3. Settings → Integrations → Open Terminal → verify connected
  4. Pull production models:
       docker exec ollama ollama pull qwen2.5-coder:32b
       docker exec ollama ollama pull nomic-embed-text
       docker exec ollama ollama pull deepseek-r1:32b

  ${BLUE}── Useful Commands ─────────────────────────────────────────────────${NC}
  All logs:      docker compose -f /opt/ai-stack/docker-compose.yml logs -f
  Single log:    docker logs -f mcpo
  Update all:    cd /opt/ai-stack && docker compose pull && docker compose up -d
  Reload nginx:  docker exec nginx nginx -s reload
${GREEN}════════════════════════════════════════════════════════════════════${NC}
EOF
