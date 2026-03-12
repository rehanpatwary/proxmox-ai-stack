#!/usr/bin/env bash
# =============================================================================
#  01_create_vms.sh — VM Provisioning
#
#  Creates all five QEMU VMs from an Ubuntu cloud image on the Proxmox host.
#  Uses cloud-init for network configuration, SSH key injection, and user setup.
#  The RTX 4090 is automatically detected and attached to ai-vm via PCIe
#  passthrough (requires 00_gpu_passthrough.sh to have run first).
#
#  WHAT IT DOES
#  ────────────
#  1. Downloads the Ubuntu cloud image if not already present
#  2. Creates five VMs (ai, coding, data, automation, monitoring)
#  3. Imports the cloud image as a virtio-scsi disk for each VM
#  4. Configures cloud-init with static IPs, SSH key, and user credentials
#  5. Attaches the GPU to ai-vm via hostpci passthrough
#  6. Starts all five VMs
#
#  REQUIREMENTS
#  ────────────
#  - Run as root on the Proxmox HOST
#  - 00_gpu_passthrough.sh must have run and host must have been rebooted
#  - config.env must be populated (run init_secrets.sh first)
#
#  IDEMPOTENT
#  ──────────
#  If a VM with the given VMID already exists, it is skipped with a warning.
#  Delete an existing VM manually before re-running to recreate it.
#
#  USAGE
#  ─────
#    bash 01_create_vms.sh
#    # Then wait ~60s for cloud-init, then: bash deploy_all.sh
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Must run as root on the Proxmox host"

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Download the Ubuntu cloud image if it does not already exist locally.
#
# Uses CLOUD_IMAGE_URL and CLOUD_IMAGE_PATH from config.env.
# Shows download progress via wget. The image is ~600 MB and is downloaded
# once; subsequent runs detect the existing file and skip the download.
#
# Side effects:
#   Creates CLOUD_IMAGE_PATH if it does not exist
##
download_cloud_image() {
    section "Cloud Image"
    if [[ -f "$CLOUD_IMAGE_PATH" ]]; then
        info "Cloud image already exists: $CLOUD_IMAGE_PATH"
        return 0
    fi

    info "Downloading ${CLOUD_IMAGE_NAME}..."
    wget -q --show-progress -O "$CLOUD_IMAGE_PATH" "$CLOUD_IMAGE_URL"
    info "Downloaded to $CLOUD_IMAGE_PATH ✓"
}

##
# Create a single VM from the Ubuntu cloud image with cloud-init networking.
#
# Creates the VM skeleton, imports the cloud image disk, attaches a cloud-init
# drive for first-boot configuration (IP, SSH key, user), and optionally
# appends extra qm arguments (used for GPU passthrough on ai-vm).
#
# The VM is configured with:
#   - OVMF (UEFI) firmware + EFI disk
#   - Q35 machine type (required for PCIe passthrough)
#   - virtio-scsi disk controller
#   - QEMU guest agent enabled (qemu-guest-agent installed via cloud-init)
#   - onboot=1 so it starts automatically after Proxmox reboots
#
# Idempotent: if the VMID already exists, prints a warning and returns
# without modifying anything.
#
# Arguments:
#   $1 - VM_ID      Proxmox VMID (integer)
#   $2 - VM_NAME    Display name (e.g. "ai-vm")
#   $3 - RAM        Memory in MB
#   $4 - CORES      Number of vCPU cores
#   $5 - DISK_SIZE  Root disk size in GB
#   $6 - IP         Static IP address (will be assigned /SUBNET_MASK)
#   $7 - EXTRA_ARGS (optional) Additional qm set arguments, e.g. GPU hostpci
#
# Side effects:
#   Creates a VM in Proxmox; imports and resizes disk; sets cloud-init config
##
create_vm() {
    local vm_id="$1"
    local vm_name="$2"
    local ram="$3"
    local cores="$4"
    local disk_size="$5"
    local ip="$6"
    local extra_args="${7:-}"

    section "Creating VM: $vm_name (ID: $vm_id)"

    # Idempotency guard: skip if VMID is already in use
    if qm status "$vm_id" &>/dev/null; then
        warn "VM $vm_id already exists — skipping (destroy manually to recreate)"
        return 0
    fi

    # Create the VM skeleton without any disk
    qm create "$vm_id" \
        --name     "$vm_name" \
        --memory   "$ram" \
        --cores    "$cores" \
        --cpu      host \
        --net0     virtio,bridge="$BRIDGE" \
        --ostype   l26 \
        --bios     ovmf \
        --machine  q35 \
        --efidisk0 "${STORAGE}:0,efitype=4m" \
        --scsihw   virtio-scsi-pci \
        --serial0  socket \
        --vga      serial0 \
        --agent    enabled=1 \
        --onboot   1

    # Import the cloud image as a QCOW2 disk attached to the SCSI controller
    qm importdisk "$vm_id" "$CLOUD_IMAGE_PATH" "$STORAGE" --format qcow2
    qm set "$vm_id" \
        --scsi0 "${STORAGE}:vm-${vm_id}-disk-1,size=${disk_size}G,discard=on,ssd=1"
    qm set "$vm_id" --boot order=scsi0
    qm resize "$vm_id" scsi0 "${disk_size}G"

    # Attach the cloud-init drive (provides network/user config on first boot)
    qm set "$vm_id" --ide2 "${STORAGE}:cloudinit"
    qm set "$vm_id" \
        --ciuser    "$VM_USER" \
        --cipassword "$VM_PASSWORD" \
        --sshkeys   <(echo "$SSH_PUBLIC_KEY") \
        --ipconfig0 "ip=${ip}/${SUBNET_MASK},gw=${GATEWAY}" \
        --nameserver "$NAMESERVER"

    # Apply any additional arguments (e.g. GPU hostpci for ai-vm)
    if [[ -n "$extra_args" ]]; then
        # eval is intentional here: extra_args is a multi-flag string built
        # by this script, not user input
        eval "qm set $vm_id $extra_args"
    fi

    info "VM $vm_name created ✓"
}

##
# Detect the PCI address of the RTX 4090 and build the hostpci argument
# string for attaching it to a VM.
#
# Sets global variable GPU_HOSTPCI to a string of --hostpci0 [--hostpci1]
# flags suitable for passing to  qm set  via create_vm's EXTRA_ARGS.
# If no GPU is found, sets GPU_HOSTPCI to an empty string.
#
# Side effects:
#   Sets global variable GPU_HOSTPCI
##
detect_gpu_hostpci() {
    section "GPU Passthrough Detection"

    local gpu_addr audio_addr
    gpu_addr=$(lspci | grep -i "RTX 4090" | awk '{print $1}' | head -1 || true)

    if [[ -z "$gpu_addr" ]]; then
        warn "RTX 4090 not found — trying any NVIDIA device..."
        gpu_addr=$(lspci | grep -i nvidia | awk '{print $1}' | head -1 || true)
    fi

    if [[ -z "$gpu_addr" ]]; then
        warn "No GPU found — ai-vm will be created WITHOUT GPU passthrough"
        GPU_HOSTPCI=""
        return 0
    fi

    info "GPU found at PCI address: $gpu_addr"
    GPU_HOSTPCI="--hostpci0 ${gpu_addr},pcie=1,x-vga=1,rombar=1"

    # Also pass through the companion HDMI audio device if present
    audio_addr=$(lspci | grep "${gpu_addr%.*}" | grep -i audio | awk '{print $1}' || true)
    if [[ -n "$audio_addr" ]]; then
        GPU_HOSTPCI="$GPU_HOSTPCI --hostpci1 ${audio_addr}"
        info "GPU audio device also found: $audio_addr"
    fi
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

GPU_HOSTPCI=""

download_cloud_image
detect_gpu_hostpci

# Create VMs in order. ai-vm receives GPU_HOSTPCI; others have no extra args.
create_vm "$AI_VM_ID"         "ai-vm"         "$AI_VM_RAM"         "$AI_VM_CORES"         "$AI_VM_DISK"         "$AI_VM_IP"         "$GPU_HOSTPCI"
create_vm "$CODING_VM_ID"     "coding-vm"     "$CODING_VM_RAM"     "$CODING_VM_CORES"     "$CODING_VM_DISK"     "$CODING_VM_IP"
create_vm "$DATA_VM_ID"       "data-vm"       "$DATA_VM_RAM"       "$DATA_VM_CORES"       "$DATA_VM_DISK"       "$DATA_VM_IP"
create_vm "$AUTOMATION_VM_ID" "automation-vm" "$AUTOMATION_VM_RAM" "$AUTOMATION_VM_CORES" "$AUTOMATION_VM_DISK" "$AUTOMATION_VM_IP"
create_vm "$MONITORING_VM_ID" "monitoring-vm" "$MONITORING_VM_RAM" "$MONITORING_VM_CORES" "$MONITORING_VM_DISK" "$MONITORING_VM_IP"

# Start all VMs; cloud-init runs on first boot and configures networking
section "Starting VMs"
for vmid in $AI_VM_ID $CODING_VM_ID $DATA_VM_ID $AUTOMATION_VM_ID $MONITORING_VM_ID; do
    info "Starting VM $vmid..."
    qm start "$vmid"
    sleep 2
done

cat <<EOF

${GREEN}════════════════════════════════════════════════════════${NC}
  All VMs created and started.

  Wait ~60 seconds for cloud-init to complete, then test SSH:
    ssh ${VM_USER}@${AI_VM_IP}        (ai-vm)
    ssh ${VM_USER}@${CODING_VM_IP}    (coding-vm)
    ssh ${VM_USER}@${DATA_VM_IP}      (data-vm)
    ssh ${VM_USER}@${AUTOMATION_VM_IP} (automation-vm)
    ssh ${VM_USER}@${MONITORING_VM_IP} (monitoring-vm)

  Next step:
    bash deploy_all.sh
${GREEN}════════════════════════════════════════════════════════${NC}
EOF
