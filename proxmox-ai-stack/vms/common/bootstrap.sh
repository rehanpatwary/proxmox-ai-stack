#!/usr/bin/env bash
# =============================================================================
#  common/bootstrap.sh — VM Base Hardening and Hygiene
#
#  Runs once on every VM immediately after cloud-init, before any service
#  installation. Handles OS-level hygiene that is common to all VMs:
#
#  WHAT IT DOES
#  ────────────
#  1. Installs useful admin tools (htop, tmux, chrony, nvme-cli, etc.)
#  2. Enables chrony for accurate NTP time sync
#  3. Caps journald disk usage so logs don't fill the root partition
#  4. Enables weekly SSD TRIM to maintain storage performance
#  5. Prints a one-time hardware summary (CPU, RAM, disk, NICs)
#
#  IDEMPOTENT
#  ──────────
#  A sentinel file (/var/lib/vm-bootstrap-done) is written on completion.
#  Re-running the script skips all steps and exits immediately.
#
#  CALLED BY
#  ─────────
#  Each VM's setup.sh sources this file early in its main section:
#    source "$(dirname "$0")/../common/bootstrap.sh"
#
#  REQUIREMENTS
#  ────────────
#  - Run as root (each setup.sh enforces this before sourcing)
#  - Ubuntu 22.04 / 24.04 (systemd + apt)
# =============================================================================

# ---------------------------------------------------------------------------
#  Logging helpers (defined here in case this file is sourced before the
#  calling script sets them up; no-op if already defined)
# ---------------------------------------------------------------------------
if ! declare -f info &>/dev/null; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
    info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
    section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
    warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
fi

BOOTSTRAP_SENTINEL="/var/lib/vm-bootstrap-done"

# ---------------------------------------------------------------------------
#  Idempotency guard
# ---------------------------------------------------------------------------
if [[ -f "$BOOTSTRAP_SENTINEL" ]]; then
    info "VM bootstrap already complete (sentinel: ${BOOTSTRAP_SENTINEL}) — skipping"
    return 0 2>/dev/null || exit 0
fi

section "VM Bootstrap (common hygiene)"

# ---------------------------------------------------------------------------
#  1. Admin tools
#
#  Packages ported from vmscripts/imp.sh:
#    htop            — interactive process viewer
#    tmux            — terminal multiplexer (keeps sessions alive over SSH)
#    chrony          — NTP client (more reliable than systemd-timesyncd)
#    nvme-cli        — NVMe drive management and SMART queries
#    smartmontools   — SMART disk health monitoring (smartctl)
#    pciutils        — lspci for PCI device inspection (GPU, NIC, etc.)
#    ethtool         — network interface diagnostics
# ---------------------------------------------------------------------------
info "Installing admin tools..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    htop tmux \
    chrony \
    nvme-cli smartmontools \
    pciutils ethtool
info "Admin tools installed ✓"

# ---------------------------------------------------------------------------
#  2. Time sync — chrony
#
#  chrony syncs the hardware clock faster and more accurately than the
#  default systemd-timesyncd. Correct time is critical for:
#    - TLS certificate validation
#    - Postgres replication / log timestamps
#    - Prometheus metric alignment across VMs
# ---------------------------------------------------------------------------
info "Enabling chrony time sync..."
systemctl enable --now chrony
chronyc tracking 2>/dev/null | grep -E "^(Reference|System)" || true
info "Chrony active ✓"

# ---------------------------------------------------------------------------
#  3. Journal size limits
#
#  Without limits, systemd-journald can accumulate GBs of logs on a busy VM.
#  SystemMaxUse=1G  — cap persistent journal on disk
#  RuntimeMaxUse=512M — cap volatile journal in /run
# ---------------------------------------------------------------------------
info "Applying journald size limits..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-size-limit.conf <<'JOURNAL'
[Journal]
SystemMaxUse=1G
RuntimeMaxUse=512M
JOURNAL
systemctl restart systemd-journald
info "Journald limits applied (max 1G persistent, 512M volatile) ✓"

# ---------------------------------------------------------------------------
#  4. Weekly SSD TRIM
#
#  TRIM notifies the SSD controller of unused blocks, maintaining write
#  performance and extending drive life. The fstrim.timer unit runs
#  fstrim -av weekly on all mounted filesystems that support it.
# ---------------------------------------------------------------------------
info "Enabling weekly SSD TRIM..."
systemctl enable --now fstrim.timer
info "fstrim.timer enabled ✓"

# ---------------------------------------------------------------------------
#  5. Hardware summary (informational — shown once on first deploy)
# ---------------------------------------------------------------------------
section "Hardware Summary"
echo "  CPU:"; lscpu | awk '/^(Model name|CPU\(s\)|Thread|Core)/{printf "    %-30s %s\n", $0}' | head -6
echo ""
echo "  RAM:"; free -h | awk 'NR<=2{printf "    %s\n", $0}'
echo ""
echo "  Disk:"; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | awk '{printf "    %s\n", $0}' | head -12
echo ""
echo "  NIC:"; ip -br link | awk '{printf "    %s\n", $0}'

# ---------------------------------------------------------------------------
#  Mark complete
# ---------------------------------------------------------------------------
touch "$BOOTSTRAP_SENTINEL"
info "VM bootstrap complete ✓"
