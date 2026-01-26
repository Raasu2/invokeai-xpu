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

# Defaults if not provided by conf
VENV_DIR="${VENV_DIR:-/opt/invokeai-xpu}"
INVOKE_ROOT="${INVOKE_ROOT:-/data/invokeai}"
PORT="${PORT:-9090}"
SERVICE_NAME="${SERVICE_NAME:-invokeai.service}"
PATCH_URL="${PATCH_URL:-https://raw.githubusercontent.com/MordragT/nixos/master/pkgs/by-scope/intel-python/invokeai/01-xpu-and-shutil.patch}"

TORCH_VER="${TORCH_VER:-2.7.1+xpu}"
TV_VER="${TV_VER:-0.22.1+xpu}"
TA_VER="${TA_VER:-2.7.1+xpu}"
INVOKE_VER="${INVOKE_VER:-6.10.0}"

log "OS info..."
. /etc/os-release
echo "ID=$ID"
echo "VERSION_ID=$VERSION_ID"
echo "VERSION_CODENAME=${VERSION_CODENAME:-unknown}"

log "Checking /dev/dri access..."
[[ -d /dev/dri ]] || die "/dev/dri missing. Pass the GPU through to the LXC first."
ls -l /dev/dri || true

if compgen -G "/dev/dri/renderD*" > /dev/null; then
  RENDER_NODE="$(ls -1 /dev/dri/renderD* | head -n1)"
  log "Using render node: ${RENDER_NODE}"
else
  die "No /dev/dri/renderD* nodes found."
fi

log "Basic PCI GPU visibility (best-effort)..."
if command -v lspci >/dev/null 2>&1; then
  lspci -nn | egrep -i "vga|3d|display" || true
else
  warn "lspci not installed yet (will be available after Part B)."
fi

log "Config summary (from $CONF if present):"
cat <<EOF
VENV_DIR=${VENV_DIR}
INVOKE_ROOT=${INVOKE_ROOT}
PORT=${PORT}
SERVICE_NAME=${SERVICE_NAME}
PATCH_URL=${PATCH_URL}
INVOKE_VER=${INVOKE_VER}
TORCH_VER=${TORCH_VER}
TV_VER=${TV_VER}
TA_VER=${TA_VER}
EOF

log "Preflight OK."