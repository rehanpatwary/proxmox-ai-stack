#!/usr/bin/env bash
# =============================================================================
#  data-vm/setup.sh — Data VM Service Installer
#
#  Installs PostgreSQL 16 with the pgvector extension on data-vm.
#  This VM acts as the shared database server for all other VMs:
#    - AnythingLLM (ai-vm)    — workspace and document metadata
#    - n8n and Flowise        — workflow state and credentials
#    - LXC business services  — Monica, BookStack, Outline, Mattermost, etc.
#
#  SERVICES DEPLOYED
#  ─────────────────
#  Service       Port   Description
#  ──────────────────────────────────────────────────────────────────────────
#  PostgreSQL 16  5432  Primary database server with pgvector extension
#  pgAdmin 4      5050  Web-based Postgres management UI
#  node-exporter  9100  Prometheus system metrics
#
#  DATABASES CREATED
#  ─────────────────
#  postgres       — default superuser database
#  anythingllm    — AnythingLLM workspace data (pgvector enabled)
#  n8n            — n8n workflow and credential storage (also used by Flowise)
#  app_db         — general purpose; rename or replace as needed
#
#  POSTGRES TUNING
#  ───────────────
#  The Postgres instance is tuned for the DATA_VM_RAM allocation (16 GB default):
#    shared_buffers        4 GB   (25% of RAM — main cache)
#    effective_cache_size  12 GB  (guidance for query planner)
#    work_mem              ~20 MB (per sort/hash operation)
#    maintenance_work_mem  1 GB   (for VACUUM, index builds)
#
#  FIREWALL
#  ────────
#  UFW rules allow port 5432 only from AI_VM_IP and AUTOMATION_VM_IP.
#  pgAdmin (5050) and node-exporter (9100) are open to the LAN.
#  Adjust rules if adding additional VMs or LXC containers that need Postgres.
#
#  REQUIREMENTS
#  ────────────
#  - Run as root inside data-vm
#  - POSTGRES_PASSWORD, AI_VM_IP, AUTOMATION_VM_IP must be set via env
#
#  USAGE
#  ─────
#    bash deploy_vm.sh data         (from Proxmox host — recommended)
#    sudo -E bash ~/data-vm/setup.sh  (from inside data-vm)
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
#  Config with safe defaults
# ---------------------------------------------------------------------------
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
AI_VM_IP="${AI_VM_IP:-192.168.1.10}"
AUTOMATION_VM_IP="${AUTOMATION_VM_IP:-192.168.1.40}"

[[ -z "$POSTGRES_PASSWORD" ]] && error "POSTGRES_PASSWORD is empty. Run  bash init_secrets.sh  on the Proxmox host."

# ---------------------------------------------------------------------------
#  Functions
# ---------------------------------------------------------------------------

##
# Update apt and install Docker CE with the Compose plugin.
# Idempotent: skips if Docker is already present.
##
install_docker() {
    section "System Update + Docker"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg lsb-release

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
# Write the SQL init script that runs on Postgres first boot.
#
# Creates additional databases, users, and enables the pgvector extension.
# This file is mounted into the Postgres container at
# /docker-entrypoint-initdb.d/ and executed automatically on first start
# (not on subsequent starts — Postgres only runs initdb on an empty data dir).
##
write_init_sql() {
    section "Postgres Init SQL"
    mkdir -p /opt/data-stack/postgres/init

    cat > /opt/data-stack/postgres/init/01_init.sql <<SQL
-- Enable pgvector on the default database
CREATE EXTENSION IF NOT EXISTS vector;

-- Databases for each service
CREATE DATABASE anythingllm;
CREATE DATABASE n8n;
CREATE DATABASE app_db;

-- Dedicated application users with least-privilege access
CREATE USER anythingllm_user WITH PASSWORD '${POSTGRES_PASSWORD}';
GRANT ALL PRIVILEGES ON DATABASE anythingllm TO anythingllm_user;

CREATE USER n8n_user WITH PASSWORD '${POSTGRES_PASSWORD}';
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n_user;

-- Enable pgvector in the AnythingLLM database for embedding storage
\c anythingllm
CREATE EXTENSION IF NOT EXISTS vector;
SELECT 'pgvector enabled in anythingllm' AS status;
SQL

    info "Init SQL written ✓"
}

##
# Write the Docker Compose file for Postgres, pgAdmin, and node-exporter.
#
# Postgres is launched with explicit performance tuning flags appropriate
# for the DATA_VM_RAM allocation (16 GB default). The values are commented
# in the compose file for reference.
##
write_docker_compose() {
    section "Docker Compose"
    cat > /opt/data-stack/docker-compose.yml <<COMPOSE
version: "3.9"

networks:
  data-net:
    driver: bridge

volumes:
  postgres_data:
  pgadmin_data:

services:

  # ── PostgreSQL 16 + pgvector ──────────────────────────────────────────────
  # pgvector/pgvector:pg16 is the official image with the pgvector extension
  # pre-compiled. The init SQL at /docker-entrypoint-initdb.d/ runs once
  # on first boot to create databases and enable extensions.
  postgres:
    image: pgvector/pgvector:pg16
    container_name: postgres
    restart: unless-stopped
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: postgres
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - /opt/data-stack/postgres/init:/docker-entrypoint-initdb.d:ro
    command: >
      postgres
        -c max_connections=200
        -c shared_buffers=4GB
        -c effective_cache_size=12GB
        -c maintenance_work_mem=1GB
        -c checkpoint_completion_target=0.9
        -c wal_buffers=16MB
        -c default_statistics_target=100
        -c random_page_cost=1.1
        -c effective_io_concurrency=200
        -c work_mem=20971kB
        -c huge_pages=off
        -c min_wal_size=1GB
        -c max_wal_size=4GB
    networks:
      - data-net

  # ── pgAdmin 4 ─────────────────────────────────────────────────────────────
  # Web UI for Postgres management. SERVER_MODE=False disables the login
  # screen (single-user mode — fine for internal access).
  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: pgadmin
    restart: unless-stopped
    ports:
      - "5050:80"
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@local.com
      PGADMIN_DEFAULT_PASSWORD: ${POSTGRES_PASSWORD}
      PGADMIN_CONFIG_SERVER_MODE: "False"
    volumes:
      - pgadmin_data:/var/lib/pgadmin
    depends_on:
      - postgres
    networks:
      - data-net

  # ── Prometheus Node Exporter ──────────────────────────────────────────────
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
      - data-net

COMPOSE
    info "docker-compose.yml written ✓"
}

##
# Configure UFW firewall rules for the data-vm.
#
# Port 5432 is restricted to AI_VM_IP and AUTOMATION_VM_IP only.
# Additional VMs or LXC containers that need Postgres must be added here.
# Port 5050 (pgAdmin) and 9100 (node-exporter) are open to all.
##
configure_firewall() {
    section "Firewall (UFW)"

    if ! command -v ufw &>/dev/null; then
        warn "ufw not found — skipping firewall configuration"
        return 0
    fi

    ufw --force enable
    ufw allow ssh

    # Postgres: allow only from VMs that need it
    ufw allow from "$AI_VM_IP"         to any port 5432 comment "ai-vm"
    ufw allow from "$AUTOMATION_VM_IP" to any port 5432 comment "automation-vm"

    # Management interfaces open to LAN
    ufw allow 5050/tcp  comment "pgAdmin"
    ufw allow 9100/tcp  comment "node-exporter"

    info "UFW rules applied ✓"
    ufw status verbose
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

install_docker
write_init_sql
write_docker_compose
configure_firewall

section "Starting Stack"
cd /opt/data-stack
docker compose up -d
info "Waiting 10s for Postgres to complete initialisation..."
sleep 10
docker compose ps

# ---------------------------------------------------------------------------
#  Post-install summary
# ---------------------------------------------------------------------------
VM_IP=$(hostname -I | awk '{print $1}')

cat <<EOF

${GREEN}════════════════════════════════════════════════════════${NC}
  Data VM stack is running.

  Services:
    PostgreSQL 16 + pgvector → ${VM_IP}:5432
    pgAdmin 4                → http://${VM_IP}:5050

  Connection string:
    postgresql://postgres:${POSTGRES_PASSWORD}@${VM_IP}:5432/postgres

  Databases: postgres, anythingllm, n8n, app_db

  IMPORTANT — Save this password:
    ${POSTGRES_PASSWORD}
${GREEN}════════════════════════════════════════════════════════${NC}
EOF
