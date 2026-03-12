#!/usr/bin/env bash
# =============================================================================
#  00_gpu_passthrough.sh — GPU Passthrough Configuration
#
#  Configures the Proxmox HOST to pass a GPU exclusively to a VM using VFIO.
#  After running this script, the GPU is no longer usable by the host OS;
#  it is reserved for the VM that has it attached.
#
#  WHAT IT DOES
#  ────────────
#  1. Detects CPU vendor (Intel / AMD) and enables the correct IOMMU flag
#  2. Adds IOMMU kernel parameters to GRUB
#  3. Loads VFIO kernel modules at boot
#  4. Scans for the RTX 4090 PCI IDs (GPU + onboard audio device)
#  5. Binds those PCI IDs to the vfio-pci driver
#  6. Blacklists the NVIDIA and Nouveau drivers on the host
#  7. Rebuilds initramfs to apply module changes
#
#  REQUIREMENTS
#  ────────────
#  - Run as root on the Proxmox HOST (not inside a VM)
#  - VT-d (Intel) or AMD-Vi (AMD) enabled in BIOS/UEFI
#  - GPU physically installed in the host machine
#
#  USAGE
#  ─────
#    bash 00_gpu_passthrough.sh
#    reboot
#    # Then verify: lspci -nnk | grep -A3 "RTX 4090"
#    #              Expected: Kernel driver in use: vfio-pci
#
#  AFTER REBOOT
#  ────────────
#    Run 01_create_vms.sh to create VMs with the GPU passed through.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

##
# Print a green INFO message to stdout.
# Arguments: $@ — message text
##
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }

##
# Print a yellow WARN message to stdout. Execution continues.
# Arguments: $@ — message text
##
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

##
# Print a red ERROR message and exit 1.
# Arguments: $@ — message text
##
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
#  Guard: must run as root on a Proxmox host
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Must run as root"
command -v update-grub &>/dev/null || error "update-grub not found. Are you on a Proxmox host?"

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Detect CPU vendor and return the appropriate IOMMU kernel parameter string.
#
# Reads /proc/cpuinfo to determine Intel vs AMD. Sets the global IOMMU_FLAG
# variable to the correct kernel cmdline argument for enabling IOMMU.
#
# Side effects:
#   Sets global variable IOMMU_FLAG
#
# Exits 1 if vendor cannot be determined.
##
detect_iommu_flag() {
    local vendor
    vendor=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
    info "CPU vendor: $vendor"

    case "$vendor" in
        GenuineIntel)  IOMMU_FLAG="intel_iommu=on iommu=pt" ;;
        AuthenticAMD)  IOMMU_FLAG="amd_iommu=on iommu=pt"  ;;
        *)             error "Unrecognised CPU vendor: $vendor — set IOMMU_FLAG manually" ;;
    esac

    info "IOMMU flag: $IOMMU_FLAG"
}

##
# Append IOMMU kernel parameters to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub.
#
# Idempotent: checks whether any 'iommu' string is already present in the grub
# file before modifying it. If already present, skips silently.
#
# Side effects:
#   Modifies /etc/default/grub
#   Calls update-grub to rebuild /boot/grub/grub.cfg
##
enable_iommu_in_grub() {
    local grub_file="/etc/default/grub"

    if grep -q "iommu" "$grub_file"; then
        warn "IOMMU parameters already present in $grub_file — skipping"
        return 0
    fi

    info "Adding IOMMU parameters to GRUB..."
    sed -i \
        "s/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet ${IOMMU_FLAG}\"/" \
        "$grub_file"

    update-grub
    info "GRUB updated ✓"
}

##
# Register VFIO kernel modules to load at boot via /etc/modules.
#
# Adds the four modules required for PCI passthrough to /etc/modules.
# Idempotent: each module is only added if not already present.
#
# Modules added:
#   vfio             — Virtual Function I/O framework
#   vfio_iommu_type1 — IOMMU driver for VFIO
#   vfio_pci         — Binds PCI devices to VFIO
#   vfio_virqfd      — IRQ file descriptor support
#
# Side effects:
#   Appends lines to /etc/modules
##
register_vfio_modules() {
    local modules_file="/etc/modules"
    local modules=(vfio vfio_iommu_type1 vfio_pci vfio_virqfd)

    for mod in "${modules[@]}"; do
        if grep -q "^${mod}" "$modules_file"; then
            info "Module already registered: $mod"
        else
            echo "$mod" >> "$modules_file"
            info "Registered module: $mod"
        fi
    done
}

##
# Detect the PCI IDs of the RTX 4090 GPU and its companion audio device.
#
# Scans lspci output for "RTX 4090" and extracts the vendor:device ID pairs
# (format: [10de:xxxx]). Also finds the HDMI audio device on the same
# IOMMU group (same PCI bus prefix) and appends its ID.
#
# Falls back to hardcoded default IDs (10de:2684 GPU, 10de:22ba audio) if
# no RTX 4090 is found, with a warning.
#
# Side effects:
#   Sets global variable GPU_IDS (comma-separated vendor:device pairs)
##
detect_gpu_pci_ids() {
    local gpu_line audio_line gpu_addr audio_id

    info "Scanning for RTX 4090 via lspci..."
    gpu_line=$(lspci -nn | grep -i "RTX 4090" || true)

    if [[ -z "$gpu_line" ]]; then
        warn "RTX 4090 not found. Listing all NVIDIA devices:"
        lspci -nn | grep -i nvidia || warn "No NVIDIA devices found at all"
        warn "Using default RTX 4090 PCI IDs: 10de:2684,10de:22ba"
        GPU_IDS="10de:2684,10de:22ba"
        return 0
    fi

    info "Found: $gpu_line"

    # Extract [vendor:device] pairs from lspci -nn output
    GPU_IDS=$(echo "$gpu_line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | paste -sd, -)

    # Find the companion HDMI audio device (same PCI bus/device, function 1)
    gpu_addr=$(echo "$gpu_line" | awk '{print $1}')
    audio_line=$(lspci -nn | grep "${gpu_addr%.*}" | grep -i audio || true)

    if [[ -n "$audio_line" ]]; then
        audio_id=$(echo "$audio_line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1)
        GPU_IDS="${GPU_IDS},${audio_id}"
        info "Audio device also found: $audio_id"
    fi

    info "GPU PCI IDs to bind: $GPU_IDS"
}

##
# Write the VFIO driver binding configuration for the detected GPU.
#
# Creates /etc/modprobe.d/vfio.conf which instructs the vfio-pci driver
# to claim the specified PCI IDs at boot, before any NVIDIA driver loads.
# The softdep directive enforces load order.
#
# Arguments: none (reads global GPU_IDS)
#
# Side effects:
#   Writes /etc/modprobe.d/vfio.conf
##
write_vfio_config() {
    local vfio_conf="/etc/modprobe.d/vfio.conf"
    {
        echo "options vfio-pci ids=${GPU_IDS}"
        echo "softdep nvidia pre: vfio-pci"
    } > "$vfio_conf"
    info "Written: $vfio_conf"
}

##
# Blacklist the host NVIDIA and Nouveau drivers.
#
# Prevents the host kernel from loading any NVIDIA driver for the GPU,
# ensuring vfio-pci gets exclusive ownership. Without this, a race
# condition at boot may cause NVIDIA to claim the device before VFIO.
#
# Side effects:
#   Writes /etc/modprobe.d/blacklist-nvidia.conf
##
blacklist_nvidia_on_host() {
    local blacklist_conf="/etc/modprobe.d/blacklist-nvidia.conf"
    cat > "$blacklist_conf" <<'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist nvidia_modeset
EOF
    info "Written: $blacklist_conf"
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

# Globals set by detection functions
IOMMU_FLAG=""
GPU_IDS=""

detect_iommu_flag
enable_iommu_in_grub
register_vfio_modules
detect_gpu_pci_ids
write_vfio_config
blacklist_nvidia_on_host

# Rebuild initramfs so all module and config changes take effect at next boot
info "Rebuilding initramfs (this may take a minute)..."
update-initramfs -u -k all
info "Initramfs rebuilt ✓"

# ---------------------------------------------------------------------------
#  Post-run instructions
# ---------------------------------------------------------------------------
cat <<EOF

${GREEN}════════════════════════════════════════════════════════${NC}
  GPU Passthrough configuration complete.

  NEXT STEPS:
  1. REBOOT the Proxmox host now:
       reboot

  2. After reboot, verify passthrough is active:
       lspci -nnk | grep -A3 -i "RTX 4090"
       # Expected:  Kernel driver in use: vfio-pci

       dmesg | grep -i iommu | head -5
       # Expected:  IOMMU enabled

  3. Then run:
       bash 01_create_vms.sh

  GPU IDs bound to VFIO: ${GPU_IDS}
${GREEN}════════════════════════════════════════════════════════${NC}
EOF
