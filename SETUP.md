# Environment Setup Log

A record of every setup step taken, what went wrong, and how it was fixed.
Useful reference if the VM is rebuilt or settings are lost.

---

## Session 1 — Day 1 Setup (2026-02-03)

### Goal
Get an OpenShift cluster running locally for the 30-day lab.

### What was planned vs what happened

**Planned**: CentOS Stream 9 VM with OpenShift Local (CRC)
**Actual**: Ubuntu 22.04 LTS VM on Hyper-V

### Step 1 — SSH Access

The VM was running but had no SSH key configured.
Added the Windows host's public key (`~/.ssh/id_rsa.pub`) via `ssh-copy-id`:

```bash
ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@172.27.134.44
```

### Step 2 — VM Resource Assessment

Initial VM specs were insufficient for CRC:

| Resource | Initial | Required | Fix |
|----------|---------|----------|-----|
| RAM | 4.7 GB | 9 GB min | Increased to 14 GB |
| Disk | 12 GB / 5.3 GB free | 35 GB min | Expanded VHD to 80 GB |
| Nested virt | Disabled | Required for KVM | Enabled via Hyper-V |

### Step 3 — Resize via Hyper-V (PowerShell as Admin)

```powershell
# Must run as Administrator
Set-VMProcessor -VMName "Ubuntu 22.04 LTS" -ExposeVirtualizationExtensions $true
Set-VMMemory -VMName "Ubuntu 22.04 LTS" -DynamicMemoryEnabled $false -StartupBytes 14GB
Resize-VHD -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\Ubuntu 22.04 LTS (1).vhdx" -SizeBytes 80GB
Start-VM -Name "Ubuntu 22.04 LTS"
```

**Gotcha**: Hyper-V Dynamic Memory was enabled, causing the VM to only use ~4.8 GB at runtime
despite StartupBytes being set to 14 GB. Fix: disable dynamic memory (`-DynamicMemoryEnabled $false`).

### Step 4 — Expand Partition Inside VM

After VHD resize, the partition still showed 12 GB. Required manual grow:

```bash
sudo apt-get install -y cloud-guest-utils
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
```

Result: `/dev/sda1` grew from 12 GB → 78 GB usable.

### Step 5 — Install Prerequisites on VM

```bash
sudo apt-get update
sudo apt-get install -y qemu-kvm libvirt-daemon libvirt-daemon-system network-manager curl
sudo usermod -aG libvirt ubuntu
```

### Step 6 — Install CRC

Red Hat account not available → used **OKD preset** (no pull secret required).

```bash
# Download CRC binary
cd /tmp
curl -L -o crc.tar.xz \
  https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/crc/2.58.0/crc-linux-amd64.tar.xz
tar -xf crc.tar.xz
sudo mv crc-linux-*/crc /usr/local/bin/crc

# Configure for OKD (no pull secret needed)
crc config set preset okd
crc config set memory 12288
crc config set cpus 4

# Run setup (downloads ~4 GB OKD bundle)
crc setup

# Start cluster (~15 minutes)
crc start
```

### Step 7 — Link oc CLI

CRC installs `oc` in the cache directory, not in PATH:

```bash
sudo ln -sf ~/.crc/cache/crc_okd_libvirt_4.20.0-okd-scos.11_amd64/oc /usr/local/bin/oc
```

### Cluster Credentials

| User | Password | Access |
|------|----------|--------|
| kubeadmin | `WD2J7-fZZr9-XFXIn-qxDvg` | Cluster admin |
| developer | `developer` | Project-level developer |

**Note**: These credentials are regenerated each time `crc delete` + `crc start` is run.
After `crc stop` + `crc start`, credentials are preserved.

### Final VM State

```
RAM:   16 GB (fixed)
Disk:  78 GB usable / ~72 GB free
CPUs:  6 vCPUs, nested virt enabled
OKD:   4.20.0-okd-scos.11
oc:    4.20.0-okd-scos.11
CRC:   2.58.0+275f36
```

---

## Useful Troubleshooting Commands

```bash
# Check cluster status
crc status

# If cluster won't start, check logs
journalctl -u crc -f

# Check libvirt VMs
virsh list --all

# Check if nested virt is active
grep -c 'vmx\|svm' /proc/cpuinfo   # should be > 0

# Check available RAM
free -h

# Restart the cluster after VM reboot
crc start
```
