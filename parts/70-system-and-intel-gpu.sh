#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."
export DEBIAN_FRONTEND=noninteractive

CONF="/etc/invokeai-xpu/install.conf"
[[ -f "$CONF" ]] && source "$CONF"

log "G.1: Pre-flight /dev/dri..."
[[ -d /dev/dri ]] || die "/dev/dri missing. Pass GPU through to the LXC."
ls -l /dev/dri || true
compgen -G "/dev/dri/renderD*" >/dev/null || die "No /dev/dri/renderD* nodes found."

log "G.2: Base packages..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git jq \
  python3 python3-venv python3-pip \
  build-essential pkg-config make \
  cmake ninja-build python3-dev \
  ffmpeg libgl1 libsm6 libxext6 libxrender1 \
  libglib2.0-0 \
  ocl-icd-libopencl1 clinfo vainfo

log "G.3: Intel GPU repo + userspace packages..."
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
  libvpl2

log "G.4: Diagnostics (clinfo/vainfo)..."
clinfo | egrep -n "Number of platforms|Platform Name|Device Name|Driver Version" | head -n 150 || true
vainfo 2>/dev/null | head -n 80 || true

log "G done."