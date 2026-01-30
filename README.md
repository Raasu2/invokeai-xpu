# invokeai-xpu
InvokeAI running on Intel Arc GPUs using PyTorch XPU (Level Zero), deployed headlessly on Ubuntu 24.04 LXC with systemd

## InvokeAI on Intel GPU (XPU, no CUDA)

This repo is basically a **“what finally worked” script** for running **InvokeAI on Intel GPUs** (Arc or iGPU) using **PyTorch XPU** on **Ubuntu 24.04**, inside a **Proxmox LXC**.

No CUDA.  
No Docker.  
No fancy setup.  

Just: *make InvokeAI run on Intel GPU without fighting it for days*.

**Disclaimer:** this is purely *vibecoded*

---

## Why this repo exists

I have an intel Arc B50 and too much free time. I like how easy InvokeAI is to use and wanted to see if i can make it work with the Arc. 

After a **long debugging session** with ChatGPT, this script captures **everything that was needed**, in the **order it actually worked**, to get:

- PyTorch XPU
- InvokeAI 6.10
- Intel Arc / iGPU
- Headless Ubuntu 24.04
- Proxmox LXC

So this is:

- ✅ A reproducible install that **actually runs InvokeAI on Intel XPU**
- ✅ Headless, systemd-managed, browser UI accessible
- ✅ Tested on **Intel Arc (B-series) and Intel iGPU**
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
- Creates a clean Python virtualenv at: `/opt/invokeai-xpu`
- Forces **PyTorch XPU wheels**
- Prevents CUDA wheels from being pulled in

### InvokeAI
- Installs **InvokeAI 6.10.0**
- Writes a **minimal, XPU-safe InvokeAI config**
- Applies **required runtime patches**, including:
- Making `intel_extension_for_pytorch (IPEX)` optional
- Guarding against missing `torch.xpu.mem_get_info()`
- Fixing invocation stats crashes when VRAM info is unavailable

### Runtime
- Creates a **systemd service**
- Verifies XPU availability at startup
- Runs InvokeAI fully headless
- Exposes the web UI over HTTP

### End result
InvokeAI runs on Intel GPU, images generate successfully, and the UI is accessible from a browser.

## Known issues
- InvokeAI **cannot accurately detect available VRAM** on Intel XPU  
(workarounds are applied; generation still works)
- ~~Generation preview may not update in real time~~
- ~~UI may require a refresh after generation finishes~~
- ~~Model downloads may not show progress until refresh~~
- GPU may stay “awake” after generation unless the service is stopped. This keeps fans spinning quite agressively. On Proxomox current workaround is to run `intel_gpu_top -l` on **host** after you want the fans to spin down. 

---

## Requirements

### Proxmox host

- Intel GPU
- XE driver
- GPU passed through to the LXC
- This is what I added to the container config file on the Proxmox host (`/etc/pve/lxc/<id>.conf`):
```bash
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:129 rwm
lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD129 dev/dri/renderD129 none bind,optional,create=file
```

---

### LXC container

- Ubuntu **24.04 LTS**
- Fresh install recommended
- Internet access
- Privileged, nesting

---

## Quick start

On a clean Ubuntu 24.04 LXC:

```bash
git clone https://github.com/Raasu2/invokeai-xpu.git
cd invokeai-xpu
chmod +x install-invoke-xpu.sh
sudo bash install-invoke-xpu.sh
```

## Thanks / Credits

Huge thanks to **MordragT** for the original InvokeAI XPU patches.
This setup would not exist without that work.
