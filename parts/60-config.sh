#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."

CONF="/etc/invokeai-xpu/install.conf"
[[ -f "$CONF" ]] && source "$CONF"

INVOKE_ROOT="${INVOKE_ROOT:-/data/invokeai}"
PORT="${PORT:-9090}"

ENV_DIR="/etc/invokeai"
ENV_FILE="${ENV_DIR}/invokeai-xpu.env"

log "90.1: Create INVOKE_ROOT + baseline invokeai.yaml..."
mkdir -p "${INVOKE_ROOT}"
cat > "${INVOKE_ROOT}/invokeai.yaml" <<YAML
schema_version: 4.0.2
device: xpu
precision: bfloat16
lazy_offload: true
attention_type: sliced
attention_slice_size: 2
sequential_guidance: true
force_tiled_decode: false
log_memory_usage: true
log_level: info
host: 0.0.0.0
port: 9090
YAML

log "90.2: Ensure optional overrides env file exists (do not overwrite)..."
mkdir -p "${ENV_DIR}"
if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" <<'ENV'
# Optional overrides can go here.
# Example:
# INVOKEAI_XPU_VRAM_TOTAL_GB=12
ENV
fi

log "90.3: Notes"
log "- Service + host/port binding is handled by Part 60 (systemd unit uses --host 0.0.0.0 --port ${PORT})"
log "- This file only sets InvokeAI runtime defaults (device/precision/attention etc.)"
