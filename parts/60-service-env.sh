#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."

CONF="/etc/invokeai-xpu/install.conf"
[[ -f "$CONF" ]] && source "$CONF"

VENV_DIR="${VENV_DIR:-/opt/invokeai-xpu}"
INVOKE_ROOT="${INVOKE_ROOT:-/data/invokeai}"
PORT="${PORT:-9090}"
SERVICE_NAME="${SERVICE_NAME:-invokeai.service}"

UNIT="/etc/systemd/system/${SERVICE_NAME}"

log "60: Stop/disable existing service (if any)..."
systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true

log "60: Write systemd unit"
cat > "${UNIT}" <<UNIT
[Unit]
Description=InvokeAI (Uvicorn) - XPU
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INVOKE_ROOT}

Environment=INVOKEAI_ROOT=${INVOKE_ROOT}
Environment=VIRTUAL_ENV=${VENV_DIR}
Environment=PATH=${VENV_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Intel XPU / Level Zero defaults (same as good build)
Environment=ZE_ENABLE_PCI_ID_DEVICE_ORDER=1
Environment=SYCL_CACHE_PERSISTENT=1
Environment=SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1

# Torch + Level Zero libs
Environment=LD_LIBRARY_PATH=${VENV_DIR}/lib:${VENV_DIR}/lib/python3.12/site-packages/torch/lib:/usr/lib/x86_64-linux-gnu:/usr/local/lib

# Hardcoded cache cap (display + fallback only)
Environment=INVOKEAI_XPU_VRAM_TOTAL_GB=16

ExecStartPre=${VENV_DIR}/bin/python -c "import torch; print('torch',torch.__version__); print('xpu avail', torch.xpu.is_available()); print('count', torch.xpu.device_count()); print('dev0', torch.xpu.get_device_name(0) if torch.xpu.device_count() else 'none')"

ExecStart=${VENV_DIR}/bin/invokeai-web --root /data/invokeai

Restart=always
RestartSec=2
TimeoutStopSec=20
KillSignal=SIGINT

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

log "60: Reload + enable + start..."
systemctl daemon-reload
systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl enable --now "${SERVICE_NAME}"

log "60 done."
log "Status: systemctl status ${SERVICE_NAME} --no-pager"
log "Logs:   journalctl -u ${SERVICE_NAME} -f"
log "URL:    http://<LXC-IP>:${PORT}"
