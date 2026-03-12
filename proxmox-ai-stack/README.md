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
│   ├── setup-gpu.sh        ← GPU passthrough setup + reboot
│   ├── init-secrets.sh     ← generate passwords (run once)
│   ├── create-template.sh  ← build reusable VM template (optional)
│   ├── create-vms.sh       ← provision all 5 VMs
│   ├── deploy-all.sh       ← deploy all VM services
│   ├── deploy-vm.sh        ← deploy a single VM
│   └── export-env.sh       ← source config into shell
├── vms/                ← deployed TO each VM via SSH
│   ├── common/         ← shared bootstrap (runs on every VM)
│   ├── ai/             ← AI VM: Ollama, Open WebUI, 15 services
│   │   ├── setup.sh          ← orchestrator
│   │   ├── install-nvidia.sh ← NVIDIA driver + container toolkit
│   │   ├── install-docker.sh ← Docker CE + Compose
│   │   └── generate-compose.sh ← writes docker-compose.yml
│   ├── coding/         ← Coding VM: OpenCode + Continue IDE
│   ├── data/           ← Data VM: Postgres + pgAdmin
│   ├── automation/     ← Automation VM: n8n + Flowise
│   └── monitoring/     ← Monitoring VM: Grafana + Prometheus
└── lxc/                ← optional: 60+ extra LXC containers
    ├── deploy-stack.sh ← entry point (interactive or --all/--phase N)
    ├── wire-to-vms.sh  ← connect LXC containers to VM services
    └── apps.sh         ← 60+ app definitions across 10 phases
```

## Quick Start

### 1. Configure

```bash
nano proxmox-ai-stack/config.env          # set SSH key, IPs, storage, bridge
bash proxmox-ai-stack/host/init-secrets.sh  # generate passwords once
```

### 2. GPU passthrough (Proxmox host, then reboot)

```bash
bash proxmox-ai-stack/host/setup-gpu.sh
reboot
```

### 3. Create VMs

```bash
# Direct import (default)
bash proxmox-ai-stack/host/create-vms.sh

# Template-based (faster for rebuilds — run create-template.sh once first)
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
bash proxmox-ai-stack/lxc/deploy-stack.sh             # interactive menu
bash proxmox-ai-stack/lxc/deploy-stack.sh --all       # deploy everything
bash proxmox-ai-stack/lxc/deploy-stack.sh --phase 4   # one phase
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
cat /opt/ai-stack/mcpo-api-key.txt            # retrieve MCPO API key
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) and [docs/lxc-integration.md](docs/lxc-integration.md).
