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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
