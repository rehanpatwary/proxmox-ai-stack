# Codebase Restructure Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the Proxmox AI Stack repo into a role-namespaced layout (`host/`, `vms/`, `lxc/`) under a `proxmox-ai-stack/` subdirectory, and split `ai-vm/setup.sh` into 4 focused files — without changing any functionality.

**Architecture:** All files are moved via `git mv` to preserve history. Internal path references are updated to match new depths. `ai-vm/setup.sh` is split into an orchestrator + 3 source-only files by extracting clearly-bounded function groups.

**Tech Stack:** Bash, git

---

## Chunk 1: Create directories and move all files

### Task 1: Create target directory structure

**Files:**
- Create: `proxmox-ai-stack/host/` (dir)
- Create: `proxmox-ai-stack/vms/{common,ai,coding,data,automation,monitoring}/` (dirs)
- Create: `proxmox-ai-stack/lxc/` (dir)

- [ ] **Step 1: Create all target directories**

```bash
mkdir -p proxmox-ai-stack/host
mkdir -p proxmox-ai-stack/vms/common
mkdir -p proxmox-ai-stack/vms/ai
mkdir -p proxmox-ai-stack/vms/coding
mkdir -p proxmox-ai-stack/vms/data
mkdir -p proxmox-ai-stack/vms/automation
mkdir -p proxmox-ai-stack/vms/monitoring
mkdir -p proxmox-ai-stack/lxc
```

- [ ] **Step 2: Verify directories exist**

```bash
find proxmox-ai-stack -type d | sort
```

Expected output: all 9 directories listed above.

---

### Task 2: Move host scripts

**Files:**
- Move: `00_gpu_passthrough.sh` → `proxmox-ai-stack/host/setup-gpu.sh`
- Move: `01_create_vms.sh` → `proxmox-ai-stack/host/create-vms.sh`
- Move: `create_template.sh` → `proxmox-ai-stack/host/create-template.sh`
- Move: `init_secrets.sh` → `proxmox-ai-stack/host/init-secrets.sh`
- Move: `deploy_all.sh` → `proxmox-ai-stack/host/deploy-all.sh`
- Move: `deploy_vm.sh` → `proxmox-ai-stack/host/deploy-vm.sh`
- Move: `export_env.sh` → `proxmox-ai-stack/host/export-env.sh`

- [ ] **Step 1: Move all host scripts**

```bash
git mv 00_gpu_passthrough.sh  proxmox-ai-stack/host/setup-gpu.sh
git mv 01_create_vms.sh       proxmox-ai-stack/host/create-vms.sh
git mv create_template.sh     proxmox-ai-stack/host/create-template.sh
git mv init_secrets.sh        proxmox-ai-stack/host/init-secrets.sh
git mv deploy_all.sh          proxmox-ai-stack/host/deploy-all.sh
git mv deploy_vm.sh           proxmox-ai-stack/host/deploy-vm.sh
git mv export_env.sh          proxmox-ai-stack/host/export-env.sh
```

- [ ] **Step 2: Verify moves**

```bash
ls proxmox-ai-stack/host/
```

Expected: `create-template.sh  create-vms.sh  deploy-all.sh  deploy-vm.sh  export-env.sh  init-secrets.sh  setup-gpu.sh`

- [ ] **Step 3: Commit**

```bash
git add proxmox-ai-stack/host/
git commit -m "refactor(host): move host scripts into host/ with consistent naming"
```

---

### Task 3: Move config, common, and VM setup scripts

**Files:**
- Move: `config.env` → `proxmox-ai-stack/config.env`
- Move: `common/bootstrap.sh` → `proxmox-ai-stack/vms/common/bootstrap.sh`
- Move: `ai-vm/setup.sh` → `proxmox-ai-stack/vms/ai/setup.sh`
- Move: `coding-vm/setup.sh` → `proxmox-ai-stack/vms/coding/setup.sh`
- Move: `data-vm/setup.sh` → `proxmox-ai-stack/vms/data/setup.sh`
- Move: `automation-vm/setup.sh` → `proxmox-ai-stack/vms/automation/setup.sh`
- Move: `monitoring/setup.sh` → `proxmox-ai-stack/vms/monitoring/setup.sh`

- [ ] **Step 1: Move config and common**

```bash
git mv config.env             proxmox-ai-stack/config.env
git mv common/bootstrap.sh    proxmox-ai-stack/vms/common/bootstrap.sh
```

- [ ] **Step 2: Move VM setup scripts**

```bash
git mv ai-vm/setup.sh         proxmox-ai-stack/vms/ai/setup.sh
git mv coding-vm/setup.sh     proxmox-ai-stack/vms/coding/setup.sh
git mv data-vm/setup.sh       proxmox-ai-stack/vms/data/setup.sh
git mv automation-vm/setup.sh proxmox-ai-stack/vms/automation/setup.sh
git mv monitoring/setup.sh    proxmox-ai-stack/vms/monitoring/setup.sh
```

- [ ] **Step 3: Verify**

```bash
ls proxmox-ai-stack/vms/ai/ proxmox-ai-stack/vms/common/
ls proxmox-ai-stack/config.env
```

- [ ] **Step 4: Commit**

```bash
git add proxmox-ai-stack/
git commit -m "refactor(vms): move config, common, and VM setup scripts into vms/"
```

---

### Task 4: Move LXC scripts and docs

**Files:**
- Move: `deploy_lxc_stack.sh` → `proxmox-ai-stack/lxc/deploy-stack.sh`
- Move: `wire_lxc_to_vms.sh` → `proxmox-ai-stack/lxc/wire-to-vms.sh`
- Move: `lxc-stack.sh` → `proxmox-ai-stack/lxc/apps.sh`
- Move: `docs/lxc-integration.md` → `proxmox-ai-stack/docs/lxc-integration.md`
- Move: `docs/troubleshooting.md` → `proxmox-ai-stack/docs/troubleshooting.md`
- Move: `docs/superpowers/` → `proxmox-ai-stack/docs/superpowers/`

- [ ] **Step 1: Move LXC scripts**

```bash
git mv deploy_lxc_stack.sh    proxmox-ai-stack/lxc/deploy-stack.sh
git mv wire_lxc_to_vms.sh     proxmox-ai-stack/lxc/wire-to-vms.sh
git mv lxc-stack.sh           proxmox-ai-stack/lxc/apps.sh
```

- [ ] **Step 2: Move docs**

```bash
mkdir -p proxmox-ai-stack/docs
git mv docs/lxc-integration.md  proxmox-ai-stack/docs/lxc-integration.md
git mv docs/troubleshooting.md  proxmox-ai-stack/docs/troubleshooting.md
git mv docs/superpowers          proxmox-ai-stack/docs/superpowers
```

- [ ] **Step 3: Verify**

```bash
ls proxmox-ai-stack/lxc/
ls proxmox-ai-stack/docs/
```

Expected lxc/: `apps.sh  deploy-stack.sh  wire-to-vms.sh`
Expected docs/: `lxc-integration.md  superpowers  troubleshooting.md`

- [ ] **Step 4: Confirm git history is preserved on a moved file**

```bash
git log --follow --oneline proxmox-ai-stack/lxc/apps.sh | head -3
```

Expected: shows original commit(s) from before the rename.

- [ ] **Step 5: Commit**

```bash
git add proxmox-ai-stack/
git commit -m "refactor(lxc): move LXC scripts into lxc/ and docs into proxmox-ai-stack/docs/"
```

---

## Chunk 2: Fix internal path references

### Task 5: Fix config.env sourcing in host scripts

Host scripts use two different patterns for sourcing config.env. After moving into `host/`, config.env is one level up — both patterns need updating.

**Pattern A** (most scripts): `source "$(dirname "$0")/config.env"`
→ Change to: `source "$(dirname "$0")/../config.env"`

**Pattern B** (`init-secrets.sh` only): `CONFIG="$(cd "$(dirname "$0")" && pwd)/config.env"`
→ Change to: `CONFIG="$(cd "$(dirname "$0")" && pwd)/../config.env"`

Note: `setup-gpu.sh` (`00_gpu_passthrough.sh`) does not source config.env at all — skip it.

**Files:**
- Modify: `proxmox-ai-stack/host/create-vms.sh`
- Modify: `proxmox-ai-stack/host/create-template.sh`
- Modify: `proxmox-ai-stack/host/deploy-all.sh`
- Modify: `proxmox-ai-stack/host/deploy-vm.sh`
- Modify: `proxmox-ai-stack/host/export-env.sh`
- Modify: `proxmox-ai-stack/host/init-secrets.sh` (Pattern B — different sed)

- [ ] **Step 1: Update Pattern A scripts (5 files)**

```bash
sed -i 's|source "$(dirname "$0")/config.env"|source "$(dirname "$0")/../config.env"|g' \
  proxmox-ai-stack/host/create-vms.sh \
  proxmox-ai-stack/host/create-template.sh \
  proxmox-ai-stack/host/deploy-all.sh \
  proxmox-ai-stack/host/deploy-vm.sh \
  proxmox-ai-stack/host/export-env.sh
```

- [ ] **Step 2: Update Pattern B in init-secrets.sh**

```bash
sed -i 's|CONFIG="$(cd "$(dirname "$0")" && pwd)/config.env"|CONFIG="$(cd "$(dirname "$0")" && pwd)/../config.env"|g' \
  proxmox-ai-stack/host/init-secrets.sh
```

- [ ] **Step 3: Verify Pattern A changes**

```bash
grep -n 'source.*config\.env' \
  proxmox-ai-stack/host/create-vms.sh \
  proxmox-ai-stack/host/create-template.sh \
  proxmox-ai-stack/host/deploy-all.sh \
  proxmox-ai-stack/host/deploy-vm.sh \
  proxmox-ai-stack/host/export-env.sh
```

Expected: every line shows `/../config.env`.

- [ ] **Step 4: Verify Pattern B change in init-secrets.sh**

```bash
grep -n 'CONFIG=' proxmox-ai-stack/host/init-secrets.sh
```

Expected: `CONFIG="$(cd "$(dirname "$0")" && pwd)/../config.env"`

- [ ] **Step 5: Syntax-check all host scripts**

```bash
bash -n proxmox-ai-stack/host/setup-gpu.sh
bash -n proxmox-ai-stack/host/create-vms.sh
bash -n proxmox-ai-stack/host/create-template.sh
bash -n proxmox-ai-stack/host/init-secrets.sh
bash -n proxmox-ai-stack/host/deploy-all.sh
bash -n proxmox-ai-stack/host/deploy-vm.sh
bash -n proxmox-ai-stack/host/export-env.sh
```

Expected: no output (silent = pass).

- [ ] **Step 6: Commit**

```bash
git add proxmox-ai-stack/host/
git commit -m "fix(host): update config.env source paths for new host/ depth"
```

---

### Task 5b: Fix deploy-all.sh internal deploy_vm function

`deploy-all.sh` has its own internal `deploy_vm()` function (separate from `deploy-vm.sh`) that SCP-copies the VM subdir to the remote. It uses hardcoded old subdir names (`"ai-vm"`, `"coding-vm"`, etc.) and the old `${SCRIPT_DIR}/${subdir}/` path. Both must be updated.

**Files:**
- Modify: `proxmox-ai-stack/host/deploy-all.sh`

- [ ] **Step 1: Read the internal deploy_vm function and call sites**

```bash
grep -n 'deploy_vm\|SUBDIR\|scp\|subdir' proxmox-ai-stack/host/deploy-all.sh
```

Note the exact lines for the SCP command and the 5 call sites.

- [ ] **Step 2: Update the scp inside the internal deploy_vm function**

Find the line:
```bash
scp $SSH_OPTS -r "${SCRIPT_DIR}/${subdir}/" "${VM_USER}@${host}:/home/${VM_USER}/"
```

Change to:
```bash
scp $SSH_OPTS -r "${SCRIPT_DIR}/../vms/${subdir}/" "${VM_USER}@${host}:/home/${VM_USER}/"
```

Also add a common/ copy immediately after (this was missing in the original — `deploy_all.sh` did not copy common/, but `deploy_vm.sh` did; standardize to always copy common/):

```bash
scp $SSH_OPTS -r "${SCRIPT_DIR}/../vms/common/" "${VM_USER}@${host}:/home/${VM_USER}/"
```

- [ ] **Step 3: Update the 5 call sites with new subdir names**

Find lines like:
```bash
deploy_vm "data"       "$DATA_VM_IP"       "data-vm"
deploy_vm "ai"         "$AI_VM_IP"         "ai-vm"
deploy_vm "automation" "$AUTOMATION_VM_IP" "automation-vm"
deploy_vm "monitoring" "$MONITORING_VM_IP" "monitoring"
deploy_vm "coding"     "$CODING_VM_IP"     "coding-vm"
```

Change to:
```bash
deploy_vm "data"       "$DATA_VM_IP"       "data"
deploy_vm "ai"         "$AI_VM_IP"         "ai"
deploy_vm "automation" "$AUTOMATION_VM_IP" "automation"
deploy_vm "monitoring" "$MONITORING_VM_IP" "monitoring"
deploy_vm "coding"     "$CODING_VM_IP"     "coding"
```

- [ ] **Step 4: Verify no old subdir names remain**

```bash
grep -n 'ai-vm\|coding-vm\|data-vm\|automation-vm' proxmox-ai-stack/host/deploy-all.sh
```

Expected: no output.

- [ ] **Step 5: Syntax-check**

```bash
bash -n proxmox-ai-stack/host/deploy-all.sh
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add proxmox-ai-stack/host/deploy-all.sh
git commit -m "fix(deploy-all): update internal deploy_vm subdir names and scp paths for vms/ layout"
```

---

### Task 6: Fix deploy-vm.sh — SUBDIR values and copy paths

`deploy-vm.sh` has two things to update:
1. The `SUBDIR` values in the `resolve_vm` function — change from old folder names (`ai-vm`, `coding-vm`, etc.) to new relative paths from `host/` to the VM dirs.
2. The `scp` copy of `common/` — change from `${SCRIPT_DIR}/common/` to `${SCRIPT_DIR}/../vms/common/`.
3. The `scp` copy of the VM subdir — change from `${SCRIPT_DIR}/${subdir}/` to `${SCRIPT_DIR}/../vms/${subdir}/` (since SUBDIR will now be just the role name: `ai`, `coding`, `data`, `automation`, `monitoring`).

**Files:**
- Modify: `proxmox-ai-stack/host/deploy-vm.sh`

- [ ] **Step 1: Read the current SUBDIR assignments and scp lines**

```bash
grep -n 'SUBDIR\|scp.*common\|scp.*subdir\|SCRIPT_DIR.*subdir' proxmox-ai-stack/host/deploy-vm.sh
```

Note the exact line numbers before editing.

- [ ] **Step 2: Update SUBDIR values to role-only names**

In the `resolve_vm` function, update the 5 SUBDIR assignments:

```
Old:  SUBDIR="ai-vm"
New:  SUBDIR="ai"

Old:  SUBDIR="data-vm"
New:  SUBDIR="data"

Old:  SUBDIR="automation-vm"
New:  SUBDIR="automation"

Old:  SUBDIR="monitoring"
New:  SUBDIR="monitoring"   ← no change needed

Old:  SUBDIR="coding-vm"
New:  SUBDIR="coding"
```

Use the Edit tool to update each line individually. Example for ai:
- Old: `ai)         VM_IP="$AI_VM_IP";         SUBDIR="ai-vm"         ;;`
- New: `ai)         VM_IP="$AI_VM_IP";         SUBDIR="ai"            ;;`

- [ ] **Step 3: Update VM subdir scp to use vms/ prefix**

Find the scp line that copies the VM-specific subdir. It currently reads something like:
```bash
scp $SSH_OPTS -r "${SCRIPT_DIR}/${subdir}/" "${VM_USER}@${host}:/home/${VM_USER}/"
```

Change to:
```bash
scp $SSH_OPTS -r "${SCRIPT_DIR}/../vms/${subdir}/" "${VM_USER}@${host}:/home/${VM_USER}/"
```

- [ ] **Step 4: Update common scp to use vms/common**

Find the line that copies `common/`:
```bash
scp $SSH_OPTS -r "${SCRIPT_DIR}/common/" "${VM_USER}@${host}:/home/${VM_USER}/"
```

Change to:
```bash
scp $SSH_OPTS -r "${SCRIPT_DIR}/../vms/common/" "${VM_USER}@${host}:/home/${VM_USER}/"
```

- [ ] **Step 5: Syntax-check**

```bash
bash -n proxmox-ai-stack/host/deploy-vm.sh
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add proxmox-ai-stack/host/deploy-vm.sh
git commit -m "fix(deploy-vm): update SUBDIR names and scp paths for new vms/ layout"
```

---

### Task 7: Fix lxc/ scripts — config.env paths and apps.sh reference

Both `deploy-stack.sh` and `wire-to-vms.sh` source `config.env` from their own directory. After moving to `lxc/`, config.env is one level up. `deploy-stack.sh` also references `lxc-stack.sh` — update to `apps.sh`.

**Files:**
- Modify: `proxmox-ai-stack/lxc/deploy-stack.sh`
- Modify: `proxmox-ai-stack/lxc/wire-to-vms.sh`

- [ ] **Step 1: Read how each lxc script sources config.env**

```bash
grep -n 'config\.env\|SCRIPT_DIR\|dirname' proxmox-ai-stack/lxc/deploy-stack.sh | head -10
grep -n 'config\.env\|SCRIPT_DIR\|dirname' proxmox-ai-stack/lxc/wire-to-vms.sh | head -10
```

Note the exact pattern used in each file (may differ).

- [ ] **Step 2: Update config.env path in deploy-stack.sh**

`deploy-stack.sh` uses a two-variable pattern: `CONFIG="${SCRIPT_DIR}/config.env"` (not a direct `source` call). Use this sed:

```bash
sed -i 's|CONFIG="${SCRIPT_DIR}/config.env"|CONFIG="${SCRIPT_DIR}/../config.env"|g' \
  proxmox-ai-stack/lxc/deploy-stack.sh
```

Then verify:

```bash
grep -n 'CONFIG=' proxmox-ai-stack/lxc/deploy-stack.sh
```

Expected: `CONFIG="${SCRIPT_DIR}/../config.env"`

- [ ] **Step 3: Update config.env path in wire-to-vms.sh**

`wire-to-vms.sh` uses `source "${SCRIPT_DIR}/config.env"`.
Change to: `source "${SCRIPT_DIR}/../config.env"`

- [ ] **Step 4: Update lxc-stack.sh reference to apps.sh in deploy-stack.sh**

Find: `LXC_SCRIPT="${SCRIPT_DIR}/lxc-stack.sh"`
Change to: `LXC_SCRIPT="${SCRIPT_DIR}/apps.sh"`

- [ ] **Step 5: Verify all changes in both files**

```bash
grep -n 'config\.env\|LXC_SCRIPT\|lxc-stack\|apps\.sh' \
  proxmox-ai-stack/lxc/deploy-stack.sh \
  proxmox-ai-stack/lxc/wire-to-vms.sh
```

Expected:
- `config.env` lines in both files show `/../config.env` or `/../config.env`
- `LXC_SCRIPT` line shows `apps.sh`, not `lxc-stack.sh`

- [ ] **Step 6: Check for any remaining `lxc-stack.sh` references**

```bash
grep -rn 'lxc-stack\.sh' proxmox-ai-stack/lxc/
```

Expected: no output.

- [ ] **Step 7: Syntax-check all lxc scripts**

```bash
bash -n proxmox-ai-stack/lxc/deploy-stack.sh
bash -n proxmox-ai-stack/lxc/apps.sh
bash -n proxmox-ai-stack/lxc/wire-to-vms.sh
```

Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add proxmox-ai-stack/lxc/
git commit -m "fix(lxc): update config.env paths and rename lxc-stack.sh ref to apps.sh"
```

---

### Task 8: Fix bootstrap sourcing in VM setup scripts

Each VM setup script currently sources `../common/bootstrap.sh`. After the restructure, `vms/<role>/setup.sh` is still exactly one level away from `vms/common/bootstrap.sh`, so the path `../common/bootstrap.sh` is still correct. This task is to verify — no edit should be needed.

**Files:**
- Read: all 5 `proxmox-ai-stack/vms/*/setup.sh`

- [ ] **Step 1: Verify bootstrap source path in all VM setup scripts**

```bash
grep -n 'bootstrap' \
  proxmox-ai-stack/vms/ai/setup.sh \
  proxmox-ai-stack/vms/coding/setup.sh \
  proxmox-ai-stack/vms/data/setup.sh \
  proxmox-ai-stack/vms/automation/setup.sh \
  proxmox-ai-stack/vms/monitoring/setup.sh
```

Expected: all lines show `../common/bootstrap.sh` — no changes needed.

- [ ] **Step 2: Syntax-check all VM setup scripts (except ai which gets rewritten)**

```bash
bash -n proxmox-ai-stack/vms/coding/setup.sh
bash -n proxmox-ai-stack/vms/data/setup.sh
bash -n proxmox-ai-stack/vms/automation/setup.sh
bash -n proxmox-ai-stack/vms/monitoring/setup.sh
```

Expected: no output.

---

## Chunk 3: Split ai/setup.sh into 4 files

### Task 9: Extract install-nvidia.sh

The NVIDIA-related functions in `vms/ai/setup.sh` are `install_nvidia_driver` and `install_nvidia_container_toolkit`. Extract them into a new `install-nvidia.sh` file.

**Files:**
- Read: `proxmox-ai-stack/vms/ai/setup.sh` (to find exact line ranges)
- Create: `proxmox-ai-stack/vms/ai/install-nvidia.sh`

- [ ] **Step 1: Find the line numbers of the NVIDIA functions**

```bash
grep -n 'install_nvidia_driver\|install_nvidia_container_toolkit' proxmox-ai-stack/vms/ai/setup.sh
```

Note the line numbers where each function is defined (starts with the function signature) and ends (closing `}`).

- [ ] **Step 2: Create install-nvidia.sh with the extracted functions**

Create `proxmox-ai-stack/vms/ai/install-nvidia.sh` with this structure:

```bash
#!/usr/bin/env bash
# install-nvidia.sh — NVIDIA driver and container toolkit installation
# Source-only: sourced by vms/ai/setup.sh. Do not run directly.
# All config variables are pre-exported by deploy-vm.sh via ENV_BLOCK.
set -euo pipefail
```

Then append the exact text of `install_nvidia_driver()` and `install_nvidia_container_toolkit()` from `setup.sh` (copy verbatim, do not modify the function bodies).

- [ ] **Step 3: Syntax-check the new file**

```bash
bash -n proxmox-ai-stack/vms/ai/install-nvidia.sh
```

Expected: no output.

- [ ] **Step 4: git add the new file**

```bash
git add proxmox-ai-stack/vms/ai/install-nvidia.sh
```

---

### Task 10: Extract install-docker.sh

The Docker installation function in `vms/ai/setup.sh` is `install_docker`. Extract it.

**Files:**
- Read: `proxmox-ai-stack/vms/ai/setup.sh` (to find exact line range)
- Create: `proxmox-ai-stack/vms/ai/install-docker.sh`

- [ ] **Step 1: Find the line numbers of install_docker**

```bash
grep -n 'install_docker\b' proxmox-ai-stack/vms/ai/setup.sh
```

- [ ] **Step 2: Create install-docker.sh with the extracted function**

```bash
#!/usr/bin/env bash
# install-docker.sh — Docker CE and Compose plugin installation
# Source-only: sourced by vms/ai/setup.sh. Do not run directly.
# All config variables are pre-exported by deploy-vm.sh via ENV_BLOCK.
set -euo pipefail
```

Then append the exact text of `install_docker()` from `setup.sh` (copy verbatim).

- [ ] **Step 3: Syntax-check**

```bash
bash -n proxmox-ai-stack/vms/ai/install-docker.sh
```

Expected: no output.

- [ ] **Step 4: git add**

```bash
git add proxmox-ai-stack/vms/ai/install-docker.sh
```

---

### Task 11: Extract generate-compose.sh

The Docker Compose generation function in `vms/ai/setup.sh` is `write_docker_compose`. Extract it.

**Files:**
- Read: `proxmox-ai-stack/vms/ai/setup.sh` (find exact line range)
- Create: `proxmox-ai-stack/vms/ai/generate-compose.sh`

- [ ] **Step 1: Find the line numbers of write_docker_compose**

```bash
grep -n 'write_docker_compose' proxmox-ai-stack/vms/ai/setup.sh
```

- [ ] **Step 2: Create generate-compose.sh with the extracted function**

```bash
#!/usr/bin/env bash
# generate-compose.sh — Generates /opt/ai-stack/docker-compose.yml with all 15 services
# Source-only: sourced by vms/ai/setup.sh. Do not run directly.
# All config variables are pre-exported by deploy-vm.sh via ENV_BLOCK.
set -euo pipefail
```

Then append the exact text of `write_docker_compose()` from `setup.sh` (copy verbatim — this is ~900 lines of heredoc content defining all 15 service blocks).

- [ ] **Step 3: Syntax-check**

```bash
bash -n proxmox-ai-stack/vms/ai/generate-compose.sh
```

Expected: no output.

- [ ] **Step 4: git add**

```bash
git add proxmox-ai-stack/vms/ai/generate-compose.sh
```

---

### Task 12: Rewrite ai/setup.sh as the thin orchestrator

Now replace the body of `vms/ai/setup.sh` with the ~40-line orchestrator. It must: keep the existing header comment block (services table + architecture diagram), source bootstrap and the 3 new files, call the install functions in the original order, and start the stack.

**Files:**
- Modify: `proxmox-ai-stack/vms/ai/setup.sh`

- [ ] **Step 1: Read the current main execution block at the bottom of setup.sh**

```bash
tail -60 proxmox-ai-stack/vms/ai/setup.sh
```

Note the exact function call order (e.g., `install_nvidia_driver`, `install_nvidia_container_toolkit`, `install_docker`, `write_docker_compose`, then `docker compose up -d`).

- [ ] **Step 2: Read the top header comment block (keep it)**

```bash
head -170 proxmox-ai-stack/vms/ai/setup.sh
```

This header (services table + architecture diagram + installation order) is valuable documentation — keep it intact in the orchestrator.

- [ ] **Step 3: Replace the entire contents of setup.sh with the orchestrator**

**Write the file from scratch** — do not edit in-place, as 1300 lines of function bodies must be removed. Use the Write tool to completely overwrite the file. The new content should be:

The new `proxmox-ai-stack/vms/ai/setup.sh` should be:

```bash
#!/usr/bin/env bash
# =============================================================================
#  vms/ai/setup.sh — AI VM Orchestrator
#
# [keep existing header comment block verbatim — services table, architecture
#  diagram, tool server types, installation order sections]
#
#  This script is the entry point. It sources the 3 focused installers below
#  and calls their functions in the correct order.
#
#  Source files (not standalone):
#    install-nvidia.sh   — NVIDIA driver + container toolkit
#    install-docker.sh   — Docker CE + Compose plugin
#    generate-compose.sh — writes /opt/ai-stack/docker-compose.yml
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Logging helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Bootstrap (system hygiene: NTP, journald, TRIM, admin tools) ─────────────
source "${SCRIPT_DIR}/../common/bootstrap.sh"

# ── Load installers ──────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/install-nvidia.sh"
source "${SCRIPT_DIR}/install-docker.sh"
source "${SCRIPT_DIR}/generate-compose.sh"

# ── Run installation in order ────────────────────────────────────────────────
install_nvidia_driver
install_nvidia_container_toolkit
install_docker
write_docker_compose

# ── Start the stack ──────────────────────────────────────────────────────────
section "Starting AI stack"
cd /opt/ai-stack
docker compose up -d
docker compose ps
info "AI VM setup complete ✓"
```

**Important:** Copy the exact header comment block from the original file (lines 1–~170) verbatim before the `set -euo pipefail` line. Keep the full services table and architecture diagram.

- [ ] **Step 4: Syntax-check**

```bash
bash -n proxmox-ai-stack/vms/ai/setup.sh
```

Expected: no output.

- [ ] **Step 5: Verify all 4 ai/ files exist**

```bash
ls proxmox-ai-stack/vms/ai/
```

Expected: `generate-compose.sh  install-docker.sh  install-nvidia.sh  setup.sh`

- [ ] **Step 6: Commit the ai/ split**

```bash
git add proxmox-ai-stack/vms/ai/
git commit -m "refactor(ai): split 1341-line setup.sh into orchestrator + 3 focused files"
```

---

## Chunk 4: Write documentation

### Task 13: Create proxmox-ai-stack/README.md

A new stack-level README giving contributors the deployment quick-start, VM table, and navigation guide.

**Files:**
- Create: `proxmox-ai-stack/README.md`

- [ ] **Step 1: Create proxmox-ai-stack/README.md**

```markdown
# Proxmox AI Stack

Self-hosted AI stack deployed across 5 Ubuntu VMs on Proxmox VE. GPU-accelerated LLM inference, a full document/code AI toolset, automation workflows, and observability — all running on your own hardware.

## VM Architecture

| VM | IP (default) | Role | Key Services |
|----|-------------|------|-------------|
| ai | 10.0.3.10 | AI inference & tooling | Ollama, Open WebUI, AnythingLLM, Qdrant, Whisper, MCPO |
| coding | 10.0.3.20 | IDE integration | OpenCode / Continue |
| data | 10.0.3.30 | Database | Postgres 16 + pgvector, pgAdmin |
| automation | 10.0.3.40 | Workflow automation | n8n, Flowise |
| monitoring | 10.0.3.50 | Observability | Grafana, Prometheus, Alertmanager |

## Layout

```
proxmox-ai-stack/
├── config.env          ← edit this first (IPs, SSH key, storage)
├── host/               ← run these ON the Proxmox host (as root)
├── vms/                ← deployed TO each VM via SSH
│   ├── common/         ← shared bootstrap (runs on every VM)
│   ├── ai/             ← AI VM: Ollama, Open WebUI, 15 services
│   ├── coding/         ← Coding VM: OpenCode + Continue IDE
│   ├── data/           ← Data VM: Postgres + pgAdmin
│   ├── automation/     ← Automation VM: n8n + Flowise
│   └── monitoring/     ← Monitoring VM: Grafana + Prometheus
└── lxc/                ← optional: 60+ extra LXC containers
```

## Quick Start

### 1. Configure

```bash
nano proxmox-ai-stack/config.env       # set SSH key, IPs, storage, bridge
bash proxmox-ai-stack/host/init-secrets.sh   # generate passwords once
```

### 2. GPU passthrough (run on Proxmox host, then reboot)

```bash
bash proxmox-ai-stack/host/setup-gpu.sh
reboot
```

### 3. Create VMs

```bash
# Direct import (default)
bash proxmox-ai-stack/host/create-vms.sh

# Template-based (faster for rebuilds)
bash proxmox-ai-stack/host/create-template.sh
USE_TEMPLATE=1 bash proxmox-ai-stack/host/create-vms.sh
```

### 4. Deploy all services

```bash
bash proxmox-ai-stack/host/deploy-all.sh
```

Or deploy a single VM:

```bash
bash proxmox-ai-stack/host/deploy-vm.sh ai
bash proxmox-ai-stack/host/deploy-vm.sh ai --dry-run    # preview
bash proxmox-ai-stack/host/deploy-vm.sh data --no-wait  # skip SSH wait
```

### 5. Optional: LXC services (60+ apps)

```bash
bash proxmox-ai-stack/lxc/deploy-stack.sh           # interactive menu
bash proxmox-ai-stack/lxc/deploy-stack.sh --all     # deploy everything
bash proxmox-ai-stack/lxc/deploy-stack.sh --phase 4 # one phase
```

## Configuration helper

To source config variables into your current shell for manual operations:

```bash
source proxmox-ai-stack/host/export-env.sh
```

## Managing the AI stack

```bash
ssh ubuntu@10.0.3.10
cd /opt/ai-stack
docker compose ps
docker compose pull && docker compose up -d   # update all images
docker exec ollama ollama pull <model>
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) and [docs/lxc-integration.md](docs/lxc-integration.md).
```

- [ ] **Step 2: git add and commit**

```bash
git add proxmox-ai-stack/README.md
git commit -m "docs(stack): add proxmox-ai-stack/README.md with quick-start and layout guide"
```

---

### Task 14: Update repo root README.md

The root README should be a brief repo overview pointing contributors to the stack subdirectory.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current root README.md**

Read the full file to understand current content.

- [ ] **Step 2: Update to reflect new structure**

Replace or update the deployment sequence section to point to `proxmox-ai-stack/`. Keep any intro text. The key change is that all script paths now start with `proxmox-ai-stack/host/` or `proxmox-ai-stack/lxc/`.

Add a "Repository layout" section near the top:

```markdown
## Repository Layout

This repo is structured to support multiple stacks:

```
/
└── proxmox-ai-stack/   ← Proxmox VE + 5 Ubuntu VMs + optional LXC layer
```

See [proxmox-ai-stack/README.md](proxmox-ai-stack/README.md) for the full quick-start guide.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(root): update README to reflect new proxmox-ai-stack/ layout"
```

---

### Task 15: Update CLAUDE.md

CLAUDE.md documents the project for Claude Code. All paths and deployment commands need updating to match the new structure.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Read current CLAUDE.md**

Read the full file — focus on the "Project Structure" tree, "Deployment Sequence", "Key Design Patterns", and "Shell Coding Standards" sections.

- [ ] **Step 2: Update Project Structure tree**

Replace the current tree with the new `proxmox-ai-stack/` layout. Mirror the folder structure shown in the spec.

- [ ] **Step 3: Update Deployment Sequence commands**

Replace all script paths:
- `bash vm-lxc-stack/init_secrets.sh` → `bash proxmox-ai-stack/host/init-secrets.sh`
- `bash 00_gpu_passthrough.sh` → `bash proxmox-ai-stack/host/setup-gpu.sh`
- `bash 01_create_vms.sh` → `bash proxmox-ai-stack/host/create-vms.sh`
- `bash create_template.sh` → `bash proxmox-ai-stack/host/create-template.sh`
- `USE_TEMPLATE=1 bash 01_create_vms.sh` → `USE_TEMPLATE=1 bash proxmox-ai-stack/host/create-vms.sh`
- `bash deploy_all.sh` → `bash proxmox-ai-stack/host/deploy-all.sh`
- `bash deploy_vm.sh ai` → `bash proxmox-ai-stack/host/deploy-vm.sh ai`
- `bash deploy_lxc_stack.sh` → `bash proxmox-ai-stack/lxc/deploy-stack.sh`

- [ ] **Step 4: Update "Extending the Stack" section**

Update paths referenced in the extension guides (adding a new VM role, adding a new LXC app).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): update CLAUDE.md paths and commands for new layout"
```

---

## Chunk 5: Final verification

### Task 16: Run all verification checks

- [ ] **Step 1: Syntax-check every script**

```bash
bash -n proxmox-ai-stack/host/setup-gpu.sh
bash -n proxmox-ai-stack/host/create-vms.sh
bash -n proxmox-ai-stack/host/create-template.sh
bash -n proxmox-ai-stack/host/init-secrets.sh
bash -n proxmox-ai-stack/host/deploy-all.sh
bash -n proxmox-ai-stack/host/deploy-vm.sh
bash -n proxmox-ai-stack/host/export-env.sh
bash -n proxmox-ai-stack/vms/common/bootstrap.sh
bash -n proxmox-ai-stack/vms/ai/setup.sh
bash -n proxmox-ai-stack/vms/ai/install-nvidia.sh
bash -n proxmox-ai-stack/vms/ai/install-docker.sh
bash -n proxmox-ai-stack/vms/ai/generate-compose.sh
bash -n proxmox-ai-stack/vms/coding/setup.sh
bash -n proxmox-ai-stack/vms/data/setup.sh
bash -n proxmox-ai-stack/vms/automation/setup.sh
bash -n proxmox-ai-stack/vms/monitoring/setup.sh
bash -n proxmox-ai-stack/lxc/deploy-stack.sh
bash -n proxmox-ai-stack/lxc/wire-to-vms.sh
bash -n proxmox-ai-stack/lxc/apps.sh
```

Expected: no output from any command.

- [ ] **Step 2: Verify git history is preserved**

```bash
git log --follow --oneline proxmox-ai-stack/host/deploy-vm.sh | head -5
git log --follow --oneline proxmox-ai-stack/lxc/apps.sh | head -5
git log --follow --oneline proxmox-ai-stack/vms/ai/setup.sh | head -5
```

Expected: each command shows at least one commit from before the restructure.

- [ ] **Step 3: Verify no old subdir/script names remain anywhere**

```bash
# Should find nothing — all old folder references should be gone
grep -rn 'ai-vm\|coding-vm\|data-vm\|automation-vm\|lxc-stack\.sh' \
  proxmox-ai-stack/host/ proxmox-ai-stack/lxc/
```

Expected: no output.

- [ ] **Step 4: Verify config.env paths are correct in host/ scripts**

```bash
# Pattern A scripts: should show /../config.env
grep -n 'source.*config\.env' proxmox-ai-stack/host/*.sh
```

Expected: every `source` line contains `/../config.env`.

```bash
# Pattern B (init-secrets.sh): should show /../config.env in CONFIG=
grep -n 'CONFIG=' proxmox-ai-stack/host/init-secrets.sh
```

Expected: `CONFIG="$(cd "$(dirname "$0")" && pwd)/../config.env"`

- [ ] **Step 4b: Verify config.env paths are correct in lxc/ scripts**

```bash
grep -n 'config\.env' proxmox-ai-stack/lxc/deploy-stack.sh proxmox-ai-stack/lxc/wire-to-vms.sh
```

Expected: all lines show `/../config.env`.

- [ ] **Step 5: Verify the repo root is clean**

```bash
ls *.sh 2>/dev/null || echo "No .sh files at repo root — correct"
ls config.env 2>/dev/null || echo "No config.env at repo root — correct"
```

Expected: both print "correct".

- [ ] **Step 6: Final commit with summary**

```bash
git add -A
git status
```

If git status is clean (no untracked or modified files), all changes are committed. If there are any remaining changes, commit them:

```bash
git commit -m "chore: final cleanup — complete codebase restructure to proxmox-ai-stack/ layout"
```

---

### Task 17: Verify the 4 ai/ files are internally consistent

- [ ] **Step 1: Confirm install-nvidia.sh contains both NVIDIA functions**

```bash
grep -n 'install_nvidia_driver\|install_nvidia_container_toolkit' \
  proxmox-ai-stack/vms/ai/install-nvidia.sh
```

Expected: both function definitions present.

- [ ] **Step 2: Confirm install-docker.sh contains the Docker function**

```bash
grep -n 'install_docker' proxmox-ai-stack/vms/ai/install-docker.sh
```

Expected: function definition present.

- [ ] **Step 3: Confirm generate-compose.sh contains write_docker_compose**

```bash
grep -n 'write_docker_compose' proxmox-ai-stack/vms/ai/generate-compose.sh
```

Expected: function definition present.

- [ ] **Step 4: Confirm setup.sh calls all 4 functions and sources all 3 files**

```bash
grep -n 'source\|install_nvidia\|install_docker\|write_docker_compose\|docker compose' \
  proxmox-ai-stack/vms/ai/setup.sh
```

Expected: lines for `source install-nvidia.sh`, `source install-docker.sh`, `source generate-compose.sh`, and calls to each function + `docker compose up -d`.

- [ ] **Step 5: Confirm no NVIDIA/Docker/Compose functions remain in setup.sh body**

```bash
grep -n 'function install_nvidia\|function install_docker\|function write_docker' \
  proxmox-ai-stack/vms/ai/setup.sh
```

Expected: no output (functions are in split files, not in setup.sh).
