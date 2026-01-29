#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

# Install uv system-wide (root), without touching shell profiles.
# Uses Astral's standalone installer in "unmanaged" mode:
#   curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL="/custom/path" sh
# Ref: https://docs.astral.sh/uv/reference/installer/
#
# Target:
#   /usr/local/bin/uv (and usually uvx)

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."

UV_BIN_DIR="/usr/local/bin"

if command -v uv >/dev/null 2>&1; then
  log "uv already present: $(command -v uv)"
  uv --version || true
  exit 0
fi

log "Installing prerequisites (curl, ca-certificates)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates

mkdir -p "${UV_BIN_DIR}"

log "Installing uv to ${UV_BIN_DIR} (unmanaged install; no shell profile changes)..."
# UV_UNMANAGED_INSTALL installs to an explicit directory and avoids modifying shell config.
curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL="${UV_BIN_DIR}" sh

# Some environments may not immediately see /usr/local/bin on PATH (rare, but happens).
if [[ -x "${UV_BIN_DIR}/uv" ]]; then
  log "uv installed: ${UV_BIN_DIR}/uv"
else
  die "uv installer did not produce ${UV_BIN_DIR}/uv"
fi

# Ensure discoverable via PATH for the rest of the script run
export PATH="${UV_BIN_DIR}:${PATH}"

log "Verifying uv..."
uv --version

if [[ -x "${UV_BIN_DIR}/uvx" ]]; then
  log "uvx installed: ${UV_BIN_DIR}/uvx"
else
  warn "uvx not found at ${UV_BIN_DIR}/uvx (this may be OK depending on installer/version)."
fi

log "Done."
