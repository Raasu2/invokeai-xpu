# invokeai-xpu
InvokeAI running on Intel Arc GPUs using PyTorch XPU (Level Zero), deployed headlessly on Ubuntu 24.04 LXC with systemd.

## InvokeAI on Intel GPU (XPU, no CUDA)

This repo is basically a “what finally worked” script for running InvokeAI on Intel GPUs using PyTorch XPU on Ubuntu 24.04 inside a Proxmox LXC.

No CUDA.  
No Docker.  
No fancy setup.

Just: make InvokeAI run on Intel GPU without fighting it for days.

**Disclaimer:** this is purely vibecoded.

---

## Why this repo exists

I have an Intel Arc B50 and too much free time. I like how easy InvokeAI is to use and wanted to see if I could make it work with the Arc.

After a long debugging session, this script captures everything that was needed, in the order required to actually get it working:

- PyTorch XPU
- InvokeAI 6.12
- Intel Arc / Intel XPU
- Headless Ubuntu 24.04
- Proxmox LXC

So this is:

- ✅ A reproducible install that runs InvokeAI on Intel XPU
- ✅ Headless, systemd-managed, browser UI accessible
- ✅ Tested on Intel Arc B50
- ✅ Can also work on direct Ubuntu installs (non-LXC)
- ❌ Not optimized
- ❌ Not officially supported
- ❌ Not guaranteed to survive future InvokeAI releases

---

## What this script does

The install script (`install-invoke-xpu.sh`) performs the following:

### System & GPU
- Installs Intel GPU userspace:
  - Level Zero
  - OpenCL ICD
  - Media drivers
- Verifies `/dev/dri/renderD*` access inside LXC

### Python & PyTorch
- Creates a clean Python virtualenv at `/opt/invokeai-xpu`
- Installs PyTorch XPU wheels
- Verifies the installed torch build still has XPU support
- Reinstalls the XPU torch stack if InvokeAI replaces it

### InvokeAI
- Installs InvokeAI 6.12.0
- Writes a minimal XPU-safe InvokeAI config
- Applies the upstream MordragT patch
- Falls back to a local patch if the URL is unavailable
- Applies compatibility fixes for InvokeAI 6.12

### Runtime
- Makes `intel_extension_for_pytorch (IPEX)` optional
- Guards against missing `torch.xpu.mem_get_info()`
- Fixes invocation stats for XPU when VRAM info is unavailable
- Creates a systemd service
- Verifies XPU availability at startup
- Runs InvokeAI fully headless
- Exposes the web UI over HTTP

### End result
InvokeAI runs on Intel GPU, images generate successfully, and the UI is accessible from a browser.

---

## Known issues

- InvokeAI cannot accurately detect available VRAM on Intel XPU  
  (workarounds are applied; generation still works)

- Patchmatch may fail to compile/load  
  (this is non-fatal and does not affect generation)

- GPU may stay “awake” after generation unless the service is stopped

  On Proxmox, current workaround is to run on the host:

  ```bash
  intel_gpu_top -l
  ```

---

## Requirements

### Proxmox host

- Intel GPU
- XE driver
- GPU passed through to the LXC

Example container config (`/etc/pve/lxc/<id>.conf`):

```bash
lxc.cgroup2.devices.allow: c 226:1 rwm  
lxc.cgroup2.devices.allow: c 226:128 rwm  
lxc.mount.entry: /dev/dri/card1 dev/dri/card1 none bind,optional,create=file  
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
```

⚠️ Device numbers may change after updates. Check:

```bash
ls -l /dev/dri  
ls -l /dev/dri/by-path  
```
---

### LXC container

- Ubuntu 24.04 LTS
- Fresh install recommended
- Internet access
- Privileged container
- Nesting enabled

---

## Quick start

```bash
git clone https://github.com/Raasu2/invokeai-xpu.git  
cd invokeai-xpu  
chmod +x install-invoke-xpu.sh  
sudo bash install-invoke-xpu.sh  
```
---

## Optional: VRAM override
Change the VRAM override in install.conf to your GPU's VRAM. 

```bash
INVOKEAI_XPU_VRAM_TOTAL_GB="16"
```
---

## Thanks / Credits

Huge thanks to MordragT for the original InvokeAI XPU patches.
