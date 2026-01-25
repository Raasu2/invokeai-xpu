#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."
export DEBIAN_FRONTEND=noninteractive

# -----------------------------
# Config (adjust if you want)
# -----------------------------
VENV_DIR="/opt/invokeai-xpu"
INVOKE_ROOT="/data/invokeai"
PORT="9090"
SERVICE_NAME="invokeai.service"

# Patch source used in your conversation
PATCH_URL="https://raw.githubusercontent.com/MordragT/nixos/master/pkgs/by-scope/intel-python/invokeai/01-xpu-and-shutil.patch"

# Versions that matched your working setup
TORCH_VER="2.7.1+xpu"
TV_VER="0.22.1+xpu"
TA_VER="2.7.1+xpu"
INVOKE_VER="6.10.0"

# -----------------------------
# 0) Pre-flight: GPU device nodes
# -----------------------------
log "Checking /dev/dri access..."
[[ -d /dev/dri ]] || die "/dev/dri missing. Pass the GPU through to the LXC first."
ls -l /dev/dri || true

if compgen -G "/dev/dri/renderD*" > /dev/null; then
  RENDER_NODE="$(ls -1 /dev/dri/renderD* | head -n1)"
  log "Using render node: ${RENDER_NODE}"
else
  die "No /dev/dri/renderD* nodes found."
fi

# -----------------------------
# 1) Base packages
# -----------------------------
log "Installing base packages..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git jq \
  python3 python3-venv python3-pip \
  build-essential pkg-config make \
  cmake ninja-build python3-dev \
  ffmpeg libgl1 libsm6 libxext6 libxrender1 \
  libglib2.0-0 \
  ocl-icd-libopencl1 clinfo \
  vainfo

# -----------------------------
# 2) Intel GPU userspace repo (Ubuntu noble: Intel 'client' component)
# -----------------------------
log "Adding Intel GPU repo (client) and installing Level Zero + OpenCL userspace..."
install -d /etc/apt/keyrings
curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key \
  | gpg --dearmor -o /etc/apt/keyrings/intel-gpu.gpg

. /etc/os-release
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/intel-gpu.gpg] https://repositories.intel.com/gpu/ubuntu ${VERSION_CODENAME} client" \
  > /etc/apt/sources.list.d/intel-gpu.list

apt-get update
apt-get install -y --no-install-recommends \
  intel-opencl-icd \
  libze1 libze-intel-gpu1 libze-dev \
  libigdgmm12 \
  libdrm2 libdrm-intel1 \
  intel-media-va-driver-non-free

log "clinfo summary (should show Intel GPU device)"
clinfo | egrep -n "Number of platforms|Platform Name|Device Name|Driver Version" | head -n 120 || true

# -----------------------------
# 3) Directories
# -----------------------------
log "Ensuring InvokeAI root dir exists..."
mkdir -p "${INVOKE_ROOT}"

# -----------------------------
# 4) Stop any previous service + rebuild venv (avoid mixed installs)
# -----------------------------
log "Stopping any previous InvokeAI service..."
systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true

log "Creating fresh venv at ${VENV_DIR}..."
rm -rf "${VENV_DIR}"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel

# -----------------------------
# 5) Install InvokeAI + FORCE Torch XPU (prevent CUDA torch)
# -----------------------------
log "Installing InvokeAI into venv..."
# Install InvokeAI, plus 'loguru' (your earlier crash)
"${VENV_DIR}/bin/pip" install --no-cache-dir "InvokeAI==${INVOKE_VER}" loguru

log "Forcing PyTorch XPU wheels (overwrites any +cu torch)..."
"${VENV_DIR}/bin/pip" uninstall -y torch torchvision torchaudio || true
"${VENV_DIR}/bin/pip" install --no-cache-dir --force-reinstall \
  "torch==${TORCH_VER}" "torchvision==${TV_VER}" "torchaudio==${TA_VER}" \
  --index-url https://download.pytorch.org/whl/xpu

log "Verifying torch build is XPU..."
"${VENV_DIR}/bin/python" - <<'PY'
import torch, sys
print("torch:", torch.__version__)
print("xpu avail:", torch.xpu.is_available())
print("xpu count:", torch.xpu.device_count())
if "+xpu" not in torch.__version__:
    print("ERROR: torch is not XPU build:", torch.__version__)
    sys.exit(2)
PY

# -----------------------------
# 6) Apply MordragT patch (filtered to only existing site-packages files)
# -----------------------------
log "Downloading MordragT XPU patch..."
PATCH_RAW="/tmp/01-xpu-and-shutil.patch"
PATCH_FILTERED="/tmp/01-xpu-and-shutil.filtered.patch"
curl -fsSL -o "${PATCH_RAW}" "${PATCH_URL}"

log "Filtering patch to only files that exist in this pip install..."
"${VENV_DIR}/bin/python" - <<'PY'
import os, re, sys, site

sitepk = None
for p in site.getsitepackages():
    if p.endswith("site-packages"):
        sitepk = p
        break
if not sitepk:
    print("Could not locate site-packages", file=sys.stderr)
    sys.exit(1)

raw = "/tmp/01-xpu-and-shutil.patch"
out = "/tmp/01-xpu-and-shutil.filtered.patch"

with open(raw, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

chunks = []
i = 0
while i < len(lines):
    if lines[i].startswith("diff --git "):
        j = i + 1
        while j < len(lines) and not lines[j].startswith("diff --git "):
            j += 1
        chunks.append(lines[i:j])
        i = j
    else:
        i += 1

kept = []
for ch in chunks:
    header = ch[0]
    m = re.match(r"diff --git a/(.+?) b/(.+?)\s*$", header)
    if not m:
        continue
    a_path, b_path = m.group(1), m.group(2)

    # Skip frontend paths (not in pip install)
    if a_path.startswith("invokeai/frontend/") or b_path.startswith("invokeai/frontend/"):
        continue

    target = os.path.join(sitepk, b_path)
    if os.path.exists(target):
        kept.append(ch)

with open(out, "w", encoding="utf-8") as f:
    for ch in kept:
        f.writelines(ch)

print("site-packages:", sitepk)
print("kept_chunks:", len(kept))
print("wrote:", out)
PY

log "Applying filtered patch..."
SITEPKG="$("${VENV_DIR}/bin/python" - <<'PY'
import site
for p in site.getsitepackages():
    if p.endswith("site-packages"):
        print(p); break
PY
)"
cd "${SITEPKG}"
patch --batch --forward -p1 < "${PATCH_FILTERED}" || true

# -----------------------------
# 7) Patch: make IPEX import optional (prevents crash)
# -----------------------------
log "Making IPEX import optional (prevents crash if IPEX not installed)..."
"${VENV_DIR}/bin/python" - <<'PY'
from pathlib import Path
p = Path("/opt/invokeai-xpu/lib/python3.12/site-packages/invokeai/app/api_app.py")
if not p.exists():
    print("Skip: api_app.py not found")
    raise SystemExit(0)

txt = p.read_text()
needle = "import intel_extension_for_pytorch as ipex"
if needle in txt and "ipex = None" not in txt:
    txt = txt.replace(
        needle,
        "try:\n    import intel_extension_for_pytorch as ipex\nexcept Exception:\n    ipex = None\n",
        1
    )
    p.write_text(txt)
    print("Patched:", p)
else:
    print("Already optional or not present.")
PY

# -----------------------------
# 8) Patch: torch.xpu.mem_get_info fallbacks (3 call sites)
#    - model_cache sizing (startup)
#    - model_cache _get_vram_available (runtime)
#    - diffusers_pipeline _adjust_memory_efficient_attention (runtime)
# -----------------------------
log "Patching InvokeAI: torch.xpu.mem_get_info fallbacks (startup + runtime)..."
"${VENV_DIR}/bin/python" - <<'PY'
import re
from pathlib import Path

def patch_line(file_path: str, pattern: str, make_block):
    p = Path(file_path)
    if not p.exists():
        print("Skip (missing):", file_path)
        return False
    txt = p.read_text()

    m = re.search(pattern, txt, re.MULTILINE)
    if not m:
        print("Skip (pattern not found):", file_path)
        return False

    indent = m.group(1)
    block = make_block(indent, m)

    txt2 = re.sub(pattern, block, txt, count=1, flags=re.MULTILINE)
    p.write_text(txt2)
    print("Patched:", file_path)
    return True

# 8.1 model_cache.py: total_cuda_vram_bytes sizing
model_cache = "/opt/invokeai-xpu/lib/python3.12/site-packages/invokeai/backend/model_manager/load/model_cache/model_cache.py"
Path(model_cache).exists() and Path(model_cache).rename(model_cache + ".bak_memfix_1") if False else None

pat1 = r"^([ \t]*)_,\s*total_cuda_vram_bytes\s*=\s*torch\.xpu\.mem_get_info\(\s*self\._execution_device\s*\)\s*$"
def blk1(indent, m):
    return (
        f"{indent}try:\n"
        f"{indent}    _, total_cuda_vram_bytes = torch.xpu.mem_get_info(self._execution_device)\n"
        f"{indent}except RuntimeError:\n"
        f"{indent}    # Some Intel XPU devices don't implement mem_get_info yet.\n"
        f"{indent}    total_cuda_vram_bytes = 0\n"
    )
patch_line(model_cache, pat1, blk1)

# 8.2 model_cache.py: vram_free query
pat2 = r"^([ \t]*)vram_free,\s*_vram_total\s*=\s*torch\.xpu\.mem_get_info\(\s*self\._execution_device\s*\)\s*$"
def blk2(indent, m):
    return (
        f"{indent}try:\n"
        f"{indent}    vram_free, _vram_total = torch.xpu.mem_get_info(self._execution_device)\n"
        f"{indent}except RuntimeError:\n"
        f"{indent}    # Some Intel XPU devices don't implement mem_get_info yet.\n"
        f"{indent}    vram_free = 0\n"
        f"{indent}    _vram_total = 0\n"
    )
patch_line(model_cache, pat2, blk2)

# 8.3 diffusers_pipeline.py: mem_free query
diff_pipe = "/opt/invokeai-xpu/lib/python3.12/site-packages/invokeai/backend/stable_diffusion/diffusers_pipeline.py"
pat3 = r"^([ \t]*)mem_free,\s*_\s*=\s*torch\.xpu\.mem_get_info\((.+)\)\s*$"
def blk3(indent, m):
    arg = m.group(2).strip()
    return (
        f"{indent}try:\n"
        f"{indent}    mem_free, _ = torch.xpu.mem_get_info({arg})\n"
        f"{indent}except RuntimeError:\n"
        f"{indent}    # Some Intel XPU devices don't implement mem_get_info yet.\n"
        f"{indent}    mem_free = 0\n"
    )
patch_line(diff_pipe, pat3, blk3)

print("Done mem_get_info patches.")
PY

# -----------------------------
# 9) InvokeAI config (baseline)
# -----------------------------
log "Writing ${INVOKE_ROOT}/invokeai.yaml ..."
cat > "${INVOKE_ROOT}/invokeai.yaml" <<YAML
device: xpu
precision: bfloat16
lazy_offload: true
attention_type: sliced
attention_slice_size: 4
sequential_guidance: true
log_memory_usage: true
log_level: info
YAML

# -----------------------------
# 10) Wrapper + env for systemd (known-good style)
# -----------------------------
log "Writing wrapper /usr/local/bin/invokeai-xpu-wrapper.sh ..."
cat > /usr/local/bin/invokeai-xpu-wrapper.sh <<SH
#!/usr/bin/env bash
set -euo pipefail

export VIRTUAL_ENV="${VENV_DIR}"
export PATH="${VENV_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export INVOKEAI_ROOT="${INVOKE_ROOT}"

export ZE_ENABLE_PCI_ID_DEVICE_ORDER=1
export SYCL_DEVICE_FILTER=level_zero:gpu
export SYCL_CACHE_PERSISTENT=1
export SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1

export LD_LIBRARY_PATH="${VENV_DIR}/lib:${VENV_DIR}/lib/python3.12/site-packages/torch/lib:/usr/lib/x86_64-linux-gnu:/usr/local/lib"

exec "${VENV_DIR}/bin/python" -m uvicorn invokeai.app.api_app:app --host 0.0.0.0 --port ${PORT}
SH
chmod +x /usr/local/bin/invokeai-xpu-wrapper.sh

log "Writing env file /etc/invokeai/invokeai-xpu.env ..."
mkdir -p /etc/invokeai
cat > /etc/invokeai/invokeai-xpu.env <<ENV
INVOKEAI_ROOT=${INVOKE_ROOT}
VIRTUAL_ENV=${VENV_DIR}
PATH=${VENV_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV

# -----------------------------
# 11) systemd unit (run as root - matches your known-good)
# -----------------------------
log "Writing systemd unit /etc/systemd/system/${SERVICE_NAME} ..."
cat > "/etc/systemd/system/${SERVICE_NAME}" <<UNIT
[Unit]
Description=InvokeAI (Uvicorn) - XPU
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INVOKE_ROOT}

ExecStartPre=${VENV_DIR}/bin/python -c "import torch; print('torch',torch.__version__); print('xpu avail', torch.xpu.is_available()); print('count', torch.xpu.device_count())"

ExecStart=/usr/local/bin/invokeai-xpu-wrapper.sh

Restart=on-failure
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl enable --now "${SERVICE_NAME}"

log "Done."
log "Status: systemctl status ${SERVICE_NAME} --no-pager"
log "Logs:   journalctl -u ${SERVICE_NAME} -f"
log "URL:    http://<LXC-IP>:${PORT}"
