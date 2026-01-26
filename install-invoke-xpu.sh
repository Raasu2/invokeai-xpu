#!/usr/bin/env bash
set -euo pipefail

die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }
log(){ echo -e "\n[+] $*\n"; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_SRC="${SCRIPT_DIR}/install.conf"
CONF_DIR="/etc/invokeai-xpu"
CONF_DST="${CONF_DIR}/install.conf"

[[ -f "${CONF_SRC}" ]] || die "Missing ${CONF_SRC} (install.conf not found next to installer)"

log "Bootstrap: installing config to ${CONF_DST}"
mkdir -p "${CONF_DIR}"
install -m 0644 "${CONF_SRC}" "${CONF_DST}"

log "Using config:"
sed -n '1,200p' "${CONF_DST}"

log "Running install parts in order..."
for f in "${SCRIPT_DIR}"/parts/*.sh; do
  [[ -x "$f" ]] || chmod +x "$f"
  log "Running: $(basename "$f")"
  "$f"
done

log "All parts complete."