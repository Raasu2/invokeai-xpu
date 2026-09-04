# invokeai-xpu
InvokeAI running on Intel Arc GPUs using native PyTorch XPU support, deployed headlessly on Ubuntu LXC/VM with systemd.

## InvokeAI on Intel GPU (XPU, no CUDA)

This is a single-script installer for running InvokeAI on Intel GPUs using **native XPU support** (introduced in InvokeAI 6.14).

Just: run InvokeAI on Intel GPU with one script.

**Disclaimer:** purely vibecoded.
---

## Why this script exists

I have an Intel Arc B50 Pro and wanted InvokeAI to work on it. Since InvokeAI 6.14 added native `torch.xpu` device support, all the custom patches, workarounds, and manual torch pinning are no longer needed.

This script captures the essentials in one reproducible installer:
- ✅ Native `torch.xpu` backend
- ✅ Headless, systemd-managed, browser UI accessible
- ✅ Pre-flight checks for Ubuntu version and kernel
- ✅ Installs Intel compute runtime from Intel's repo (25.40+ for Battlemage stability)
- ✅ Works on Proxmox LXC **and** VM (GPU passthrough)
- ✅ Uses `uv` with `--torch-backend=xpu` — gets correct torch+xpu automatically

---

## What this script does

The installer (`install-invokeai-xpu-proxmox.sh`) performs:

### Pre-flight
- Checks Ubuntu version (24.04, 25.04, 25.10, 26.04)
- Checks kernel version (≥ 6.14 required for Battlemage)
- Verifies `/dev/dri/renderD*` access inside LXC/VM

### System & GPU
- Adds Intel GPU repo
- Removes stale Ubuntu compute runtime (24.x — known BMG crash)
- Installs Intel GPU userspace from Intel's repo:
  - Level Zero (`libze1`, `libze-intel-gpu1`)
  - OpenCL ICD (`intel-opencl-icd`)
  - Compiler/runtime (`intel-igc-cm`, `intel-gsc`)

### Python & InvokeAI
- Installs `uv` (Astral's fast Python package manager)
- Creates relocatable venv at `/opt/invokeai-xpu` with uv-managed Python 3.12
- Installs `invokeai[xpu]==6.14.0` via `uv pip install --torch-backend=xpu`
- Verifies `torch.xpu.is_available()` and device detection

### Runtime
- Writes minimal `invokeai.yaml` (device: xpu, bfloat16, lazy_offload)
- Creates optional VRAM override at `/etc/invokeai/invokeai-xpu.env`
- Creates systemd service with Intel XPU env vars
- Includes BMG stability workarounds (`NEOReadDebugKeys=1`, `RenderCompressedBuffersEnabled=0`)
- Starts service on boot, logs to journal

### End result
InvokeAI runs on Intel GPU, images generate successfully, UI accessible at `http://<IP>:9090`.

---

## Requirements

### Proxmox Host
- Intel GPU (Arc Alchemist A-series, Battlemage B-series)
- i915/Xe kernel driver loaded
- GPU passed through to LXC **or** VM

#### LXC Container Config (`/etc/pve/lxc/<id>.conf`):
```bash
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:129 rwm
lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD129 dev/dri/renderD129 none bind,optional,create=file
```
⚠️ Device numbers may change. Verify with `ls -l /dev/dri` on host.

#### VM (PCI Passthrough)
- Add GPU as PCI device in VM hardware config
- Ensure `vfio-pci` driver binds on host

---

### LXC Container / VM
- Ubuntu 24.04, 25.04, 25.10, or 26.04
- Kernel 6.14+ (Ubuntu 24.04: install `linux-generic-hwe-24.04`)
- Fresh install recommended
- Internet access
- Privileged container (LXC) or standard VM

---

## Quick Start

```bash
git clone https://github.com/Raasu2/invokeai-xpu.git
cd invokeai-xpu
chmod +x install-invokeai-xpu-proxmox.sh
sudo bash install-invokeai-xpu-proxmox.sh
```

That's it. Wait for completion, then open `http://<VM-IP>:9090`.

---

## Configuration

All settings are at the top of `install-invokeai-xpu-proxmox.sh`:

```bash
VENV_DIR="/opt/invokeai-xpu"        # Virtual environment location
INVOKE_ROOT="/data/invokeai"        # InvokeAI root directory (models, outputs)
PORT="9090"                         # Web UI port
SERVICE_NAME="invokeai.service"     # systemd unit name
INVOKEAI_XPU_VRAM_TOTAL_GB="16"     # VRAM override (for passthrough VMs)
SERVICE_USER="root"                 # Service user (change to dedicated user if desired)
INVOKE_VER="6.14.0"                 # InvokeAI version
```

### VRAM Override
For GPU passthrough VMs where driver-global VRAM query (Sysman) may not work, set:
```bash
INVOKEAI_XPU_VRAM_TOTAL_GB="16"  # Match your GPU's VRAM
```

### Non-root Service User
```bash
# Before running installer:
useradd -r -s /bin/false invokeai
# Then set in script:
SERVICE_USER="invokeai"
```

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| `/dev/dri` missing | GPU not passed through to LXC/VM |
| Kernel too old | Install HWE kernel or upgrade Ubuntu |
| `torch.xpu.is_available()` false | Level Zero packages missing |
| OOM on generation | Increase `INVOKEAI_XPU_VRAM_TOTAL_GB` |
| Service won't start | `journalctl -u invokeai.service -f` |
| SIGABRT in `command_encoder` | Stale compute runtime — re-run installer to upgrade from Intel repo |
| `patchmatch` warning | Non-fatal, does not affect generation |

---

## Thanks / Credits

- **InvokeAI team** — Native XPU support (PR #9401)
- **LexiconCode** — Primary author of native XPU backend
- **MordragT** — Original XPU patches that paved the way
- **Astral** — `uv` package manager

---

## License
MIT
