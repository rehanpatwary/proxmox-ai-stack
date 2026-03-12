# Proxmox AI Stack

A fully automated deployment pipeline for a self-hosted AI and business automation infrastructure on Proxmox VE. Combines GPU-accelerated QEMU VMs for performance-critical AI workloads with lightweight LXC containers for business services.

---

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [Deployment Guide](#deployment-guide)
- [Service Catalog](#service-catalog)
- [LXC Integration](#lxc-integration)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

---

## Repository Layout

This repository is structured to support multiple stacks:

```
/
└── proxmox-ai-stack/   ← Proxmox VE + 5 Ubuntu VMs + optional LXC layer
```

See [proxmox-ai-stack/README.md](proxmox-ai-stack/README.md) for the full quick-start guide.

---

## Architecture

```
Proxmox VE Host
│
├── VM Layer  (QEMU/KVM — GPU and performance workloads)
│   ├── ai-vm           192.168.1.10   RTX 4090 passthrough
│   │   ├── Ollama          :11434   LLM inference engine
│   │   ├── Open WebUI      :3000    Chat interface
│   │   ├── AnythingLLM     :3001    RAG / document Q&A
│   │   ├── Qdrant          :6333    Vector database
│   │   ├── Whisper         :8000    Speech-to-text API
│   │   └── Nginx           :80/:443 Reverse proxy
│   │
│   ├── coding-vm       192.168.1.20
│   │   └── OpenCode / Continue  (connects to Ollama on ai-vm)
│   │
│   ├── data-vm         192.168.1.30
│   │   ├── PostgreSQL 16 + pgvector  :5432
│   │   └── pgAdmin                   :5050
│   │
│   ├── automation-vm   192.168.1.40
│   │   ├── n8n         :5678   Workflow automation
│   │   └── Flowise     :3002   Visual LLM pipelines
│   │
│   └── monitoring-vm   192.168.1.50
│       ├── Grafana     :3003   Dashboards
│       └── Prometheus  :9090   Metrics collection
│
└── LXC Layer  (lightweight containers — business services)
    ├── Phase 1   Infrastructure  (Docker, Redis, Nginx Proxy Manager)
    ├── Phase 4   Business/ERP   (Odoo, Invoice Ninja, Monica CRM)
    ├── Phase 5   Documents      (Paperless-ngx, BookStack, Outline)
    ├── Phase 6   Communication  (Mattermost, Element)
    ├── Phase 9   Security       (Keycloak SSO, Authelia)
    └── Phase 10  Dev/Code       (Forgejo, Jenkins, SonarQube)
```

### Design Decisions

| Decision | Reason |
|---|---|
| VMs for AI workloads | PCIe passthrough requires QEMU — LXC cannot access a GPU |
| Ubuntu 24.04 (Noble) cloud image | LTS with cloud-init support and a recent kernel |
| Postgres on a dedicated VM | Shared by n8n, Flowise, AnythingLLM, and LXC business apps |
| Static IPs for VMs | Predictable addressing; services reference each other by IP |
| LXC for business apps | Lower overhead, faster boot, community-scripts ecosystem |
| VMID range split | VMs: 200–204 · LXC: 400–499 — no collision |

---

## Prerequisites

### Hardware

| Component | Minimum | Recommended |
|---|---|---|
| CPU | 8 cores (VT-d or AMD-Vi required) | 16+ cores |
| RAM | 64 GB | 128 GB |
| Storage | 500 GB SSD | 1 TB NVMe |
| GPU | NVIDIA RTX (any with VFIO support) | RTX 4090 24 GB |

### Software

- Proxmox VE 8.x running on bare metal
- Root SSH access to the Proxmox host
- Internet connectivity (scripts download images and packages)

### Local machine (where you run deployments from)

- SSH key pair: `ssh-keygen -t ed25519 -C "proxmox-ai"`
- `scp` available (standard on macOS and Linux)

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/yourname/proxmox-ai-stack.git
cd proxmox-ai-stack

# 2. Edit network settings and paste your SSH public key
nano proxmox-ai-stack/config.env

# 3. Generate secrets once — writes static values back into config.env
bash proxmox-ai-stack/host/init-secrets.sh

# 4. Copy the entire directory to the Proxmox host
scp -r . root@<proxmox-ip>:/root/proxmox-ai-stack/

# 5. SSH into the Proxmox host and run
ssh root@<proxmox-ip>
cd /root/proxmox-ai-stack

bash proxmox-ai-stack/host/setup-gpu.sh   # configure VFIO, then reboot
# --- reboot ---
bash proxmox-ai-stack/host/create-vms.sh  # provision all 5 VMs
bash proxmox-ai-stack/host/deploy-all.sh  # install services on every VM
```

Total time: approximately 20–30 minutes (dominated by package and model downloads).

---

## Configuration Reference

All configuration lives in **`config.env`**. Edit this file before running any scripts.

### Network

| Variable | Default | Description |
|---|---|---|
| `BRIDGE` | `vmbr0` | Proxmox network bridge |
| `GATEWAY` | `192.168.1.1` | Default gateway (your router) |
| `NAMESERVER` | `1.1.1.1` | DNS resolver used by VMs |
| `SUBNET_MASK` | `24` | CIDR prefix length |

### VM IP Addresses

| Variable | Default | VM |
|---|---|---|
| `AI_VM_IP` | `192.168.1.10` | AI workloads + Ollama |
| `CODING_VM_IP` | `192.168.1.20` | OpenCode / Continue |
| `DATA_VM_IP` | `192.168.1.30` | PostgreSQL + pgAdmin |
| `AUTOMATION_VM_IP` | `192.168.1.40` | n8n + Flowise |
| `MONITORING_VM_IP` | `192.168.1.50` | Grafana + Prometheus |

All five IPs must be outside your DHCP pool and reachable from the Proxmox host.

### VM Resources

| VM | RAM (MB) | CPU Cores | Disk (GB) |
|---|---|---|---|
| `ai-vm` | 32768 | 12 | 120 |
| `coding-vm` | 8192 | 4 | 60 |
| `data-vm` | 16384 | 4 | 150 |
| `automation-vm` | 8192 | 4 | 60 |
| `monitoring-vm` | 4096 | 2 | 40 |

### Cloud Image

To switch Ubuntu versions, update these two variables in `config.env`:

```bash
# Ubuntu 22.04 LTS (Jammy Jellyfish)
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
CLOUD_IMAGE_NAME="jammy-server-cloudimg-amd64.img"

# Ubuntu 24.04 LTS (Noble Numbat) — recommended
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
CLOUD_IMAGE_NAME="noble-server-cloudimg-amd64.img"
```

### Secrets

Secrets are intentionally left blank in `config.env` and populated by `init_secrets.sh`. Never assign them with inline `$(openssl rand ...)` — that regenerates a new value every time the file is sourced.

```bash
bash init_secrets.sh   # run once; safe to re-run (skips existing values)
```

| Variable | Purpose |
|---|---|
| `POSTGRES_PASSWORD` | PostgreSQL superuser password |
| `ANYTHINGLLM_JWT_SECRET` | AnythingLLM session signing key |
| `N8N_ENCRYPTION_KEY` | n8n credential encryption key |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password (default: `admin`) |

---

## Deployment Guide

### Step 1 — Edit `config.env`

```bash
nano config.env
```

Required changes:
- `GATEWAY` — your router's IP address
- `AI_VM_IP` through `MONITORING_VM_IP` — five available static IPs on your LAN
- `SSH_PUBLIC_KEY` — output of `cat ~/.ssh/id_ed25519.pub`
- `STORAGE` — verify the correct pool name with `pvesm list` on the Proxmox host

### Step 2 — Initialise secrets

```bash
bash init_secrets.sh
```

### Step 3 — GPU passthrough (Proxmox host)

```bash
bash 00_gpu_passthrough.sh
reboot
```

After reboot, verify the GPU is bound to VFIO:

```bash
lspci -nnk | grep -A3 -i "RTX 4090"
# Kernel driver in use: vfio-pci   <- correct
```

### Step 4 — Create VMs (Proxmox host)

```bash
bash 01_create_vms.sh
```

Downloads the Ubuntu cloud image once, creates five VMs with cloud-init networking, and starts them. Wait approximately 60 seconds for cloud-init to complete, then test SSH:

```bash
ssh ubuntu@192.168.1.10
```

### Step 5 — Deploy all services

```bash
bash deploy_all.sh
```

Deploys in dependency order: `data → ai → automation → monitoring → coding`. Individual VM failures are logged and skipped; all VMs are always attempted. A summary table prints at the end.

### Deploying a single VM independently

```bash
bash deploy_vm.sh coding           # deploy only coding-vm
bash deploy_vm.sh ai               # redeploy ai-vm
bash deploy_vm.sh data --dry-run   # preview without executing
bash deploy_vm.sh ai --no-wait     # skip SSH readiness check
```

### Running setup manually from inside a VM

```bash
# On Proxmox host — generate the export block for a specific VM
bash export_env.sh ai

# Copy the printed output, paste it into the VM terminal, then:
sudo -E bash ~/ai-vm/setup.sh
```

---

## Service Catalog

### AI VM (`192.168.1.10`)

| Service | Port | Description |
|---|---|---|
| Ollama | 11434 | LLM inference. Serves all models to other VMs and containers |
| Open WebUI | 3000 | Chat UI with RAG, voice input, and model management |
| AnythingLLM | 3001 | Document Q&A workspace backed by Qdrant + Postgres |
| Qdrant | 6333 | Vector store used by AnythingLLM for embeddings |
| Whisper | 8000 | OpenAI-compatible STT API running `large-v3` on GPU |
| Nginx | 80/443 | Reverse proxy for `chat.*`, `docs.*`, `ollama.*` subdomains |
| node-exporter | 9100 | Prometheus system metrics endpoint |
| nvidia-exporter | 9445 | Prometheus GPU metrics endpoint |

**Recommended models:**

```bash
docker exec ollama ollama pull qwen2.5-coder:32b   # coding
docker exec ollama ollama pull deepseek-r1:32b      # reasoning
docker exec ollama ollama pull nomic-embed-text     # embeddings (required for RAG)
docker exec ollama ollama pull llava:34b            # vision / multimodal
docker exec ollama ollama pull qwen2.5-coder:1.5b  # tab autocomplete
```

### Data VM (`192.168.1.30`)

| Service | Port | Description |
|---|---|---|
| PostgreSQL 16 | 5432 | Shared database server with pgvector extension |
| pgAdmin 4 | 5050 | Web-based Postgres management |
| node-exporter | 9100 | Prometheus metrics |

**Databases created at install:** `postgres`, `anythingllm`, `n8n`, `app_db`

### Automation VM (`192.168.1.40`)

| Service | Port | Description |
|---|---|---|
| n8n | 5678 | Workflow automation. Timezone: Asia/Dhaka. Backed by Postgres |
| Flowise | 3002 | Drag-and-drop LLM pipeline builder. Backed by Postgres |
| node-exporter | 9100 | Prometheus metrics |

### Monitoring VM (`192.168.1.50`)

| Service | Port | Description |
|---|---|---|
| Grafana | 3003 | Dashboards. Default login: `admin` / `config.env` value |
| Prometheus | 9090 | Metrics collector scraping all five VMs |
| Alertmanager | 9093 | Alert routing (pre-installed, configure rules as needed) |

**Grafana dashboard IDs to import** (Dashboards → New → Import):

| ID | Dashboard |
|---|---|
| 1860 | Node Exporter Full |
| 14574 | NVIDIA GPU Metrics |
| 893 | Docker Container Metrics |
| 3662 | Prometheus Overview |

### Coding VM (`192.168.1.20`)

| Tool | Config | Notes |
|---|---|---|
| OpenCode | `~/.config/opencode/config.json` | Uses `qwen2.5-coder:32b` via Ollama on ai-vm |
| Continue | `~/.continue/config.json` | VS Code / JetBrains extension |

---

## LXC Integration

See [docs/lxc-integration.md](./docs/lxc-integration.md) for full details.

```bash
bash deploy_lxc_stack.sh --phase 4    # Business / ERP
bash deploy_lxc_stack.sh --phase 9    # Security / SSO
bash wire_lxc_to_vms.sh               # Point LXC containers at VM services
```

---

## Troubleshooting

See [docs/troubleshooting.md](./docs/troubleshooting.md) for a full troubleshooting guide.

**Quick reference:**

| Problem | Fix |
|---|---|
| GPU not visible in ai-vm | `lspci -nnk` on host — should show `vfio-pci`; re-run `00_gpu_passthrough.sh` if not |
| Secrets change on every run | Run `bash init_secrets.sh` to make them static |
| NVIDIA Toolkit GPG fails over SSH | Fixed in current `ai-vm/setup.sh` via `--batch --no-tty` |
| VM deployment failed | `bash deploy_vm.sh <name>` to retry just that VM |
| n8n cannot reach Postgres | Check UFW on data-vm; `automation-vm` IP must be allowed on port 5432 |

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## License

MIT — see [LICENSE](./LICENSE).
