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

# error() must be defined before sourcing bootstrap (used for root check below).
# bootstrap.sh defines info/section/warn; it skips redefining if already present.
RED='\033[0;31m'; NC='\033[0m'
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

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
