#!/usr/bin/env bash
set -euo pipefail

die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }
log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."
export DEBIAN_FRONTEND=noninteractive

VENV_DIR="/opt/invokeai-xpu"
INVOKE_ROOT="/data/invokeai"
PORT="9090"
SERVICE_NAME="invokeai.service"
INVOKEAI_XPU_VRAM_TOTAL_GB="16"
SERVICE_USER="root"

INVOKE_VER="6.14.0"

log "Preflight checks..."
. /etc/os-release
echo "ID=$ID VERSION_ID=$VERSION_ID CODENAME=${VERSION_CODENAME:-unknown}"

[[ "$ID" == "ubuntu" ]] || die "This script is for Ubuntu only (detected: $ID)."

case "$VERSION_ID" in
  24.04|25.04|25.10|26.04) ;;
  *) die "Ubuntu $VERSION_ID is not supported. Use 24.04, 25.04, 25.10, or 26.04." ;;
esac

KERNEL="$(uname -r)"
log "Detected kernel: ${KERNEL}"

# Extract major.minor version (e.g. "6.17" from "6.17.13-7-pve")
KMAJOR="$(echo "$KERNEL" | cut -d. -f1)"
KMINOR="$(echo "$KERNEL" | cut -d. -f2)"
if [[ "$KMAJOR" -lt 6 || ("$KMAJOR" -eq 6 && "$KMINOR" -lt 14) ]]; then
  die "Kernel ${KERNEL} is too old. Battlemage (Arc B-series) requires kernel 6.14+.
  Ubuntu 24.04 ships kernel 6.8 — install HWE kernel:
    apt install linux-generic-hwe-24.04
  Or use Ubuntu 25.04+ / 26.04 (ships 6.14+)."
fi
log "Kernel ${KERNEL} is OK (>= 6.14)."

[[ -d /dev/dri ]] || die "/dev/dri missing. Pass the GPU through to the VM/LXC first."
if compgen -G "/dev/dri/renderD*" > /dev/null; then
  RENDER_NODE="$(ls -1 /dev/dri/renderD* | head -n1)"
  log "Using render node: ${RENDER_NODE}"
else
  die "No /dev/dri/renderD* nodes found."
fi

log "Installing base packages..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git jq \
  python3 python3-venv \
  build-essential pkg-config make \
  cmake ninja-build python3-dev \
  ffmpeg libgl1 libsm6 libxext6 libxrender1 \
  libglib2.0-0 \
  ocl-icd-libopencl1 clinfo \
  vainfo

log "Adding Intel GPU repo and installing Level Zero + OpenCL userspace..."
install -d /etc/apt/keyrings
curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key \
  | gpg --dearmor -o /etc/apt/keyrings/intel-gpu.gpg
[[ -n "${VERSION_CODENAME:-}" ]] || die "VERSION_CODENAME not found in /etc/os-release"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/intel-gpu.gpg] https://repositories.intel.com/gpu/ubuntu ${VERSION_CODENAME} client" \
  > /etc/apt/sources.list.d/intel-gpu.list
apt-get update

log "Removing any stale Ubuntu repo compute runtime (known BMG crash with 24.x)..."
apt-get remove -y --purge intel-opencl-icd libze-intel-gpu1 libze1 2>/dev/null || true
apt-get autoremove -y || true

log "Installing Intel GPU compute runtime from Intel repo (25.40+ for BMG stability)..."
apt-get install -y --no-install-recommends \
  intel-opencl-icd \
  libze1 libze-intel-gpu1 libze-dev \
  libigdgmm12 \
  libdrm2 libdrm-intel1 \
  intel-igc-cm \
  intel-gsc

log "Installing uv..."
UV_BIN_DIR="/usr/local/bin"
if ! command -v uv >/dev/null 2>&1; then
  mkdir -p "${UV_BIN_DIR}"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL="${UV_BIN_DIR}" sh
  export PATH="${UV_BIN_DIR}:${PATH}"
fi
uv --version

log "Creating venv at ${VENV_DIR} with uv-managed Python 3.12..."
systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
rm -rf "${VENV_DIR}"
uv venv "${VENV_DIR}" --relocatable --prompt invoke --python 3.12 --python-preference only-managed

log "Installing InvokeAI ${INVOKE_VER} with XPU backend (uv handles torch+xpu)..."
uv pip install --python "${VENV_DIR}/bin/python" \
  "invokeai[xpu]==${INVOKE_VER}" \
  --torch-backend=xpu --force-reinstall

log "Verifying torch XPU + InvokeAI..."
"${VENV_DIR}/bin/python" - <<'PY'
import sys, torch, invokeai
print("torch:", torch.__version__)
print("invokeai:", getattr(invokeai, "__version__", "unknown"))
assert "+xpu" in torch.__version__, "torch is not an XPU build"
assert torch.xpu.is_available(), "XPU not available"
assert torch.xpu.device_count() >= 1, "No XPU devices detected"
print("xpu avail:", torch.xpu.is_available())
print("xpu count:", torch.xpu.device_count())
print("dev0:", torch.xpu.get_device_name(0))
PY

log "Configuring InvokeAI..."
mkdir -p "${INVOKE_ROOT}"
cat > "${INVOKE_ROOT}/invokeai.yaml" <<YAML
schema_version: 4.0.3
device: xpu
precision: bfloat16
lazy_offload: true
sequential_guidance: true
force_tiled_decode: false
log_memory_usage: true
log_level: info
host: 0.0.0.0
port: ${PORT}
YAML

mkdir -p /etc/invokeai
[[ -f /etc/invokeai/invokeai-xpu.env ]] || cat > /etc/invokeai/invokeai-xpu.env <<ENV
INVOKEAI_XPU_VRAM_TOTAL_GB=${INVOKEAI_XPU_VRAM_TOTAL_GB}
ENV

log "Creating systemd service..."
UNIT="/etc/systemd/system/${SERVICE_NAME}"
cat > "${UNIT}" <<UNIT
[Unit]
Description=InvokeAI (Uvicorn) - XPU
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${INVOKE_ROOT}

Environment=INVOKEAI_ROOT=${INVOKE_ROOT}
Environment=VIRTUAL_ENV=${VENV_DIR}
Environment=PATH=${VENV_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

Environment=ZE_ENABLE_PCI_ID_DEVICE_ORDER=1
Environment=SYCL_CACHE_PERSISTENT=1
Environment=SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=0

Environment=NEOReadDebugKeys=1
Environment=RenderCompressedBuffersEnabled=0

Environment=INVOKEAI_XPU_VRAM_TOTAL_GB=${INVOKEAI_XPU_VRAM_TOTAL_GB}

ExecStartPre=${VENV_DIR}/bin/python -c "import torch; print('torch',torch.__version__); print('xpu avail', torch.xpu.is_available()); print('count', torch.xpu.device_count()); print('dev0', torch.xpu.get_device_name(0) if torch.xpu.device_count() else 'none')"

ExecStart=${VENV_DIR}/bin/invokeai-web --root ${INVOKE_ROOT}

Restart=always
RestartSec=2
TimeoutStopSec=20
KillSignal=SIGINT

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

log "Starting service..."
systemctl daemon-reload
systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl enable --now "${SERVICE_NAME}"

log "Done!"
log "Status: systemctl status ${SERVICE_NAME} --no-pager"
log "Logs:   journalctl -u ${SERVICE_NAME} -f"
log "URL:    http://<VM-IP>:${PORT}"