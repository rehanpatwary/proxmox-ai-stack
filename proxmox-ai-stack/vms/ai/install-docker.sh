#!/usr/bin/env bash
# =============================================================================
#  install-docker.sh — Docker CE installer
#
#  SOURCE-ONLY: do not run this file directly.
#  Sourced by ai/setup.sh, which calls the functions below.
# =============================================================================
set -euo pipefail

##
# Install Docker CE and the Docker Compose plugin from Docker's official repo.
#
# Idempotent: skips if the docker binary already exists.
# Enables the Docker daemon to start on boot via systemd.
##
install_docker() {
    section "Docker CE"

    if command -v docker &>/dev/null; then
        info "Docker already installed ($(docker --version)) ✓"
        return 0
    fi

    info "Installing Docker CE..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    info "Docker installed ✓"
}
