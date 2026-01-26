#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."
export DEBIAN_FRONTEND=noninteractive

CONF="/etc/invokeai-xpu/install.conf"
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

VENV_DIR="${VENV_DIR:-/opt/invokeai-xpu}"
INVOKE_ROOT="${INVOKE_ROOT:-/data/invokeai}"
SERVICE_NAME="${SERVICE_NAME:-invokeai.service}"

TORCH_VER="${TORCH_VER:-2.7.1+xpu}"
TV_VER="${TV_VER:-0.22.1+xpu}"
TA_VER="${TA_VER:-2.7.1+xpu}"
INVOKE_VER="${INVOKE_VER:-6.10.0}"

log "Ensuring InvokeAI root dir exists: ${INVOKE_ROOT}"
mkdir -p "${INVOKE_ROOT}"

log "Stopping/disabling any previous service (${SERVICE_NAME})..."
systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true

log "Creating fresh venv at ${VENV_DIR}..."
rm -rf "${VENV_DIR}"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel

log "Installing InvokeAI==${INVOKE_VER} (+loguru) into venv..."
"${VENV_DIR}/bin/pip" install --no-cache-dir "InvokeAI==${INVOKE_VER}" loguru

log "Forcing PyTorch XPU wheels (remove any CUDA torch first)..."
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

log "Writing manifests for later diffing..."
mkdir -p "${INVOKE_ROOT}/_manifests"
"${VENV_DIR}/bin/pip" freeze | sort > "${INVOKE_ROOT}/_manifests/pip-freeze.txt"
"${VENV_DIR}/bin/python" -c "import torch; print(torch.__version__)" > "${INVOKE_ROOT}/_manifests/torch-version.txt"

log "Venv + InvokeAI + torch-xpu installed."