#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."

VENV_DIR="${VENV_DIR:-/opt/invokeai-xpu}"
PY="${VENV_DIR}/bin/python"
[[ -x "$PY" ]] || die "Python not found at: $PY"

SITEPKG="$("$PY" - <<'PY'
import site
for p in site.getsitepackages():
    if p.endswith("site-packages"):
        print(p); break
PY
)"

MODEL_CACHE="${SITEPKG}/invokeai/backend/model_manager/load/model_cache/model_cache.py"
ENVKEY="INVOKEAI_XPU_VRAM_TOTAL_GB"

log "Using venv: $VENV_DIR"
log "site-packages: $SITEPKG"
log "Target: $MODEL_CACHE"

"$PY" - <<PY
from pathlib import Path
import re

p = Path(r"$MODEL_CACHE")
ENVKEY = "$ENVKEY"

if not p.exists():
    raise SystemExit(f"ERROR: not found: {p}")

txt = p.read_text(encoding="utf-8", errors="replace")

# Ensure import os exists
if re.search(r"(?m)^import os\\s*$", txt) is None:
    m = re.search(r"(?m)^(from __future__ .*?\\n)", txt)
    if m:
        txt = txt[:m.end()] + "import os\\n" + txt[m.end():]
    else:
        txt = "import os\\n" + txt
    print("Added: import os")

# Patch the crashing assignment (exact or equivalent forms)
# Common forms seen:
#   _, total_cuda_vram_bytes = torch.xpu.mem_get_info(self._execution_device)
#   mem_free, total_cuda_vram_bytes = torch.xpu.mem_get_info(self._execution_device)
#   _, total_vram_bytes = torch.xpu.mem_get_info(self._execution_device)
pat = re.compile(
    r"(?m)^(\\s*)(\\w+)\\s*,\\s*(\\w+)\\s*=\\s*torch\\.xpu\\.mem_get_info\\(self\\._execution_device\\)\\s*$"
)

m = pat.search(txt)
if not m:
    # Sometimes there is spacing or slightly different self attribute access
    pat2 = re.compile(
        r"(?m)^(\\s*)(\\w+)\\s*,\\s*(\\w+)\\s*=\\s*torch\\.xpu\\.mem_get_info\\(([^\\)]+)\\)\\s*$"
    )
    m2 = pat2.search(txt)
    if not m2:
        raise SystemExit("ERROR: Could not find a torch.xpu.mem_get_info(...) assignment to patch in model_cache.py")
    indent, a, b, arg = m2.group(1), m2.group(2), m2.group(3), m2.group(4).strip()
    # Only patch if it's using self._execution_device (or close)
    if "self._execution_device" not in arg:
        raise SystemExit(f"ERROR: Found mem_get_info({arg}) but it doesn't reference self._execution_device; refusing to patch blindly.")
    rep = (
        f"{indent}try:\\n"
        f"{indent}    {a}, {b} = torch.xpu.mem_get_info({arg})\\n"
        f"{indent}except Exception:\\n"
        f"{indent}    # Intel XPU may not support mem_get_info(); use env override or 0\\n"
        f"{indent}    _gb = float(os.environ.get('{ENVKEY}', '0') or 0)\\n"
        f"{indent}    {a} = 0\\n"
        f"{indent}    {b} = int(_gb * (1024 ** 3)) if _gb > 0 else 0\\n"
    )
    txt = pat2.sub(rep, txt, count=1)
    print("Patched: broad mem_get_info(...) assignment")
else:
    indent, a, b = m.group(1), m.group(2), m.group(3)
    rep = (
        f"{indent}try:\\n"
        f"{indent}    {a}, {b} = torch.xpu.mem_get_info(self._execution_device)\\n"
        f"{indent}except Exception:\\n"
        f"{indent}    # Intel XPU may not support mem_get_info(); use env override or 0\\n"
        f"{indent}    _gb = float(os.environ.get('{ENVKEY}', '0') or 0)\\n"
        f"{indent}    {a} = 0\\n"
        f"{indent}    {b} = int(_gb * (1024 ** 3)) if _gb > 0 else 0\\n"
    )
    txt = pat.sub(rep, txt, count=1)
    print("Patched: mem_get_info(self._execution_device) with try/except fallback")

p.write_text(txt, encoding="utf-8")
print("Wrote:", p)

# Quick compile check
import py_compile
py_compile.compile(str(p), doraise=True)
print("py_compile: OK")
PY

log "Done."
log "Tip: set a VRAM total so cache math behaves:"
log "  systemctl edit invokeai.service"
log "  [Service]"
log "  Environment=INVOKEAI_XPU_VRAM_TOTAL_GB=12"
log "Then: systemctl daemon-reload && systemctl restart invokeai.service"
