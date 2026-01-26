#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."
export DEBIAN_FRONTEND=noninteractive

log "Installing base packages..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git jq \
  python3 python3-venv python3-pip \
  build-essential pkg-config make \
  cmake ninja-build python3-dev \
  ffmpeg libgl1 libsm6 libxext6 libxrender1 \
  libglib2.0-0 \
  ocl-icd-libopencl1 clinfo \
  vainfo \
  pciutils

log "Base packages installed."