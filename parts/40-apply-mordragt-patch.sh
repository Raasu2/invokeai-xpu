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
PATCH_URL="${PATCH_URL:-https://raw.githubusercontent.com/MordragT/nixos/master/pkgs/by-lang/intel-python/invokeai/01-xpu-and-shutil.patch}"
PATCH_LOCAL="${PATCH_LOCAL:-patches/01-xpu-and-shutil_mod612.patch}"

[[ -x "${VENV_DIR}/bin/python" ]] || die "Venv python not found at ${VENV_DIR}/bin/python. Run Part 30 first."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${PATCH_LOCAL}" = /* ]]; then
  PATCH_LOCAL_RESOLVED="${PATCH_LOCAL}"
else
  PATCH_LOCAL_RESOLVED="${REPO_ROOT}/${PATCH_LOCAL}"
fi

PATCH_RAW="/tmp/01-xpu-and-shutil.patch"
PATCH_FILTERED="/tmp/01-xpu-and-shutil.filtered.patch"
PATCH_LOG="/tmp/01-xpu-and-shutil.patch.log"

log "Patch sources"
echo "PATCH_URL=${PATCH_URL}"
echo "PATCH_LOCAL=${PATCH_LOCAL_RESOLVED}"

if [[ -f "${PATCH_LOCAL_RESOLVED}" ]]; then
  log "Using local patch from install.conf"
  cp "${PATCH_LOCAL_RESOLVED}" "${PATCH_RAW}"
else
  die "Local patch not found: ${PATCH_LOCAL_RESOLVED}
Upstream reference: ${PATCH_URL}"
fi

log "Filtering patch to only files that exist in this pip install..."
"${VENV_DIR}/bin/python" - <<'PY'
import os
import re
import site
import sys

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

SITEPKG="$("${VENV_DIR}/bin/python" - <<'PY'
import site
for p in site.getsitepackages():
    if p.endswith("site-packages"):
        print(p)
        break
PY
)"

cd "${SITEPKG}"

log "Applying filtered patch..."
set +e
patch --batch --forward -p1 < "${PATCH_FILTERED}" 2>&1 | tee "${PATCH_LOG}"
PATCH_RC=${PIPESTATUS[0]}
set -e

if [[ "${PATCH_RC}" -ne 0 ]]; then
  die "Patch apply failed. See log: ${PATCH_LOG}"
elif grep -q "FAILED" "${PATCH_LOG}"; then
  die "Some patch hunks failed. See log: ${PATCH_LOG}"
else
  log "Patch applied cleanly (or already present)."
fi

log "Done."echo "PATCH_URL=${PATCH_URL}"
echo "PATCH_LOCAL=${PATCH_LOCAL_RESOLVED}"

if [[ -f "${PATCH_LOCAL_RESOLVED}" ]]; then
  log "Using local patch from install.conf"
  cp "${PATCH_LOCAL_RESOLVED}" "${PATCH_RAW}"
else
  warn "Local patch not found: ${PATCH_LOCAL_RESOLVED}"
  warn "Trying URL patch instead: ${PATCH_URL}"
  if ! curl -fsSL -o "${PATCH_RAW}" "${PATCH_URL}"; then
    die "Failed to get patch from both local path and URL."
  fi
fi

log "Filtering patch to only files that exist in this pip install..."
"${VENV_DIR}/bin/python" - <<'PY'
import os
import re
import sys
import site

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

SITEPKG="$("${VENV_DIR}/bin/python" - <<'PY'
import site
for p in site.getsitepackages():
    if p.endswith("site-packages"):
        print(p)
        break
PY
)"

cd "${SITEPKG}"

log "Applying filtered patch..."
set +e
patch --batch --forward -p1 < "${PATCH_FILTERED}" 2>&1 | tee "${PATCH_LOG}"
PATCH_RC=${PIPESTATUS[0]}
set -e

if [[ "${PATCH_RC}" -ne 0 ]]; then
  warn "patch returned non-zero exit code: ${PATCH_RC}"
fi

if grep -q "FAILED" "${PATCH_LOG}"; then
  warn "Some patch hunks failed."
  warn "See log: ${PATCH_LOG}"
else
  log "Patch applied cleanly (or already present)."
fi

log "Done."
