# Troubleshooting

---

## GPU Passthrough

### GPU not visible inside ai-vm

**Symptom:** `nvidia-smi` inside ai-vm returns `No devices found` or the command is missing.

**Diagnosis:**

```bash
# On Proxmox host — verify VFIO is bound, not the host NVIDIA driver
lspci -nnk | grep -A3 -i "RTX 4090"
# Good:  Kernel driver in use: vfio-pci
# Bad:   Kernel driver in use: nvidia
```

```bash
# Confirm IOMMU is active in kernel
dmesg | grep -i iommu | head -10
# Should contain: IOMMU enabled  or  AMD-Vi: ...
```

```bash
# Confirm the VM has the PCI device configured
qm config 200 | grep hostpci
# Expected: hostpci0: 0000:01:00.0,pcie=1,x-vga=1
```

**Fix:**

```bash
# Re-run GPU passthrough setup on the host
bash 00_gpu_passthrough.sh
reboot

# After reboot, verify, then recreate the VM if needed
bash 01_create_vms.sh
```

If the GPU still shows the wrong driver after reboot, check that the `blacklist-nvidia.conf` file was written correctly:

```bash
cat /etc/modprobe.d/blacklist-nvidia.conf
cat /etc/modprobe.d/vfio.conf
```

---

## NVIDIA Container Toolkit

### GPG error during installation

**Symptom:**
```
gpg: cannot open '/dev/tty': No such device or address
curl: (23) Failed writing body
```

**Cause:** The `gpg --dearmor` pipe variant tries to open `/dev/tty` for a passphrase prompt. This device is not available in non-interactive SSH sessions.

**Fix** (already applied in `ai-vm/setup.sh`):

```bash
# Save the key to a temp file first, then dearmor with --batch --no-tty
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey > /tmp/nvidia-key.asc
gpg --batch --yes --no-tty \
    --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    /tmp/nvidia-key.asc
rm -f /tmp/nvidia-key.asc
```

If you encounter the same pattern with other apt repository keys, apply the same workaround.

---

## Secrets and Configuration

### Postgres password changes on every run

**Cause:** `config.env` had secrets defined as `$(openssl rand ...)`. This re-executes the command every time the file is sourced, generating a new value each time.

**Fix:**

```bash
bash init_secrets.sh
```

This generates values once and writes them as static strings into `config.env`. Re-running the script is safe — it never overwrites a value that is already set.

**Verify** the secrets are now static:

```bash
grep POSTGRES_PASSWORD config.env
# Expected: POSTGRES_PASSWORD="a3f8c..."   (a fixed hex string)
# Bad:      POSTGRES_PASSWORD="$(openssl rand -hex 16)"
```

### Secrets are empty after sourcing config.env

If `init_secrets.sh` was never run, all secret variables will be empty strings. The setup scripts guard against this:

```bash
# ai-vm/setup.sh will exit immediately with:
ERROR: Secrets are empty. Run  bash init_secrets.sh  first.
```

Run `bash init_secrets.sh` from the repo root before any deployment.

---

## VM Deployment

### SSH timeout during deployment

**Symptom:** `deploy_all.sh` or `deploy_vm.sh` prints repeated "not ready" messages and eventually times out.

**Cause:** The VM has not finished cloud-init, or the IP is unreachable (wrong static IP, firewall, etc.).

**Diagnosis:**

```bash
# From Proxmox host, open the VM's console
qm terminal 200

# Inside the VM, check cloud-init status
cloud-init status
# Expected: status: done

# Check the assigned IP
ip addr show
```

**Fix options:**

```bash
# Option 1: Wait longer (increase MAX in deploy_vm.sh or deploy_all.sh, default 36 x 5s = 3 min)

# Option 2: If VM is already up but SSH is just slow
bash deploy_vm.sh ai --no-wait

# Option 3: Deploy manually (SSH in yourself, then run)
ssh ubuntu@192.168.1.10
sudo -E bash ~/ai-vm/setup.sh
```

### VM already exists error

**Symptom:** `01_create_vms.sh` prints `VM 200 already exists — skipping`.

**This is expected behaviour** — the script is idempotent. If you need to recreate a VM from scratch:

```bash
qm stop 200
qm destroy 200
bash 01_create_vms.sh
```

### A single VM deployment failed — redeploy only that VM

```bash
bash deploy_vm.sh ai           # retry ai-vm
bash deploy_vm.sh data         # retry data-vm
bash deploy_vm.sh automation   # retry automation-vm
bash deploy_vm.sh monitoring   # retry monitoring-vm
bash deploy_vm.sh coding       # retry coding-vm
```

---

## Service-Specific Issues

### Ollama runs out of VRAM / is slow

```bash
# SSH into ai-vm, check what models are currently loaded
docker exec ollama ollama ps

# Unload a model manually
docker exec ollama ollama stop <model-name>
```

To limit to one model loaded at a time, add to `ai-vm/docker-compose.yml` under `ollama → environment`:

```yaml
OLLAMA_MAX_LOADED_MODELS: "1"
```

Then restart:

```bash
docker compose -f /opt/ai-stack/docker-compose.yml restart ollama
```

### n8n cannot connect to Postgres

```bash
# From automation-vm, test port reachability
nc -zv 192.168.1.30 5432

# Check data-vm firewall — automation-vm IP must be allowed
ssh ubuntu@192.168.1.30 "sudo ufw status numbered"

# If the rule is missing, add it on data-vm
ssh ubuntu@192.168.1.30 "sudo ufw allow from 192.168.1.40 to any port 5432"
```

### Whisper takes too long to start

On first start, the `large-v3` model (~3 GB) downloads before the API becomes available. This is normal. Check progress:

```bash
docker logs -f whisper
```

If you want a faster-starting alternative, change the model in `ai-vm/docker-compose.yml`:

```yaml
WHISPER__MODEL: medium   # or small, base
```

### Grafana shows no data / targets are down

```bash
# On monitoring-vm, check Prometheus target status
# Open in browser: http://192.168.1.50:9090/targets

# Or check from CLI
curl -s http://192.168.1.50:9090/api/v1/targets | python3 -m json.tool | grep health
```

If targets show `DOWN`, verify `node-exporter` is running on each VM:

```bash
ssh ubuntu@192.168.1.10 "docker ps | grep node-exporter"
```

---

## LXC Containers

### LXC container cannot reach Ollama or Postgres

LXC containers and VMs share `vmbr0` and can reach each other by IP directly. If a container cannot reach a VM:

```bash
# From inside the LXC container
pct exec <CTID> -- ping 192.168.1.10

# If ping fails, check the container's network config
pct config <CTID> | grep net
```

Ensure the container has a valid IP on the same subnet as your VMs, or verify `vmbr0` is the correct bridge.

### wire_lxc_to_vms.sh patched a config but the service still uses the old value

Patching config files takes effect on next service restart. After running `wire_lxc_to_vms.sh`:

```bash
# Restart the affected container
pct restart <CTID>

# Or restart only the service inside the container
pct exec <CTID> -- systemctl restart <service-name>
```

### LXC deployer skips a service unexpectedly

The deploy state file at `/root/.proxmox-ai-deploy-state` records every successfully deployed service. If a service name appears in that file, the deployer skips it.

```bash
# View the state file
cat /root/.proxmox-ai-deploy-state

# Remove a specific entry to allow redeployment
sed -i '/^flowise$/d' /root/.proxmox-ai-deploy-state

# Reset everything (redeploy from scratch)
rm /root/.proxmox-ai-deploy-state
```
