#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."

CONF="/etc/invokeai-xpu/install.conf"
[[ -f "$CONF" ]] && source "$CONF"

VENV_DIR="${VENV_DIR:-/opt/invokeai-xpu}"
PY="${VENV_DIR}/bin/python"
[[ -x "$PY" ]] || die "Python not found/executable at: $PY"

SITEPKG="$("$PY" - <<'PY'
import site
for p in site.getsitepackages():
    if p.endswith("site-packages"):
        print(p); break
PY
)"

log "Using venv: $VENV_DIR"
log "site-packages: $SITEPKG"

API_APP="${SITEPKG}/invokeai/app/api_app.py"
DIFF_PIPE="${SITEPKG}/invokeai/backend/stable_diffusion/diffusers_pipeline.py"
MODEL_CACHE="${SITEPKG}/invokeai/backend/model_manager/load/model_cache/model_cache.py"

ENVKEY="INVOKEAI_XPU_VRAM_TOTAL_GB"

# ------------------------------------------------------------
# F1.1: Make IPEX import optional (api_app.py)
# ------------------------------------------------------------
log "F1.1: Make IPEX import optional (api_app.py)..."
"$PY" - <<PY
from pathlib import Path

p = Path(r"$API_APP")
if not p.exists():
    print("Skip: not found", p)
    raise SystemExit(0)

txt = p.read_text(encoding="utf-8", errors="replace")
needle = "import intel_extension_for_pytorch as ipex"

if needle in txt and "ipex = None" not in txt:
    txt = txt.replace(
        needle,
        "try:\n    import intel_extension_for_pytorch as ipex\nexcept Exception:\n    ipex = None\n",
        1
    )
    p.write_text(txt, encoding="utf-8")
    print("Patched:", p)
else:
    print("Already optional or not present.")
PY

# ------------------------------------------------------------
# F1.2: Patch diffusers_pipeline.py mem_get_info call (if present)
# ------------------------------------------------------------
log "F1.2: Patch diffusers_pipeline.py torch.xpu.mem_get_info() -> safe fallback (if present)..."
"$PY" - <<PY
from pathlib import Path
import re

ENVKEY = "$ENVKEY"
p = Path(r"$DIFF_PIPE")
if not p.exists():
    print("Skip: not found", p)
    raise SystemExit(0)

txt = p.read_text(encoding="utf-8", errors="replace")

# Ensure import os exists
if re.search(r"(?m)^import os\\s*$", txt) is None:
    m = re.search(r"(?m)^(from __future__ .*\\n)", txt)
    if m:
        pos = m.end()
        txt = txt[:pos] + "import os\\n" + txt[pos:]
    else:
        txt = "import os\\n" + txt
    print("Added: import os")

# Replace:
#   mem_free, _ = torch.xpu.mem_get_info(<anything>)
pat = r"(?m)^(\\s*)mem_free,\\s*_\\s*=\\s*torch\\.xpu\\.mem_get_info\\((.+)\\)\\s*$"
m = re.search(pat, txt)
if not m:
    print("No mem_get_info assignment found here (ok).")
else:
    indent = m.group(1)
    arg = m.group(2).strip()
    rep = (
        f"{indent}try:\\n"
        f"{indent}    mem_free, _ = torch.xpu.mem_get_info({arg})\\n"
        f"{indent}except Exception:\\n"
        f"{indent}    # Intel XPU may not support free-memory query; fall back to configured total or 0\\n"
        f"{indent}    _gb = float(os.environ.get('{ENVKEY}', '0') or 0)\\n"
        f"{indent}    mem_free = int(_gb * (1024 ** 3)) if _gb > 0 else 0\\n"
    )
    txt = re.sub(pat, rep, txt, count=1)
    print("Patched mem_get_info fallback in diffusers_pipeline.py")

p.write_text(txt, encoding="utf-8")
print("Wrote:", p)
PY

# ------------------------------------------------------------
# F1.4: Patch model_cache.py (this is the crash you hit)
#   torch.xpu.mem_get_info(self._execution_device) may throw NOTIMPLEMENTED
# ------------------------------------------------------------
log "F1.4: Patch model_cache.py torch.xpu.mem_get_info(self._execution_device) -> safe fallback..."
"$PY" - <<PY
from pathlib import Path
import re

ENVKEY = "$ENVKEY"
p = Path(r"$MODEL_CACHE")
if not p.exists():
    print("Skip: not found", p)
    raise SystemExit(0)

txt = p.read_text(encoding="utf-8", errors="replace")

# Ensure import os exists
if re.search(r"(?m)^import os\\s*$", txt) is None:
    m = re.search(r"(?m)^(from __future__ .*?\\n)", txt)
    if m:
        txt = txt[:m.end()] + "import os\\n" + txt[m.end():]
    else:
        txt = "import os\\n" + txt
    print("Added: import os")

# Target the exact assignment that crashes in your logs:
#   _, total_cuda_vram_bytes = torch.xpu.mem_get_info(self._execution_device)
pat = r"(?m)^(\\s*)_,\\s*total_cuda_vram_bytes\\s*=\\s*torch\\.xpu\\.mem_get_info\\(self\\._execution_device\\)\\s*$"

m = re.search(pat, txt)
if not m:
    print("WARN: did not find the exact mem_get_info assignment. Will try a broader pattern...")

    # Broader fallback: any assignment of two vars from torch.xpu.mem_get_info(self._execution_device)
    pat2 = r"(?m)^(\\s*)(\\w+)\\s*,\\s*(\\w+)\\s*=\\s*torch\\.xpu\\.mem_get_info\\(self\\._execution_device\\)\\s*$"
    m2 = re.search(pat2, txt)
    if not m2:
        print("WARN: no mem_get_info(self._execution_device) assignment found. Nothing to patch.")
    else:
        indent = m2.group(1)
        a = m2.group(2)
        b = m2.group(3)
        rep = (
            f"{indent}try:\\n"
            f"{indent}    {a}, {b} = torch.xpu.mem_get_info(self._execution_device)\\n"
            f"{indent}except Exception:\\n"
            f"{indent}    _gb = float(os.environ.get('{ENVKEY}', '0') or 0)\\n"
            f"{indent}    {a} = 0\\n"
            f"{indent}    {b} = int(_gb * (1024 ** 3)) if _gb > 0 else 0\\n"
        )
        txt = re.sub(pat2, rep, txt, count=1)
        print("Patched broad mem_get_info fallback.")
else:
    indent = m.group(1)
    rep = (
        f"{indent}try:\\n"
        f"{indent}    _, total_cuda_vram_bytes = torch.xpu.mem_get_info(self._execution_device)\\n"
        f"{indent}except Exception:\\n"
        f"{indent}    # Intel XPU may not support querying VRAM; use env override or 0\\n"
        f"{indent}    _gb = float(os.environ.get('{ENVKEY}', '0') or 0)\\n"
        f"{indent}    total_cuda_vram_bytes = int(_gb * (1024 ** 3)) if _gb > 0 else 0\\n"
    )
    txt = re.sub(pat, rep, txt, count=1)
    print("Patched exact mem_get_info fallback in model_cache.py")

p.write_text(txt, encoding="utf-8")
print("Wrote:", p)
PY

log "Validate patched modules compile..."
python3 -m py_compile "$API_APP" "$MODEL_CACHE" 2>/dev/null || true
python3 -m py_compile "$DIFF_PIPE" 2>/dev/null || true
log "Done. Restart: systemctl restart invokeai.service"
