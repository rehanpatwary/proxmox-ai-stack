# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Proxmox VE automation project for deploying a self-hosted AI stack across 5 Ubuntu VMs. All scripts are Bash and run either on the **Proxmox host** (as root) or **inside individual VMs** (as root via sudo).

The repository contains one folder: `proxmox-ai-stack/` — the primary, actively maintained stack.

## Project Structure

```
proxmox-ai-stack/
  config.env               ← single source of truth for all config (IPs, VM IDs, secrets)
  host/                    ← run these ON the Proxmox host (as root)
    setup-gpu.sh           ← GPU passthrough setup + reboot
    init-secrets.sh        ← run ONCE to generate secrets into config.env
    create-template.sh     ← builds a reusable Ubuntu Proxmox template (VMID 199)
    create-vms.sh          ← creates all 5 VMs; supports USE_TEMPLATE=1 for clone-based workflow
    deploy-all.sh          ← orchestrates all 5 VMs via SSH
    deploy-vm.sh           ← deploys a single VM; supports --dry-run, --no-wait
    export-env.sh          ← helper to source config.env for manual use
  vms/                     ← deployed TO each VM via SSH
    common/
      bootstrap.sh         ← shared VM hygiene: chrony, journald limits, TRIM, admin tools
    ai/
      setup.sh             ← orchestrator: NVIDIA drivers, Docker, full AI tool stack (15 services)
      install-nvidia.sh    ← NVIDIA driver + container toolkit
      install-docker.sh    ← Docker CE + Compose
      generate-compose.sh  ← writes docker-compose.yml
    coding/
      setup.sh             ← OpenCode + Continue IDE pointing at ai-vm Ollama
    data/
      setup.sh             ← Postgres 16 + pgvector + pgAdmin
    automation/
      setup.sh             ← n8n + Flowise
    monitoring/
      setup.sh             ← Prometheus + Grafana + Alertmanager
  lxc/                     ← optional: 60+ extra LXC containers
    deploy-stack.sh        ← entry point (interactive or --all/--phase N)
    wire-to-vms.sh         ← connects LXC containers to VM services
    apps.sh                ← 60+ app definitions across 10 phases
  docs/
    lxc-integration.md
    troubleshooting.md
```

## VM Architecture

| VM | IP (default) | Services |
|----|-------------|---------|
| ai-vm | 10.0.3.10 | Ollama (:11434), Open WebUI (:3000), AnythingLLM (:3001), Qdrant (:6333), Whisper (:8000), Open Terminal (:8080), MCPO (:8081), OpenAPI Filesystem/Memory/Git/SQL (:8082-8085), SearXNG (:8086), Nginx (:80/:443), node-exporter (:9100), nvidia-exporter (:9445) |
| coding-vm | 10.0.3.20 | OpenCode / Continue IDE extension, node-exporter (:9100) |
| data-vm | 10.0.3.30 | Postgres 16 + pgvector (:5432), pgAdmin (:5050), node-exporter (:9100) |
| automation-vm | 10.0.3.40 | n8n (:5678), Flowise (:3002), node-exporter (:9100) |
| monitoring-vm | 10.0.3.50 | Grafana (:3003), Prometheus (:9090), Alertmanager (:9093), node-exporter (:9100) |

Template VM (VMID 199) is ephemeral — created by `host/create-template.sh`, used for cloning, not running.

## Deployment Sequence

```bash
# 1. Configure
nano proxmox-ai-stack/config.env              # set IPs, SSH key, STORAGE, BRIDGE
bash proxmox-ai-stack/host/init-secrets.sh   # generates secrets once into config.env

# 2. GPU passthrough (Proxmox host as root)
bash proxmox-ai-stack/host/setup-gpu.sh
reboot

# 3a. Create VMs — direct import (default)
bash proxmox-ai-stack/host/create-vms.sh

# 3b. Create VMs — template-based (faster, recommended for rebuilds)
bash proxmox-ai-stack/host/create-template.sh              # once: builds frozen template VMID 199
USE_TEMPLATE=1 bash proxmox-ai-stack/host/create-vms.sh   # clones template instead of re-importing

# 4. Deploy all services
bash proxmox-ai-stack/host/deploy-all.sh

# Or deploy a single VM
bash proxmox-ai-stack/host/deploy-vm.sh ai
bash proxmox-ai-stack/host/deploy-vm.sh data --no-wait     # skip SSH wait if VM already up
bash proxmox-ai-stack/host/deploy-vm.sh ai --dry-run       # preview without executing

# 5. Optional: deploy LXC services (60+ apps in 10 phases)
bash proxmox-ai-stack/lxc/deploy-stack.sh             # interactive menu
bash proxmox-ai-stack/lxc/deploy-stack.sh --all       # deploy everything
bash proxmox-ai-stack/lxc/deploy-stack.sh --phase 4   # deploy phase 4 (Business/Finance)
```

## Key Design Patterns

- **`config.env` is the source of truth** — all scripts source it via `source "$(dirname "$0")/../config.env"` (path relative to the script, not `$PWD`). Never hardcode IPs or credentials in scripts.
- **Secrets flow**: `host/init-secrets.sh` writes static values into `config.env`. `host/deploy-vm.sh` builds an `ENV_BLOCK` using `build_env_block()`, single-quoting every value (`export KEY='VALUE'`) to prevent special characters (`$`, `!`) from being misinterpreted by the remote shell. The remote `setup.sh` is invoked with `sudo -E` to preserve the exports.
- **Idempotency**: Each `setup.sh` checks if software is already installed before installing. VM creation skips existing VM IDs. `vms/common/bootstrap.sh` uses a sentinel file (`/var/lib/vm-bootstrap-done`) to skip on re-runs.
- **Common bootstrap**: Every `setup.sh` sources `../common/bootstrap.sh` as its first step. This installs admin tools (htop, tmux, chrony, nvme-cli, smartmontools, pciutils, ethtool), enables NTP, caps journald, and enables SSD TRIM. Deploy runs this exactly once per VM.
- **host/deploy-all.sh** runs each VM in a subshell so failures don't abort the whole deployment; results are summarized at the end. Redeploy failed VMs with `bash proxmox-ai-stack/host/deploy-vm.sh <name>`.
- **host/deploy-vm.sh** copies both the VM-specific subdir AND `vms/common/` to the remote VM so `bootstrap.sh` is available.
- **vm setup scripts** are run remotely via `ssh -t` with env vars injected — they must not rely on interactive prompts and must be run as root.
- **Template workflow**: `host/create-template.sh` builds VMID 199 from the Ubuntu cloud image. `host/create-vms.sh` with `USE_TEMPLATE=1` uses `qm clone` instead of re-importing the cloud image for each VM — significantly faster for rebuilds.

## Configuration

Before any deployment, edit `proxmox-ai-stack/config.env`:
- `SSH_PUBLIC_KEY` — your ed25519 public key
- `STORAGE` — Proxmox storage pool name (check with `pvesm status`)
- `BRIDGE` — network bridge (check with `ip link show`)
- `GATEWAY` / `*_VM_IP` — match your network
- `TEMPLATE_VMID` — VMID for the reusable template (default: 199; must not conflict with VMs 200-204 or LXC 400+)
- Secrets (`POSTGRES_PASSWORD`, etc.) — set by `host/init-secrets.sh`, never manually

**Never** assign secrets using `$(openssl rand ...)` directly in `config.env` — command substitutions re-execute on every `source`, generating a new value each time and breaking all services that rely on a consistent password.

## AI VM Docker Stack

`vms/ai/setup.sh` (via `generate-compose.sh`) generates `/opt/ai-stack/docker-compose.yml` at runtime. All 15 services share the `ai-net` bridge network. GPU-dependent services (Ollama, Whisper, nvidia-exporter) use `deploy.resources.reservations.devices`.

Key tool server architecture:
- **MCPO** (:8081) — proxies stdio MCP servers (time, fetch, thinking, filesystem, memory, git) to HTTP/OpenAPI
- **OpenAPI servers** (:8082-8085) — native HTTP tool servers (filesystem, memory, git, SQL)
- **Open Terminal** (:8080) — sandboxed AI-controlled Linux shell
- All tool servers are pre-registered in Open WebUI via `TOOL_SERVER_CONNECTIONS` env var

Manage the stack on ai-vm:
```bash
ssh ubuntu@10.0.3.10
cd /opt/ai-stack
docker compose ps
docker compose pull && docker compose up -d   # update all images
docker exec ollama ollama pull <model>
cat /opt/ai-stack/mcpo-api-key.txt            # retrieve MCPO API key
```

## LXC Stack (Optional Extension)

`lxc/apps.sh` deploys 60+ community-script LXC containers (VMIDs 400-499) across 10 phases without touching the 5 VMs.

**Always use `lxc/deploy-stack.sh` as the entry point**, never call `lxc/apps.sh` directly when VMs are running. The wrapper does three things before handing off via `exec`:
1. Pre-marks VM-hosted services (ollama, open-webui, n8n, postgresql, grafana, etc.) in `/root/.proxmox-ai-deploy-state` so `lxc/apps.sh` skips them
2. Exports VM endpoints under multiple naming conventions (`OLLAMA_BASE_URL`, `DATABASE_HOST`, `POSTGRES_HOST`, `DB_HOST`, etc.) to cover the varying env var names used by different community scripts
3. Passes `BRIDGE`, `GATEWAY`, `STORAGE` from `config.env` to the LXC deployer

`lxc/apps.sh` tracks state in `/root/.proxmox-ai-deploy-state` (one app name per line). The interactive `--phase N` mode shows a checkbox UI — new apps are numbered/pre-selected, existing Proxmox containers show as `[✓ skip]`, state-file entries with no matching VMID show as `[! MISSING]`. The `--all` flag bypasses the UI entirely (batch mode).

LXC phases: Infrastructure → AI & LLM → Automation → Business/Finance → Documents/Knowledge → Communication → Monitoring → Workspace/Storage → Security/Identity → Dev/Code

## Shell Coding Standards

**Strict mode** — two distinct patterns are used intentionally:
- `set -euo pipefail` — scripts that must abort on any failure
- `set -uo pipefail` (no `-e`) — scripts that deploy multiple independent units (e.g. `deploy_all.sh`) where one failure must not abort the rest; the reason must be documented with an inline comment

**Logging helpers** — define these in every script; never use raw `echo` with ANSI codes:
```bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
```

**Variable naming:**
| Scope | Convention |
|---|---|
| Global config | `UPPER_SNAKE_CASE` |
| Local (inside function) | `lower_snake_case` via `local` |
| Loop variables | `lower_snake_case` |

**Function doc comments** — required above every function:
```bash
##
# Brief one-line description.
#
# Arguments:
#   $1 - NAME   description
# Returns:
#   0 on success, 1 on failure
# Side effects:
#   Writes to /etc/... or modifies $SOME_GLOBAL
##
```
Omit sections that do not apply.

**SSH calls** must always include:
```bash
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
```
`BatchMode=yes` prevents SSH from hanging when key auth fails.

**Heredocs:** use `<<'EOF'` (quoted) when the content must not expand variables; use `<<EOF` (unquoted) when expansion is intentional.

**Arithmetic under `set -e`:** avoid `((var++))` — it exits with code 1 when the expression evaluates to 0 (i.e. when `var` was 0 before increment). Use `var=$(( var + 1 ))` instead.

**Subshell error isolation** for multi-unit deployment:
```bash
( set -e; do_work )
code=$?
[[ $code -ne 0 ]] && warn "Failed with exit $code"
```
Never use `|| true` to silently swallow errors unless the failure is expected and documented.

## Extending the Stack

### Adding a new VM role
1. Create `vms/<role>/setup.sh` following the structure of existing setup scripts.
2. Add IP, VMID, and resource variables to `proxmox-ai-stack/config.env`.
3. Add the VM to `host/deploy-all.sh` in dependency order and as a `case` in `host/deploy-vm.sh`.
4. Add the VM's `node-exporter` endpoint to `vms/monitoring/prometheus.yml`.

### Adding a new LXC app or phase
1. Add entries to the `APPS` array in `lxc/apps.sh`:
   ```
   "VMID|NAME|SCRIPT_NAME|TYPE|CPU|RAM|DISK|PHASE|CATEGORY|DESCRIPTION"
   ```
2. If the service connects to a VM (Ollama, Postgres), add a wiring block to `lxc/wire-to-vms.sh`.
3. If the service duplicates one already in a VM, add it to `mark_vm_services_as_deployed()` in `lxc/deploy-stack.sh`.

## Commit Message Format

```
type(scope): short description

Longer explanation if needed. Wrap at 72 characters.
```

Types: `feat`, `fix`, `docs`, `refactor`, `chore`

Examples:
```
feat(ai-vm): add cAdvisor container for Docker metrics
fix(deploy): use --batch --no-tty for NVIDIA GPG dearmor
refactor(lxc-stack): add interactive phase selection UI
```
