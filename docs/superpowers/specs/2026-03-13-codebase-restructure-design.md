# Codebase Restructure Design

**Date:** 2026-03-13
**Status:** Approved
**Goal:** Restructure the Proxmox AI Stack repository for public/open-source clarity without changing any functionality.

---

## Problem

Three compounding issues make the codebase hard for new contributors to navigate:

1. **Scripts are too long** — `ai-vm/setup.sh` is 1341 lines mixing GPU setup, Docker install, and 15-service Compose generation in one file.
2. **Top-level is cluttered** — all scripts live flat at the root with no grouping by purpose or execution context.
3. **Naming is inconsistent** — numbered prefixes (`00_`, `01_`), underscores, and plain verbs are used arbitrarily.

---

## Approach

**Role-namespaced layout with decomposed large scripts.**

Scripts grouped by *where they run* (`host/`, `vms/`, `lxc/`). The repo root becomes a container for stacks, making it extensible for future additions (e.g. `k8s-stack/`). The largest script (`ai-vm/setup.sh`) is split by concern into a thin orchestrator + 3 focused files.

Rejected alternatives:
- *Minimal rename only* — doesn't address script length or clutter.
- *Shared lib layer* — adds indirection; logging helpers are small enough not to justify it yet.

---

## Folder Structure

```
repo root/
├── README.md                  ← repo overview, points to stacks
├── CONTRIBUTING.md
├── LICENSE
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
    │   │   ├── install-nvidia.sh
    │   │   ├── install-docker.sh
    │   │   └── generate-compose.sh
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

`vms/ai/setup.sh` becomes a ~40-line orchestrator:

| File | Responsibility | Approx. Lines |
|------|---------------|---------------|
| `setup.sh` | Sources bootstrap, calls the 3 installers in order, runs `docker compose up` | ~40 |
| `install-nvidia.sh` | NVIDIA driver + container toolkit install | ~150 |
| `install-docker.sh` | Docker CE install + daemon config | ~80 |
| `generate-compose.sh` | Writes `/opt/ai-stack/docker-compose.yml` with all 15 services | ~900 |

`generate-compose.sh` remains large by design — it is primarily a data definition (15 service blocks in a heredoc), not logic. Splitting it further would create unnecessary indirection.

---

## Internal Script Changes

All changes are **path and reference updates only** — no logic changes.

### `config.env` sourcing
```bash
# host/ scripts (1 level deep from stack root)
source "$(dirname "$0")/../config.env"

# vms/ai/ scripts (2 levels deep)
source "$(dirname "$0")/../../config.env"

# lxc/ scripts (1 level deep)
source "$(dirname "$0")/../config.env"
```

### deploy-vm.sh copy paths
Updated to copy `vms/ai/` and `vms/common/` instead of `ai-vm/` and `common/`.

### deploy-all.sh references
Script calls updated to reference files in `host/`.

### ai/setup.sh orchestrator
```bash
source "$(dirname "$0")/install-nvidia.sh"
source "$(dirname "$0")/install-docker.sh"
source "$(dirname "$0")/generate-compose.sh"
```

### lxc/deploy-stack.sh
Reference to `lxc-stack.sh` updated to `./apps.sh`.

### Documentation
`CLAUDE.md`, stack `README.md`, and `docs/` updated to reflect new paths and filenames throughout.

---

## File Rename Map

| Old path | New path |
|----------|----------|
| `00_gpu_passthrough.sh` | `proxmox-ai-stack/host/setup-gpu.sh` |
| `01_create_vms.sh` | `proxmox-ai-stack/host/create-vms.sh` |
| `create_template.sh` | `proxmox-ai-stack/host/create-template.sh` |
| `init_secrets.sh` | `proxmox-ai-stack/host/init-secrets.sh` |
| `deploy_all.sh` | `proxmox-ai-stack/host/deploy-all.sh` |
| `deploy_vm.sh` | `proxmox-ai-stack/host/deploy-vm.sh` |
| `export_env.sh` | `proxmox-ai-stack/host/export-env.sh` |
| `config.env` | `proxmox-ai-stack/config.env` |
| `common/bootstrap.sh` | `proxmox-ai-stack/vms/common/bootstrap.sh` |
| `ai-vm/setup.sh` | `proxmox-ai-stack/vms/ai/setup.sh` (+ 3 new split files) |
| `coding-vm/setup.sh` | `proxmox-ai-stack/vms/coding/setup.sh` |
| `data-vm/setup.sh` | `proxmox-ai-stack/vms/data/setup.sh` |
| `automation-vm/setup.sh` | `proxmox-ai-stack/vms/automation/setup.sh` |
| `monitoring/setup.sh` | `proxmox-ai-stack/vms/monitoring/setup.sh` |
| `deploy_lxc_stack.sh` | `proxmox-ai-stack/lxc/deploy-stack.sh` |
| `wire_lxc_to_vms.sh` | `proxmox-ai-stack/lxc/wire-to-vms.sh` |
| `lxc-stack.sh` | `proxmox-ai-stack/lxc/apps.sh` |
| `docs/` | `proxmox-ai-stack/docs/` |

---

## Success Criteria

- A new contributor can read the top-level `README.md` and know exactly which folder to open and which script to run first
- Every script's purpose is clear from its filename and location alone
- No script does more than one logical job
- All existing functionality works identically after the restructure
- `CLAUDE.md` accurately reflects the new structure
