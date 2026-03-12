# Codebase Restructure Design

**Date:** 2026-03-13
**Status:** Approved
**Goal:** Restructure the Proxmox AI Stack repository for public/open-source clarity without changing any functionality.

---

## Problem

Three compounding issues make the codebase hard for new contributors to navigate:

1. **Scripts are too long** — `ai-vm/setup.sh` is 1341 lines mixing GPU setup, Docker install, and 15-service Compose generation in one file.
2. **Top-level is cluttered** — all scripts live flat at the repo root with no grouping by purpose or execution context.
3. **Naming is inconsistent** — numbered prefixes (`00_`, `01_`), underscores, and plain verbs are used arbitrarily.

---

## Approach

**Role-namespaced layout with decomposed large scripts.**

Scripts are grouped by *where they run* (`host/`, `vms/`, `lxc/`). The repo root becomes a container for stacks, making it extensible for future additions (e.g. `k8s-stack/`). The largest script (`ai-vm/setup.sh`) is split by concern into a thin orchestrator + 3 focused files.

Rejected alternatives:
- *Minimal rename only* — doesn't address script length or clutter.
- *Shared lib layer* — adds indirection; logging helpers are small enough not to justify it yet.

---

## How the Move Works

The current repo root contains all scripts flat alongside `ai-vm/`, `common/`, `monitoring/`, etc. subdirectories. The restructure creates a `proxmox-ai-stack/` subdirectory inside the repo root and moves everything into it via `git mv`. Files that belong to the repo (not the stack) stay at the root.

```
Before:                          After:
repo-root/                       repo-root/
├── 00_gpu_passthrough.sh        ├── README.md          (updated)
├── 01_create_vms.sh             ├── CONTRIBUTING.md    (unchanged)
├── config.env                   ├── LICENSE            (unchanged)
├── deploy_all.sh                ├── CLAUDE.md          (updated)
├── ...                          ├── .gitignore         (unchanged)
├── ai-vm/setup.sh               ├── .claude/           (unchanged)
├── common/                      └── proxmox-ai-stack/
├── docs/                            ├── config.env
└── README.md                        ├── host/
                                     ├── vms/
                                     ├── lxc/
                                     └── docs/
```

### Execution sequence

```bash
# 1. Create target directories
mkdir -p proxmox-ai-stack/host
mkdir -p proxmox-ai-stack/vms/{common,ai,coding,data,automation,monitoring}
mkdir -p proxmox-ai-stack/lxc
mkdir -p proxmox-ai-stack/docs/superpowers/specs

# 2. Move host scripts
git mv 00_gpu_passthrough.sh  proxmox-ai-stack/host/setup-gpu.sh
git mv 01_create_vms.sh       proxmox-ai-stack/host/create-vms.sh
git mv create_template.sh     proxmox-ai-stack/host/create-template.sh
git mv init_secrets.sh        proxmox-ai-stack/host/init-secrets.sh
git mv deploy_all.sh          proxmox-ai-stack/host/deploy-all.sh
git mv deploy_vm.sh           proxmox-ai-stack/host/deploy-vm.sh
git mv export_env.sh          proxmox-ai-stack/host/export-env.sh

# 3. Move config
git mv config.env             proxmox-ai-stack/config.env

# 4. Move common
git mv common/bootstrap.sh    proxmox-ai-stack/vms/common/bootstrap.sh

# 5. Move VM setup scripts
git mv ai-vm/setup.sh         proxmox-ai-stack/vms/ai/setup.sh
git mv coding-vm/setup.sh     proxmox-ai-stack/vms/coding/setup.sh
git mv data-vm/setup.sh       proxmox-ai-stack/vms/data/setup.sh
git mv automation-vm/setup.sh proxmox-ai-stack/vms/automation/setup.sh
git mv monitoring/setup.sh    proxmox-ai-stack/vms/monitoring/setup.sh

# 6. Move LXC scripts
git mv deploy_lxc_stack.sh    proxmox-ai-stack/lxc/deploy-stack.sh
git mv wire_lxc_to_vms.sh     proxmox-ai-stack/lxc/wire-to-vms.sh
git mv lxc-stack.sh           proxmox-ai-stack/lxc/apps.sh

# 7. Move docs
git mv docs/lxc-integration.md    proxmox-ai-stack/docs/lxc-integration.md
git mv docs/troubleshooting.md    proxmox-ai-stack/docs/troubleshooting.md
git mv docs/superpowers           proxmox-ai-stack/docs/superpowers

# 8. Create new split files (git add, not git mv — these are new)
# (edit proxmox-ai-stack/vms/ai/setup.sh into the orchestrator, then:)
# touch proxmox-ai-stack/vms/ai/install-nvidia.sh
# touch proxmox-ai-stack/vms/ai/install-docker.sh
# touch proxmox-ai-stack/vms/ai/generate-compose.sh
# git add proxmox-ai-stack/vms/ai/

# 9. Create new stack-level README
# touch proxmox-ai-stack/README.md
# git add proxmox-ai-stack/README.md
```

---

## Folder Structure

```
repo root/
├── README.md                  ← repo overview, points to stacks
├── CONTRIBUTING.md            ← unchanged
├── LICENSE                    ← unchanged
├── CLAUDE.md                  ← updated to reflect new paths
├── .gitignore                 ← unchanged
├── .claude/                   ← unchanged (Claude Code local settings)
└── proxmox-ai-stack/          ← future stacks sit alongside this
    ├── config.env             ← single source of truth (unchanged)
    ├── README.md              ← deployment sequence, VM table, quick-start
    ├── docs/
    │   ├── lxc-integration.md
    │   ├── troubleshooting.md
    │   └── superpowers/specs/ ← design docs (this file)
    │
    ├── host/                  ← run ON the Proxmox host (as root)
    │   ├── setup-gpu.sh       ← was: 00_gpu_passthrough.sh
    │   ├── init-secrets.sh    ← was: init_secrets.sh
    │   ├── create-template.sh ← was: create_template.sh
    │   ├── create-vms.sh      ← was: 01_create_vms.sh
    │   ├── deploy-all.sh      ← was: deploy_all.sh
    │   ├── deploy-vm.sh       ← was: deploy_vm.sh
    │   └── export-env.sh      ← was: export_env.sh
    │
    ├── vms/                   ← deployed TO VMs via SSH
    │   ├── common/
    │   │   └── bootstrap.sh   ← unchanged
    │   ├── ai/
    │   │   ├── setup.sh       ← thin orchestrator (~40 lines)
    │   │   ├── install-nvidia.sh   ← source-only, not standalone
    │   │   ├── install-docker.sh   ← source-only, not standalone
    │   │   └── generate-compose.sh ← source-only, not standalone
    │   ├── coding/
    │   │   └── setup.sh
    │   ├── data/
    │   │   └── setup.sh
    │   ├── automation/
    │   │   └── setup.sh
    │   └── monitoring/
    │       └── setup.sh
    │
    └── lxc/                   ← optional LXC container layer
        ├── deploy-stack.sh    ← was: deploy_lxc_stack.sh
        ├── wire-to-vms.sh     ← was: wire_lxc_to_vms.sh
        └── apps.sh            ← was: lxc-stack.sh
```

---

## AI VM Decomposition

### The split

`vms/ai/setup.sh` is produced via `git mv ai-vm/setup.sh proxmox-ai-stack/vms/ai/setup.sh`, then edited in-place to become the ~40-line orchestrator (preserving git history). The 3 new split files are created fresh with `git add` (no history to preserve — they are extracted from the moved file).

The 3 split files are **source-only** — not standalone executables. They must never be called directly with `bash`. The orchestrator sources them, so they inherit all variables without re-sourcing config themselves.

Each split file begins with `set -euo pipefail` (re-setting strict mode inside a sourced file is safe and harmless in Bash; it also makes the files auditable in isolation).

| File | Responsibility | Approx. Lines |
|------|---------------|---------------|
| `setup.sh` | Orchestrator: sources bootstrap, sources the 3 files, runs `docker compose up` | ~40 |
| `install-nvidia.sh` | NVIDIA driver + container toolkit install | ~150 |
| `install-docker.sh` | Docker CE install + daemon config | ~80 |
| `generate-compose.sh` | Writes `/opt/ai-stack/docker-compose.yml` with all 15 services | ~900 |

`generate-compose.sh` remains large by design — it is primarily a data definition (15 service blocks in a heredoc), not logic.

### How variables reach the split files

`deploy-vm.sh` injects all config values as a remote `ENV_BLOCK` before executing `setup.sh` on the VM. The VM setup scripts therefore **do not source `config.env` directly** — all variables are already exported in the remote shell environment when `setup.sh` starts.

The orchestrator pattern (no config.env source — variables arrive via ENV_BLOCK):

```bash
#!/usr/bin/env bash
# vms/ai/setup.sh — AI VM orchestrator
# Run remotely via deploy-vm.sh; all config vars are pre-exported by the deploy script.
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"

source "${SCRIPT_DIR}/../common/bootstrap.sh"
source "${SCRIPT_DIR}/install-nvidia.sh"
source "${SCRIPT_DIR}/install-docker.sh"
source "${SCRIPT_DIR}/generate-compose.sh"

docker compose -f /opt/ai-stack/docker-compose.yml up -d
```

**Host scripts** (`host/*.sh`) run locally on the Proxmox host and do source `config.env` directly:
```bash
source "$(dirname "$0")/../config.env"
```

---

## Internal Script Changes

All changes are **path and reference updates only** — no logic changes.

### `config.env` sourcing (host scripts only)

Host scripts (`host/*.sh`) run locally and source config directly. They are 1 level deep from the stack root:

```bash
source "$(dirname "$0")/../config.env"
```

VM setup scripts and LXC scripts do **not** source `config.env` — they receive variables via `deploy-vm.sh`'s ENV_BLOCK injection (existing behavior, unchanged).

### `vms/*/setup.sh` bootstrap sourcing

All VM setup scripts source bootstrap relative to themselves. From any `vms/<role>/setup.sh`, the path to `vms/common/bootstrap.sh` is `../common/bootstrap.sh` — identical to the current pattern from `<role>-vm/setup.sh` to `common/bootstrap.sh`. No change required beyond verifying the path after the move.

### `deploy-vm.sh` copy paths

`deploy-vm.sh` SCP-copies both the VM-specific directory and `common/` to the remote VM for all 5 roles. All source paths update:

| Role | Old source path | New source path |
|------|----------------|-----------------|
| ai | `ai-vm/` | `vms/ai/` |
| coding | `coding-vm/` | `vms/coding/` |
| data | `data-vm/` | `vms/data/` |
| automation | `automation-vm/` | `vms/automation/` |
| monitoring | `monitoring/` | `vms/monitoring/` |

`common/` → `vms/common/` for all roles.

### `deploy-all.sh` → `deploy-vm.sh` calls

`deploy-all.sh` and `deploy-vm.sh` both live in `host/`. `deploy-all.sh` calls `deploy-vm.sh` via a same-directory relative path (`$(dirname "$0")/deploy-vm.sh`). **No path change is needed.** Only the comment block at the top of `deploy-all.sh` needs updating to reflect the new location.

### `lxc/deploy-stack.sh` → `apps.sh`

The reference to `lxc-stack.sh` inside `deploy_lxc_stack.sh` is updated to `./apps.sh`.

### `prometheus.yml`

`prometheus.yml` is generated at runtime by `vms/monitoring/setup.sh` via a heredoc — it is not a static file in the repository. After the restructure, `monitoring/setup.sh` moves from depth 1 (`monitoring/`) to depth 2 (`vms/monitoring/`). The bootstrap source path changes from `../common/bootstrap.sh` to `../common/bootstrap.sh` — identical relative path because `vms/monitoring/` is still one level away from `vms/common/`. No change is needed inside `monitoring/setup.sh` for bootstrap sourcing. The prometheus.yml generation writes to an absolute path (`/etc/prometheus/prometheus.yml`) so it is unaffected by the script's new location.

### `export-env.sh` operator UX

`export-env.sh` is used interactively: `source export_env.sh`. After the restructure, operators must use the new path:

```bash
source proxmox-ai-stack/host/export-env.sh
```

The stack `README.md` must document this explicitly in the "Configuration" section.

---

## File Rename Map

| Old path (repo root) | New path | Action |
|----------------------|----------|--------|
| `00_gpu_passthrough.sh` | `proxmox-ai-stack/host/setup-gpu.sh` | `git mv` |
| `01_create_vms.sh` | `proxmox-ai-stack/host/create-vms.sh` | `git mv` |
| `create_template.sh` | `proxmox-ai-stack/host/create-template.sh` | `git mv` |
| `init_secrets.sh` | `proxmox-ai-stack/host/init-secrets.sh` | `git mv` |
| `deploy_all.sh` | `proxmox-ai-stack/host/deploy-all.sh` | `git mv` |
| `deploy_vm.sh` | `proxmox-ai-stack/host/deploy-vm.sh` | `git mv` |
| `export_env.sh` | `proxmox-ai-stack/host/export-env.sh` | `git mv` |
| `config.env` | `proxmox-ai-stack/config.env` | `git mv` |
| `common/bootstrap.sh` | `proxmox-ai-stack/vms/common/bootstrap.sh` | `git mv` |
| `ai-vm/setup.sh` | `proxmox-ai-stack/vms/ai/setup.sh` | `git mv`, then edit to orchestrator |
| `coding-vm/setup.sh` | `proxmox-ai-stack/vms/coding/setup.sh` | `git mv` |
| `data-vm/setup.sh` | `proxmox-ai-stack/vms/data/setup.sh` | `git mv` |
| `automation-vm/setup.sh` | `proxmox-ai-stack/vms/automation/setup.sh` | `git mv` |
| `monitoring/setup.sh` | `proxmox-ai-stack/vms/monitoring/setup.sh` | `git mv` |
| `deploy_lxc_stack.sh` | `proxmox-ai-stack/lxc/deploy-stack.sh` | `git mv` |
| `wire_lxc_to_vms.sh` | `proxmox-ai-stack/lxc/wire-to-vms.sh` | `git mv` |
| `lxc-stack.sh` | `proxmox-ai-stack/lxc/apps.sh` | `git mv` |
| `docs/lxc-integration.md` | `proxmox-ai-stack/docs/lxc-integration.md` | `git mv` |
| `docs/troubleshooting.md` | `proxmox-ai-stack/docs/troubleshooting.md` | `git mv` |
| `docs/superpowers/` | `proxmox-ai-stack/docs/superpowers/` | `git mv` (whole dir) |
| `README.md` | `README.md` | stays at root, content updated |
| `CONTRIBUTING.md` | `CONTRIBUTING.md` | stays at root, unchanged |
| `LICENSE` | `LICENSE` | stays at root, unchanged |
| `CLAUDE.md` | `CLAUDE.md` | stays at root, content updated |
| `.gitignore` | `.gitignore` | stays at root, unchanged |
| `.claude/` | `.claude/` | stays at root, unchanged |

New files created (not moved):
| New path | How created |
|----------|-------------|
| `proxmox-ai-stack/vms/ai/install-nvidia.sh` | extracted from `ai-vm/setup.sh`, `git add` |
| `proxmox-ai-stack/vms/ai/install-docker.sh` | extracted from `ai-vm/setup.sh`, `git add` |
| `proxmox-ai-stack/vms/ai/generate-compose.sh` | extracted from `ai-vm/setup.sh`, `git add` |
| `proxmox-ai-stack/README.md` | new file, `git add` |

---

## Success Criteria

1. `bash -n` passes on all scripts:
   ```bash
   bash -n proxmox-ai-stack/host/*.sh \
            proxmox-ai-stack/vms/**/*.sh \
            proxmox-ai-stack/lxc/*.sh
   ```

2. `shellcheck` passes on all scripts (source paths verifiable):
   ```bash
   shellcheck --source-path=proxmox-ai-stack \
              proxmox-ai-stack/host/*.sh \
              proxmox-ai-stack/lxc/*.sh
   ```

3. `git log --follow proxmox-ai-stack/host/deploy-vm.sh` shows full pre-restructure history — confirms `git mv` was used (not delete + create).

4. A new contributor reading only the repo root `README.md` and `proxmox-ai-stack/README.md` can identify which folder to open and which script to run first, without consulting any other file.

5. All existing functionality works identically — no service endpoints, credentials, or deployment behaviors change.

6. `CLAUDE.md` accurately reflects the new structure including all updated paths and deployment sequence commands.
