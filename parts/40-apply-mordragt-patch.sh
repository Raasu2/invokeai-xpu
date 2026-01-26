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
PATCH_URL="${PATCH_URL:-https://raw.githubusercontent.com/MordragT/nixos/master/pkgs/by-scope/intel-python/invokeai/01-xpu-and-shutil.patch}"

[[ -x "${VENV_DIR}/bin/python" ]] || die "Venv python not found at ${VENV_DIR}/bin/python. Run Part D first."

PATCH_RAW="/tmp/01-xpu-and-shutil.patch"
PATCH_FILTERED="/tmp/01-xpu-and-shutil.filtered.patch"

log "Downloading MordragT patch..."
curl -fsSL -o "${PATCH_RAW}" "${PATCH_URL}"

log "Filtering patch to only files that exist in this pip install..."
"${VENV_DIR}/bin/python" - <<'PY'
import os, re, sys, site

sitepk = None
for p in site.getsitepackages():
    if p.endswith("site-packages"):
        sitepk = p
        break
if not sitepk:
    print("Could not locate site-packages", file=sys.stderr)
    sys.exit(1)

raw = "/tmp/01-xpu-and-shutil.patch"
out = "/tmp/01-xpu-and-shutil.filtered.patch"

with open(raw, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

chunks = []
i = 0
while i < len(lines):
    if lines[i].startswith("diff --git "):
        j = i + 1
        while j < len(lines) and not lines[j].startswith("diff --git "):
            j += 1
        chunks.append(lines[i:j])
        i = j
    else:
        i += 1

kept = []
for ch in chunks:
    header = ch[0]
    m = re.match(r"diff --git a/(.+?) b/(.+?)\s*$", header)
    if not m:
        continue
    a_path, b_path = m.group(1), m.group(2)

    # Skip frontend paths (not in pip install)
    if a_path.startswith("invokeai/frontend/") or b_path.startswith("invokeai/frontend/"):
        continue

    target = os.path.join(sitepk, b_path)
    if os.path.exists(target):
        kept.append(ch)

with open(out, "w", encoding="utf-8") as f:
    for ch in kept:
        f.writelines(ch)

print("site-packages:", sitepk)
print("kept_chunks:", len(kept))
print("wrote:", out)
PY

log "Applying filtered patch..."
SITEPKG="$("${VENV_DIR}/bin/python" - <<'PY'
import site
for p in site.getsitepackages():
    if p.endswith("site-packages"):
        print(p); break
PY
)"

cd "${SITEPKG}"
# --forward makes re-runs safe; if already applied it will skip hunks
patch --batch --forward -p1 < "${PATCH_FILTERED}" || true

log "Patch applied (or already present)."