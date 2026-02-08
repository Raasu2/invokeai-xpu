#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."
export DEBIAN_FRONTEND=noninteractive

log "Adding Intel GPU repo (client) and installing Level Zero + OpenCL userspace..."
install -d /etc/apt/keyrings

curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key \
  | gpg --dearmor -o /etc/apt/keyrings/intel-gpu.gpg

. /etc/os-release
[[ -n "${VERSION_CODENAME:-}" ]] || die "VERSION_CODENAME not found in /etc/os-release"

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/intel-gpu.gpg] https://repositories.intel.com/gpu/ubuntu ${VERSION_CODENAME} client" \
  > /etc/apt/sources.list.d/intel-gpu.list

apt-get update
apt-get install -y --no-install-recommends \
  intel-opencl-icd \
  libze1 libze-intel-gpu1 libze-dev \
  libigdgmm12 \
  libdrm2 libdrm-intel1 \
  intel-igc-cm \
  intel-gsc

log "clinfo summary (should show Intel platform/device)"
clinfo | egrep -n "Number of platforms|Platform Name|Device Name|Driver Version|OpenCL Version" | head -n 200 || true

log "vainfo (best-effort)"
vainfo 2>/dev/null | head -n 80 || true

log "Intel GPU userspace installed."
