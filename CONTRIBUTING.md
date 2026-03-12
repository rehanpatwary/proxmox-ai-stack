# Contributing

## Coding Standards

All shell scripts in this repository follow the standards below. Pull requests that deviate will be asked to revise before merging.

---

### Shell Script Standards

#### Shebang and strict mode

Every script must start with:

```bash
#!/usr/bin/env bash
```

Scripts that run top-to-bottom and must abort on any failure use:

```bash
set -euo pipefail
```

Scripts that deploy multiple independent units (e.g. `deploy_all.sh`) where one failure must not abort the rest use:

```bash
set -uo pipefail   # no -e intentionally — individual failures are isolated in subshells
```

The reason for the difference must be documented with an inline comment.

#### Logging helpers

Every script defines these four helpers immediately after strict mode:

```bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# info  — normal progress messages
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }

# section — major phase separator (printed before each logical block)
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }

# warn  — non-fatal issues; execution continues
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

# error — fatal error; always exits 1
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
```

Use these — do not add `echo` calls with raw ANSI codes.

#### Root guard

Scripts that must run as root check at the top, before doing any work:

```bash
[[ $EUID -ne 0 ]] && error "Must run as root"
```

#### Function documentation

Every function must have a doc comment immediately above it:

```bash
##
# Brief one-line description of what the function does.
#
# Arguments:
#   $1 - NAME   description of first argument
#   $2 - VALUE  description of second argument
#
# Returns:
#   0 on success, 1 on failure
#
# Side effects:
#   Writes to /etc/... or modifies $SOME_GLOBAL
##
my_function() {
    local name="$1"
    local value="$2"
    ...
}
```

Omit sections that do not apply (e.g. no "Returns" block for functions that always exit 1 on failure).

#### Variable naming

| Scope | Convention | Example |
|---|---|---|
| Global (config) | `UPPER_SNAKE_CASE` | `AI_VM_IP`, `POSTGRES_PASSWORD` |
| Local (inside function) | `lower_snake_case` via `local` | `local vm_id=200` |
| Loop variables | `lower_snake_case` | `for entry in ...` |
| Constants | `UPPER_SNAKE_CASE` | `readonly SSH_OPTS="..."` |

All local variables inside functions must be declared with `local`.

#### Section headers

Use consistent width section banners to separate logical phases:

```bash
section "Installing Docker"
```

This produces:

```
══ Installing Docker ══
```

Do not use ad-hoc `echo "=== ... ==="` lines.

#### Idempotency

Every setup step must be idempotent — safe to run twice without breaking the system. Use guard checks:

```bash
# Check before installing
if command -v docker &>/dev/null; then
    info "Docker already installed ($(docker --version))"
else
    # install
fi

# Check before creating a resource
if qm status "$VM_ID" &>/dev/null; then
    warn "VM $VM_ID already exists — skipping"
    return
fi
```

#### Error handling in subshells

When deploying multiple independent units, run each in a subshell and capture the exit code:

```bash
(
    set -e
    do_work
)
local code=$?
if [[ $code -ne 0 ]]; then
    warn "Unit failed with exit $code"
fi
```

Never use `|| true` to silently swallow errors unless the failure is genuinely expected and documented.

#### Secrets

- Never assign secrets using `$(openssl rand ...)` directly in `config.env` — they regenerate on every `source`.
- Secrets are generated once by `init_secrets.sh` and stored as static strings.
- Never log secret values. Never echo passwords in output.

#### SSH calls

All SSH calls must include non-interactive options:

```bash
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
```

`BatchMode=yes` prevents SSH from hanging waiting for a password when key auth fails.

#### Heredocs

Use heredocs with a quoted delimiter when the content must not expand variables:

```bash
cat > /path/to/file <<'EOF'
literal content $NOT_EXPANDED
EOF
```

Use an unquoted delimiter when variable expansion is intentional:

```bash
cat > /path/to/file <<EOF
server address: ${SERVER_IP}
EOF
```

---

### File and Directory Layout

```
proxmox-ai-stack/
├── config.env               # Single source of truth for all settings
├── init_secrets.sh          # One-time secret initialiser
├── 00_gpu_passthrough.sh    # Proxmox host: VFIO setup
├── 01_create_vms.sh         # Proxmox host: VM provisioning
├── deploy_all.sh            # Proxmox host: orchestrate all VM deployments
├── deploy_vm.sh             # Proxmox host: deploy a single VM
├── export_env.sh            # Proxmox host: generate env exports for manual use
├── deploy_lxc_stack.sh      # Proxmox host: LXC integration wrapper
├── wire_lxc_to_vms.sh       # Proxmox host: post-deploy LXC config patching
├── lxc-stack.sh             # Proxmox host: community-scripts LXC deployer
├── ai-vm/
│   └── setup.sh             # Runs inside ai-vm
├── coding-vm/
│   └── setup.sh             # Runs inside coding-vm
├── data-vm/
│   └── setup.sh             # Runs inside data-vm
├── automation-vm/
│   └── setup.sh             # Runs inside automation-vm
├── monitoring/
│   └── setup.sh             # Runs inside monitoring-vm
└── docs/
    ├── architecture.md
    ├── configuration.md
    ├── lxc-integration.md
    └── troubleshooting.md
```

Rules:
- Scripts that run on the **Proxmox host** live at the repo root.
- Scripts that run **inside a VM** live in their VM's subdirectory.
- All scripts source `config.env` via `source "$(dirname "$0")/config.env"` — path relative to the script, not `$PWD`.

---

### Adding a New VM Role

1. Create `<role>-vm/setup.sh` following the same structure as existing setup scripts.
2. Add the VM's IP, ID, and resource variables to `config.env`.
3. Add the VM to `deploy_all.sh` in the correct dependency order.
4. Add the VM as a case in `deploy_vm.sh`.
5. Add the VM's `node-exporter` endpoint to `monitoring/prometheus.yml`.
6. Document the new service in `README.md` under Service Catalog.

### Adding a New LXC Phase

1. Add entries to the `APPS` array in `lxc-stack.sh` following the existing format:
   ```
   "VMID|NAME|SCRIPT_NAME|TYPE|CPU|RAM|DISK|PHASE|CATEGORY|DESCRIPTION"
   ```
2. If the new service needs to connect to a VM (Ollama, Postgres, etc.), add a wiring block to `wire_lxc_to_vms.sh`.
3. Add a `VM_DEPLOYED_SERVICES` entry to `deploy_lxc_stack.sh` if the service duplicates one already running in a VM.

---

### Commit Message Format

```
type(scope): short description

Longer explanation if needed. Wrap at 72 characters.
```

Types: `feat`, `fix`, `docs`, `refactor`, `chore`

Examples:

```
feat(ai-vm): add cAdvisor container for Docker metrics
fix(deploy): use --batch --no-tty for NVIDIA GPG dearmor
docs(readme): add Grafana dashboard import IDs
refactor(config): move cloud image vars to top of config block
```
