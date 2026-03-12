#!/usr/bin/env bash
# =============================================================================
#  create_template.sh — Ubuntu Cloud-Init Template Builder
#
#  Downloads the Ubuntu cloud image and freezes it as a reusable Proxmox VM
#  template. Run this ONCE before using  USE_TEMPLATE=1 bash 01_create_vms.sh
#  to clone VMs from the template rather than re-importing the cloud image
#  for each VM.
#
#  WHAT IT DOES
#  ────────────
#  1. Downloads the Ubuntu cloud image (if not already present)
#  2. Validates the image with qemu-img
#  3. Creates a minimal VM (VMID = TEMPLATE_VMID from config.env)
#  4. Imports the cloud image as a virtio-scsi disk
#  5. Attaches a cloud-init drive and injects the SSH key
#  6. Calls  qm template  to freeze the VM as a Proxmox template
#
#  IDEMPOTENT
#  ──────────
#  If TEMPLATE_VMID already exists, the script prints a message and exits
#  without modifying anything. Delete the template manually to rebuild:
#    qm destroy <TEMPLATE_VMID>
#
#  REQUIREMENTS
#  ────────────
#  - Run as root on the Proxmox HOST
#  - config.env must be populated (run init_secrets.sh first)
#  - qm, pvesm, wget, qemu-img must be available
#
#  USAGE
#  ─────
#  # Step 1 — build the template (once)
#    bash create_template.sh
#
#  # Step 2 — clone VMs from template (faster than direct image import)
#    USE_TEMPLATE=1 bash 01_create_vms.sh
#
#  # Default workflow (no template) — still works unchanged
#    bash 01_create_vms.sh
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

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

[[ $EUID -ne 0 ]] && error "Run as root on the Proxmox host"

# ---------------------------------------------------------------------------
#  Dependency checks
# ---------------------------------------------------------------------------
for cmd in qm pvesm wget qemu-img; do
    command -v "$cmd" &>/dev/null || error "Missing required command: $cmd"
done

if ! pvesm status | awk '{print $1}' | grep -qx "$STORAGE"; then
    error "Storage '${STORAGE}' not found. Check: pvesm status"
fi

# ---------------------------------------------------------------------------
#  Idempotency guard
# ---------------------------------------------------------------------------
section "Template Check (VMID ${TEMPLATE_VMID})"

if qm status "$TEMPLATE_VMID" &>/dev/null; then
    info "VMID ${TEMPLATE_VMID} already exists."
    # Check whether it is already a template
    if qm config "$TEMPLATE_VMID" 2>/dev/null | grep -q "^template:"; then
        info "Template ${TEMPLATE_VMID} is already built ✓"
        info "To rebuild: qm destroy ${TEMPLATE_VMID} && bash create_template.sh"
    else
        warn "VMID ${TEMPLATE_VMID} exists but is NOT a template (may be a running VM)."
        warn "Choose a different TEMPLATE_VMID in config.env or destroy the VM first."
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
#  Download cloud image
# ---------------------------------------------------------------------------
section "Cloud Image"

mkdir -p "$(dirname "$CLOUD_IMAGE_PATH")"

if [[ -f "$CLOUD_IMAGE_PATH" ]]; then
    info "Cloud image already present: ${CLOUD_IMAGE_PATH}"
else
    info "Downloading ${CLOUD_IMAGE_NAME}..."
    wget -q --show-progress -O "$CLOUD_IMAGE_PATH" "$CLOUD_IMAGE_URL"
    info "Download complete ✓"
fi

# Validate image is readable and has a non-zero virtual size
step "Validating image..."
if ! qemu-img info "$CLOUD_IMAGE_PATH" &>/dev/null; then
    error "Image unreadable by qemu-img: ${CLOUD_IMAGE_PATH}. Delete and re-run."
fi

VIRT_SIZE=$(qemu-img info --output=json "$CLOUD_IMAGE_PATH" \
    | awk -F: '/\"virtual-size\"/{gsub(/[^0-9]/,"",$2); print $2; exit 0}')

if [[ -z "$VIRT_SIZE" || "$VIRT_SIZE" == "0" ]]; then
    error "Image virtual size is 0 — file is corrupt. Delete ${CLOUD_IMAGE_PATH} and re-run."
fi
info "Image OK (virtual size: $((VIRT_SIZE / 1024 / 1024 / 1024)) GB) ✓"

# ---------------------------------------------------------------------------
#  Create template VM
# ---------------------------------------------------------------------------
section "Creating Template VM (VMID ${TEMPLATE_VMID})"

step "Creating VM skeleton..."
qm create "$TEMPLATE_VMID" \
    --name     "ubuntu-template" \
    --memory   2048 \
    --cores    2 \
    --cpu      host \
    --net0     virtio,bridge="${BRIDGE}" \
    --ostype   l26 \
    --bios     ovmf \
    --machine  q35 \
    --efidisk0 "${STORAGE}:0,efitype=4m" \
    --scsihw   virtio-scsi-pci \
    --serial0  socket \
    --vga      serial0 \
    --agent    enabled=1

# Import cloud image as disk
step "Importing cloud image disk..."
qm importdisk "$TEMPLATE_VMID" "$CLOUD_IMAGE_PATH" "$STORAGE" --format qcow2

# Attach the imported disk as scsi0
step "Attaching disk as scsi0..."
qm set "$TEMPLATE_VMID" \
    --scsi0 "${STORAGE}:vm-${TEMPLATE_VMID}-disk-1,discard=on,ssd=1"
qm set "$TEMPLATE_VMID" --boot order=scsi0

# Attach cloud-init drive (cloned VMs will receive their own IP/user config)
step "Attaching cloud-init drive..."
qm set "$TEMPLATE_VMID" --ide2 "${STORAGE}:cloudinit"

# Inject SSH key and default user into the template's cloud-init config.
# Clones inherit these and can override with qm set after cloning.
step "Configuring cloud-init user and SSH key..."
qm set "$TEMPLATE_VMID" \
    --ciuser  "$VM_USER" \
    --sshkeys <(echo "$SSH_PUBLIC_KEY")

# ---------------------------------------------------------------------------
#  Freeze as template
# ---------------------------------------------------------------------------
section "Converting to Template"
step "Running qm template ${TEMPLATE_VMID}..."
qm template "$TEMPLATE_VMID"
info "Template ${TEMPLATE_VMID} created ✓"

# ---------------------------------------------------------------------------
#  Summary
# ---------------------------------------------------------------------------
cat <<EOF

${GREEN}════════════════════════════════════════════════════════${NC}
  Template ready: VMID ${TEMPLATE_VMID} (ubuntu-template)
  Storage: ${STORAGE}
  Image:   ${CLOUD_IMAGE_NAME}

  Verify:
    qm list | grep ${TEMPLATE_VMID}     # should show (template)
    qm config ${TEMPLATE_VMID}         # inspect template config

  Next step — clone VMs from this template:
    USE_TEMPLATE=1 bash 01_create_vms.sh

  To rebuild the template:
    qm destroy ${TEMPLATE_VMID}
    bash create_template.sh
${GREEN}════════════════════════════════════════════════════════${NC}
EOF
