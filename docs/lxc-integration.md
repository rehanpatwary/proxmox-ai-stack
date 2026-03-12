# LXC Integration

LXC containers provide lightweight, fast-booting environments for business services that do not require a GPU. They run on the same Proxmox host as the QEMU VMs and share the same `vmbr0` bridge, so they can reach VM services directly by IP.

---

## Layer Separation

| Layer | Technology | Used for |
|---|---|---|
| QEMU VMs (200–204) | KVM / PCIe passthrough | Ollama inference, Postgres, n8n, monitoring — anything requiring GPU, isolated storage, or full kernel |
| LXC containers (400–499) | Linux Containers | ERP, CRM, document management, SSO, Git hosting, communication — stateless or low-resource services |

---

## VMID Allocation

| Range | Layer | Notes |
|---|---|---|
| 200–204 | QEMU VMs | ai, coding, data, automation, monitoring |
| 400–499 | LXC containers | community-scripts managed |

The LXC deployer starts at VMID 400 by default (`START_VMID` in `config.env`). It automatically finds the next free ID if one is already in use.

---

## Available Phases

| Phase | Category | Key Services |
|---|---|---|
| 1 | Infrastructure | Docker, Redis, MariaDB, Nginx Proxy Manager, Vaultwarden, WireGuard |
| 2 | AI and LLM | *(skipped — handled by VMs)* |
| 3 | Automation | Node-RED, Semaphore, Coolify, Cronicle |
| 4 | Business and Finance | Odoo ERP, Invoice Ninja, Firefly III, Monica CRM, OpenProject, Kimai |
| 5 | Documents and Knowledge | Paperless-ngx, Paperless-AI, BookStack, Outline, Stirling PDF, Trilium |
| 6 | Communication | Mattermost, Listmonk, Element + Matrix, ntfy |
| 7 | Monitoring | *(skipped — handled by monitoring-vm)* |
| 8 | Workspace and Storage | Nextcloud, MinIO, Syncthing, Duplicati |
| 9 | Security and Identity | Keycloak SSO, Authelia, Headscale, BunkerWeb WAF |
| 10 | Dev and Code | Forgejo, Jenkins, Dockge, SonarQube, IT Tools |

Phases 2 and 7 are automatically skipped because those services already run in your VMs (`ollama`, `open-webui`, `grafana`, `prometheus`, etc. are pre-marked as deployed).

---

## Deployment

### Interactive deployment (recommended first time)

```bash
bash deploy_lxc_stack.sh
```

Presents a menu to deploy all, by phase, or a single app.

### Deploy a specific phase

```bash
bash deploy_lxc_stack.sh --phase 4    # Business / Finance
bash deploy_lxc_stack.sh --phase 5    # Documents / Knowledge
bash deploy_lxc_stack.sh --phase 9    # Security / SSO
bash deploy_lxc_stack.sh --phase 10   # Dev / Code
```

### Preview without making changes

```bash
bash deploy_lxc_stack.sh --dry-run
```

### Check deployment status

```bash
bash deploy_lxc_stack.sh --status
```

Shows which containers are deployed and running, with access IPs where available.

---

## What `deploy_lxc_stack.sh` Does

The wrapper script performs three actions before handing off to the community-scripts deployer:

**1. Pre-marks VM-deployed services**

Writes service names already running in VMs into the deploy state file (`/root/.proxmox-ai-deploy-state`). The LXC deployer reads this file and skips any service listed in it:

```
ollama, open-webui, flowise, n8n, grafana, prometheus, postgresql, qdrant, loki
```

**2. Exports VM endpoints as environment variables**

Community scripts read these during setup to configure service connections:

```bash
OLLAMA_BASE_URL=http://192.168.1.10:11434
DATABASE_HOST=192.168.1.30
DATABASE_PASSWORD=<from config.env>
GRAFANA_URL=http://192.168.1.50:3003
```

**3. Passes network config from `config.env`**

Bridge, gateway, storage, and starting VMID flow through automatically. No need to reconfigure the LXC deployer separately.

---

## Post-Deploy Wiring

Many community-script containers write their configuration to files at install time, ignoring runtime environment variables. `wire_lxc_to_vms.sh` execs into each container after deployment and patches the config files directly.

```bash
# Preview what would be patched
bash wire_lxc_to_vms.sh --dry-run

# Apply patches
bash wire_lxc_to_vms.sh

# Restart affected containers
pct restart <CTID>
```

### Services wired automatically

| Container | Patched config | Connected to |
|---|---|---|
| Paperless-AI | `.env` | Ollama on ai-vm |
| Monica CRM | `.env` + `artisan config:cache` | Postgres on data-vm |
| BookStack | `.env` + `artisan config:cache` | Postgres on data-vm |
| Outline | `.env` | Postgres on data-vm |
| Mattermost | `config.json` | Postgres on data-vm |
| Keycloak | `keycloak.conf` | Postgres on data-vm |

The script also creates any missing Postgres databases on `data-vm` and prints the Nginx Proxy Manager routing table.

---

## Nginx Proxy Manager Routing

After deploying `nginx-proxy` (Phase 1), configure these proxy hosts in the NPM admin UI (`http://<npm-ip>:81`, default login `admin@example.com` / `changeme`):

| Domain | Forward to | Notes |
|---|---|---|
| `chat.yourdomain.com` | `192.168.1.10:3000` | Open WebUI |
| `docs.yourdomain.com` | `192.168.1.10:3001` | AnythingLLM |
| `ollama.yourdomain.com` | `192.168.1.10:11434` | Ollama API (restrict access) |
| `n8n.yourdomain.com` | `192.168.1.40:5678` | n8n |
| `flowise.yourdomain.com` | `192.168.1.40:3002` | Flowise |
| `grafana.yourdomain.com` | `192.168.1.50:3003` | Grafana |
| `db.yourdomain.com` | `192.168.1.30:5050` | pgAdmin (restrict to internal IPs) |

Enable "Websockets Support" for Open WebUI, AnythingLLM, n8n, and Flowise.

---

## Keycloak SSO Integration

After deploying Keycloak (Phase 9), you can add single sign-on for Open WebUI, Flowise, n8n, and Grafana.

Open WebUI SSO:

```yaml
# Add to ai-vm docker-compose.yml under open-webui environment:
OAUTH_CLIENT_ID: openwebui
OAUTH_CLIENT_SECRET: <keycloak-client-secret>
OPENID_PROVIDER_URL: http://<keycloak-ip>:8080/realms/master/.well-known/openid-configuration
```

Grafana SSO:

```ini
# Add to grafana environment in monitoring docker-compose.yml:
GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<keycloak-client-secret>
GF_AUTH_GENERIC_OAUTH_AUTH_URL=http://<keycloak-ip>:8080/realms/master/protocol/openid-connect/auth
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=http://<keycloak-ip>:8080/realms/master/protocol/openid-connect/token
```
