#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."
export DEBIAN_FRONTEND=noninteractive

# Prefer a predictable uv location if installed by parts/15-install-uv.sh
export PATH="/usr/local/bin:${PATH}"

CONF="/etc/invokeai-xpu/install.conf"
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

VENV_DIR="${VENV_DIR:-/opt/invokeai-xpu}"
INVOKE_ROOT="${INVOKE_ROOT:-/data/invokeai}"
SERVICE_NAME="${SERVICE_NAME:-invokeai.service}"

# Pins (defaults match your previous script behavior)
TORCH_VER="${TORCH_VER:-2.7.1+xpu}"
TV_VER="${TV_VER:-0.22.1+xpu}"
TA_VER="${TA_VER:-2.7.1+xpu}"
INVOKE_VER="${INVOKE_VER:-6.10.0}"

# Prefer system python for LXC/headless determinism
SYSTEM_PY="${SYSTEM_PY:-/usr/bin/python3}"

uv_ok(){ command -v uv >/dev/null 2>&1; }

uv_pip_install(){
  # Usage: uv_pip_install <args...>
  uv pip install --python "${VENV_DIR}/bin/python" "$@"
}

uv_pip_uninstall(){
  uv pip uninstall --python "${VENV_DIR}/bin/python" -y "$@" || true
}

uv_pip_freeze(){
  uv pip freeze --python "${VENV_DIR}/bin/python"
}

log "Ensuring InvokeAI root dir exists: ${INVOKE_ROOT}"
mkdir -p "${INVOKE_ROOT}"

log "Stopping/disabling any previous service (${SERVICE_NAME})..."
systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true

uv_ok || die "uv not found in PATH. Make sure parts/15-install-uv.sh ran successfully."

log "Creating fresh venv at ${VENV_DIR} using uv (python: ${SYSTEM_PY})..."
rm -rf "${VENV_DIR}"
uv venv "${VENV_DIR}" --python "${SYSTEM_PY}"

log "Removing any existing torch packages (safety)..."
uv_pip_uninstall torch torchvision torchaudio pytorch-triton-xpu triton

log "Installing PyTorch XPU stack from the official XPU index..."
# Astral uv docs highlight Intel GPU support via the XPU index and pytorch-triton-xpu.
# We pin the +xpu wheels explicitly for determinism.
uv_pip_install --index-url https://download.pytorch.org/whl/xpu --force-reinstall --no-cache-dir \
  "torch==${TORCH_VER}" "torchvision==${TV_VER}" "torchaudio==${TA_VER}" "pytorch-triton-xpu"

log "Verifying torch build is XPU and device is visible..."
"${VENV_DIR}/bin/python" - <<'PY'
import sys
import torch
print("torch:", torch.__version__)
ok = True
if "+xpu" not in torch.__version__:
    print("ERROR: torch is not an XPU build:", torch.__version__)
    ok = False
try:
    avail = torch.xpu.is_available()
    cnt = torch.xpu.device_count()
    print("xpu avail:", avail)
    print("xpu count:", cnt)
    if not avail or cnt < 1:
        print("ERROR: XPU not available or no devices detected.")
        ok = False
except Exception as e:
    print("ERROR: torch.xpu check failed:", repr(e))
    ok = False
if not ok:
    sys.exit(2)
PY

log "Installing InvokeAI==${INVOKE_VER} (+loguru) into venv via uv..."
# Install Invoke after torch so it doesn't try to pull a different torch variant.
uv_pip_install "InvokeAI==${INVOKE_VER}" loguru

log "Sanity-checking InvokeAI import..."
"${VENV_DIR}/bin/python" - <<'PY'
import invokeai
print("invokeai:", getattr(invokeai, "__version__", "unknown"))
PY

log "Writing manifests for later diffing..."
mkdir -p "${INVOKE_ROOT}/_manifests"
uv_pip_freeze | sort > "${INVOKE_ROOT}/_manifests/uv-freeze.txt"
"${VENV_DIR}/bin/python" -c "import torch; print(torch.__version__)" > "${INVOKE_ROOT}/_manifests/torch-version.txt"

log "Venv + torch-xpu + InvokeAI installed (uv-based, XPU-index)."
