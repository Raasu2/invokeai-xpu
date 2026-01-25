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

working together.

This is not “best practice”.
This is “this finally works”.

---

## What this script does

- Installs Intel GPU userspace (Level Zero, OpenCL, media drivers)
- Creates a clean Python venv at `/opt/invokeai-xpu`
- Forces PyTorch XPU wheels (prevents CUDA installs)
- Installs InvokeAI `6.10.0`
- Applies required InvokeAI XPU patches (MordragT-based, filtered)
- Patches InvokeAI to:
  - make IPEX optional
  - guard against missing `torch.xpu.mem_get_info`
- Writes a minimal InvokeAI config
- Creates a systemd service + wrapper
- Verifies XPU visibility at service start

End result:  
InvokeAI runs on Intel GPU and you can open the UI in a browser.

## Known issues
- InvokeAI does not detect available VRAM (did not affect image generation)
- I'm not seeing generation preview
- UI is not updating after generation finishes had to reload manually
- Same issue installing models, does not show progress if you dont refresh page

---

## Requirements

### Proxmox host

- Intel GPU
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
chmod +x setup-invokeai-xpu.sh
sudo bash setup-invokeai-xpu.sh
```

## Thanks / Credits

Huge thanks to **MordragT** for the original InvokeAI XPU patches.
This setup would not exist without that work.
