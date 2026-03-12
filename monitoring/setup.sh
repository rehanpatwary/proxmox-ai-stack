#!/usr/bin/env bash
# =============================================================================
#  monitoring/setup.sh — Monitoring VM Service Installer
#
#  Installs Prometheus and Grafana on monitoring-vm. Prometheus is
#  pre-configured to scrape metrics from all five VMs including GPU metrics
#  from ai-vm. Grafana is provisioned with the Prometheus datasource.
#
#  SERVICES DEPLOYED
#  ─────────────────
#  Service        Port   Description
#  ──────────────────────────────────────────────────────────────────────────
#  Prometheus     9090   Time-series metrics collection and storage
#  Grafana        3003   Dashboard visualisation (admin / GRAFANA_ADMIN_PASSWORD)
#  Alertmanager   9093   Alert routing (installed; configure rules as needed)
#  node-exporter  9100   Self-monitoring for this VM
#
#  PROMETHEUS SCRAPE TARGETS
#  ─────────────────────────
#  Job               Target               Metrics
#  ──────────────────────────────────────────────────────────────────────────
#  ai-vm             AI_VM_IP:9100        System (node-exporter)
#  ai-vm-gpu         AI_VM_IP:9445        GPU (nvidia-exporter)
#  ai-vm-cadvisor    AI_VM_IP:9080        Docker containers
#  coding-vm         CODING_VM_IP:9100    System
#  data-vm           DATA_VM_IP:9100      System
#  automation-vm     AUTOMATION_VM_IP:9100 System
#  monitoring-vm     MONITORING_VM_IP:9100 System (self)
#  ollama            AI_VM_IP:11434/metrics Ollama API metrics
#
#  GRAFANA SETUP
#  ─────────────
#  The Prometheus datasource is provisioned automatically. To add dashboards:
#  Grafana → Dashboards → New → Import → paste ID
#    1860  — Node Exporter Full
#    14574 — NVIDIA GPU Metrics
#    893   — Docker Container Metrics
#    3662  — Prometheus Overview
#
#  REQUIREMENTS
#  ────────────
#  - Run as root inside monitoring-vm
#  - All other VMs should be running (so targets are reachable at first scrape)
#
#  USAGE
#  ─────
#    bash deploy_vm.sh monitoring         (from Proxmox host — recommended)
#    sudo -E bash ~/monitoring/setup.sh   (from inside the VM)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root:  sudo -E bash setup.sh"

# ---------------------------------------------------------------------------
#  Common VM bootstrap (chrony, journald limits, TRIM, admin tools)
#  Runs once; idempotent on re-runs.
# ---------------------------------------------------------------------------
# shellcheck source=../common/bootstrap.sh
source "$(dirname "$0")/../common/bootstrap.sh"

# ---------------------------------------------------------------------------
#  Config with safe defaults
# ---------------------------------------------------------------------------
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
AI_VM_IP="${AI_VM_IP:-192.168.1.10}"
CODING_VM_IP="${CODING_VM_IP:-192.168.1.20}"
DATA_VM_IP="${DATA_VM_IP:-192.168.1.30}"
AUTOMATION_VM_IP="${AUTOMATION_VM_IP:-192.168.1.40}"
MONITORING_VM_IP="${MONITORING_VM_IP:-192.168.1.50}"

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Update apt and install Docker CE.
# Idempotent: skips if Docker is already present.
##
install_docker() {
    section "System Update + Docker"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget gnupg lsb-release

    if command -v docker &>/dev/null; then
        info "Docker already installed ($(docker --version))"
        return 0
    fi

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    info "Docker installed ✓"
}

##
# Write the Prometheus configuration file defining scrape targets.
#
# The config is written to /opt/monitoring/prometheus/prometheus.yml and
# mounted into the Prometheus container as read-only. Scrape interval is
# 15s — reduce to 30s or 60s on lower-resource hosts.
##
write_prometheus_config() {
    section "Prometheus Config"
    mkdir -p /opt/monitoring/prometheus

    cat > /opt/monitoring/prometheus/prometheus.yml <<PROM
# =============================================================================
#  Prometheus configuration — Proxmox AI Stack
# =============================================================================

global:
  scrape_interval:     15s   # How often to collect metrics from each target
  evaluation_interval: 15s   # How often to evaluate alert rules
  scrape_timeout:      10s   # Timeout per scrape request

alerting:
  alertmanagers: []   # Add alertmanager targets here when alert rules are defined

rule_files: []        # Add alert rule file paths here

scrape_configs:

  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # ai-vm: system metrics via node-exporter
  - job_name: 'ai-vm'
    static_configs:
      - targets: ['${AI_VM_IP}:9100']
        labels:
          instance: 'ai-vm'
          role: 'inference'

  # ai-vm: NVIDIA GPU metrics via nvidia-exporter
  - job_name: 'ai-vm-gpu'
    static_configs:
      - targets: ['${AI_VM_IP}:9445']
        labels:
          instance: 'ai-vm'
          role: 'gpu'

  # coding-vm: system metrics
  - job_name: 'coding-vm'
    static_configs:
      - targets: ['${CODING_VM_IP}:9100']
        labels:
          instance: 'coding-vm'
          role: 'coding'

  # data-vm: system metrics
  - job_name: 'data-vm'
    static_configs:
      - targets: ['${DATA_VM_IP}:9100']
        labels:
          instance: 'data-vm'
          role: 'database'

  # automation-vm: system metrics
  - job_name: 'automation-vm'
    static_configs:
      - targets: ['${AUTOMATION_VM_IP}:9100']
        labels:
          instance: 'automation-vm'
          role: 'automation'

  # monitoring-vm: self-monitoring
  - job_name: 'monitoring-vm'
    static_configs:
      - targets: ['${MONITORING_VM_IP}:9100']
        labels:
          instance: 'monitoring-vm'
          role: 'monitoring'

  # Ollama API native metrics endpoint
  - job_name: 'ollama'
    static_configs:
      - targets: ['${AI_VM_IP}:11434']
    metrics_path: '/metrics'
    scheme: http

PROM
    info "prometheus.yml written ✓"
}

##
# Write Grafana provisioning files for automatic datasource configuration.
#
# Grafana reads provisioning files at startup and configures datasources
# automatically without requiring manual UI steps. The Prometheus datasource
# is set as the default so new dashboards use it without additional config.
##
write_grafana_provisioning() {
    section "Grafana Provisioning"
    mkdir -p /opt/monitoring/grafana/provisioning/{datasources,dashboards}
    mkdir -p /opt/monitoring/grafana/dashboards

    # Datasource: Prometheus
    cat > /opt/monitoring/grafana/provisioning/datasources/prometheus.yml <<DS
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
DS

    # Dashboard provider: load JSON files from /var/lib/grafana/dashboards/
    cat > /opt/monitoring/grafana/provisioning/dashboards/default.yml <<DASH
apiVersion: 1
providers:
  - name: 'AI Stack'
    orgId: 1
    folder: 'AI Stack'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
DASH

    info "Grafana provisioning files written ✓"
}

##
# Write the Docker Compose file for Prometheus, Grafana, Alertmanager, and
# a local node-exporter for self-monitoring.
#
# Prometheus data retention is set to 30 days. Grafana community plugins
# are installed at startup via GF_INSTALL_PLUGINS.
##
write_docker_compose() {
    section "Docker Compose"

    cat > /opt/monitoring/docker-compose.yml <<COMPOSE
version: "3.9"

networks:
  mon-net:
    driver: bridge

volumes:
  prometheus_data:
  grafana_data:

services:

  # ── Prometheus ────────────────────────────────────────────────────────────
  # Collects and stores metrics from all VMs. Retention is 30 days.
  # web.enable-lifecycle allows config reload via POST /-/reload.
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - /opt/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
    networks:
      - mon-net

  # ── Grafana ───────────────────────────────────────────────────────────────
  # Dashboard platform. Prometheus datasource is auto-provisioned.
  # Community plugins are installed at container startup.
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3003:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_INSTALL_PLUGINS: grafana-clock-panel,grafana-worldmap-panel,natel-plotly-panel
    volumes:
      - grafana_data:/var/lib/grafana
      - /opt/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
      - /opt/monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro
    depends_on:
      - prometheus
    networks:
      - mon-net

  # ── Alertmanager ──────────────────────────────────────────────────────────
  # Alert routing for Prometheus rules. Pre-installed with empty config.
  # Add receivers (email, Slack, PagerDuty) in alertmanager.yml as needed.
  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    restart: unless-stopped
    ports:
      - "9093:9093"
    networks:
      - mon-net

  # ── Node Exporter (self) ──────────────────────────────────────────────────
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
    networks:
      - mon-net

COMPOSE
    info "docker-compose.yml written ✓"
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

install_docker
write_prometheus_config
write_grafana_provisioning
write_docker_compose

section "Starting Stack"
cd /opt/monitoring
docker compose up -d
sleep 10
docker compose ps

# ---------------------------------------------------------------------------
#  Post-install summary
# ---------------------------------------------------------------------------
VM_IP=$(hostname -I | awk '{print $1}')

cat <<EOF

${GREEN}════════════════════════════════════════════════════════${NC}
  Monitoring VM stack is running.

  Services:
    Grafana    → http://${VM_IP}:3003  (admin / ${GRAFANA_ADMIN_PASSWORD})
    Prometheus → http://${VM_IP}:9090

  NEXT STEP — Import dashboards in Grafana:
    Dashboards → New → Import → enter ID → Load → Save

    ID     Dashboard
    ─────  ─────────────────────────────────
    1860   Node Exporter Full (all VMs)
    14574  NVIDIA GPU Metrics
    893    Docker Container Metrics
    3662   Prometheus Overview

  Check scrape status:
    http://${VM_IP}:9090/targets
    (some targets may show DOWN until node-exporter is running on each VM)
${GREEN}════════════════════════════════════════════════════════${NC}
EOF
