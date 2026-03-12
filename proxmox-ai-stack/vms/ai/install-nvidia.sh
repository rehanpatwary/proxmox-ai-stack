#!/usr/bin/env bash
# =============================================================================
#  install-nvidia.sh — NVIDIA Driver + Container Toolkit installers
#
#  SOURCE-ONLY: do not run this file directly.
#  Sourced by ai/setup.sh, which calls the functions below.
# =============================================================================
set -euo pipefail

##
# Install NVIDIA driver 535 from the graphics-drivers PPA.
#
# Idempotent: checks nvidia-smi before installing.
# A reboot may be required on first install for the GPU to become visible.
##
install_nvidia_driver() {
    section "NVIDIA Driver"

    if nvidia-smi &>/dev/null; then
        local ver
        ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)
        info "NVIDIA driver already installed (version: $ver) ✓"
        return 0
    fi

    info "Installing NVIDIA driver 535..."
    add-apt-repository -y ppa:graphics-drivers/ppa
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-driver-535
    info "Driver installed ✓ (reboot may be required if GPU not yet visible)"
}

##
# Install the NVIDIA Container Toolkit to enable GPU access inside containers.
#
# Idempotent: checks for the nvidia-container-toolkit package.
#
# GPG WORKAROUND:
#   The standard  curl | gpg --dearmor  pipe fails in non-interactive SSH
#   sessions because gpg opens /dev/tty for a passphrase prompt.
#   Fix: save key to a temp file first, then dearmor with --batch --no-tty.
#
# Side effects:
#   Configures the NVIDIA runtime as Docker's default GPU runtime.
#   Restarts Docker to apply the runtime change.
##
install_nvidia_container_toolkit() {
    section "NVIDIA Container Toolkit"

    if dpkg -l | grep -q nvidia-container-toolkit; then
        info "NVIDIA Container Toolkit already installed ✓"
        return 0
    fi

    info "Installing NVIDIA Container Toolkit..."

    # SSH-safe GPG: save key to temp file, dearmor with --batch --no-tty
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        > /tmp/nvidia-gpgkey.asc
    gpg --batch --yes --no-tty \
        --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        /tmp/nvidia-gpgkey.asc
    rm -f /tmp/nvidia-gpgkey.asc

    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    info "NVIDIA Container Toolkit installed ✓"
}
