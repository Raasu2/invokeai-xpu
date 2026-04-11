# parts/50-runtime-patches.sh
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
        print(p)
        break
PY
)"

log "Using venv: $VENV_DIR"
log "site-packages: $SITEPKG"

API_APP="${SITEPKG}/invokeai/app/api_app.py"
DIFF_PIPE="${SITEPKG}/invokeai/backend/stable_diffusion/diffusers_pipeline.py"
MODEL_CACHE="${SITEPKG}/invokeai/backend/model_manager/load/model_cache/model_cache.py"

ENVKEY="INVOKEAI_XPU_VRAM_TOTAL_GB"

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
        1,
    )
    p.write_text(txt, encoding="utf-8")
    print("Patched:", p)
else:
    print("Already optional or not present.")
PY

log "F1.2: Patch diffusers_pipeline.py torch.xpu.mem_get_info() -> safe fallback..."
"$PY" - <<PY
from pathlib import Path
import re

ENVKEY = "$ENVKEY"
p = Path(r"$DIFF_PIPE")
if not p.exists():
    print("Skip: not found", p)
    raise SystemExit(0)

txt = p.read_text(encoding="utf-8", errors="replace")

if re.search(r"(?m)^import os\\s*$", txt) is None:
    m = re.search(r"(?m)^(from __future__ .*\\n)", txt)
    if m:
        pos = m.end()
        txt = txt[:pos] + "import os\\n" + txt[pos:]
    else:
        txt = "import os\\n" + txt
    print("Added: import os")

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
        f"{indent}    _gb = float(os.environ.get('{ENVKEY}', '0') or 0)\\n"
        f"{indent}    mem_free = int(_gb * (1024 ** 3)) if _gb > 0 else 0\\n"
    )
    txt = re.sub(pat, rep, txt, count=1)
    print("Patched mem_get_info fallback in diffusers_pipeline.py")

p.write_text(txt, encoding="utf-8")
print("Wrote:", p)
PY

log "F1.4: Patch model_cache.py torch.xpu.mem_get_info(...) -> safe fallback..."
"$PY" - <<PY
from pathlib import Path
import py_compile
import re

ENVKEY = "$ENVKEY"
p = Path(r"$MODEL_CACHE")
if not p.exists():
    print("Skip: not found", p)
    raise SystemExit(0)

txt = p.read_text(encoding="utf-8", errors="replace")

if re.search(r"(?m)^import os\\s*$", txt) is None:
    m = re.search(r"(?m)^(from __future__ .*?\\n)", txt)
    if m:
        txt = txt[:m.end()] + "import os\\n" + txt[m.end():]
    else:
        txt = "import os\\n" + txt
    print("Added: import os")

if "torch.xpu.mem_get_info" not in txt:
    print("No torch.xpu.mem_get_info(...) found. Nothing to patch.")
else:
    pat_exact = re.compile(
        r"(?m)^(\\s*)(\\w+)\\s*,\\s*(\\w+)\\s*=\\s*torch\\.xpu\\.mem_get_info\\(self\\._execution_device\\)\\s*$"
    )

    m = pat_exact.search(txt)
    if m:
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
        txt = pat_exact.sub(rep, txt, count=1)
        print("Patched: mem_get_info(self._execution_device) with try/except fallback")
    else:
        pat_broad = re.compile(
            r"(?m)^(\\s*)(\\w+)\\s*,\\s*(\\w+)\\s*=\\s*torch\\.xpu\\.mem_get_info\\(([^\\)]+)\\)\\s*$"
        )
        m2 = pat_broad.search(txt)
        if not m2:
            raise SystemExit("ERROR: Could not find a torch.xpu.mem_get_info(...) assignment to patch in model_cache.py")

        indent, a, b, arg = m2.group(1), m2.group(2), m2.group(3), m2.group(4).strip()
        if "self._execution_device" not in arg:
            raise SystemExit(
                f"ERROR: Found mem_get_info({arg}) but it does not reference self._execution_device; refusing to patch blindly."
            )

        rep = (
            f"{indent}try:\\n"
            f"{indent}    {a}, {b} = torch.xpu.mem_get_info({arg})\\n"
            f"{indent}except Exception:\\n"
            f"{indent}    # Intel XPU may not support mem_get_info(); use env override or 0\\n"
            f"{indent}    _gb = float(os.environ.get('{ENVKEY}', '0') or 0)\\n"
            f"{indent}    {a} = 0\\n"
            f"{indent}    {b} = int(_gb * (1024 ** 3)) if _gb > 0 else 0\\n"
        )
        txt = pat_broad.sub(rep, txt, count=1)
        print("Patched: broad mem_get_info(...) assignment")

p.write_text(txt, encoding="utf-8")
print("Wrote:", p)

py_compile.compile(str(p), doraise=True)
print("py_compile model_cache.py: OK")
PY

log "Validate patched modules compile..."
"$PY" -m py_compile "$API_APP" "$DIFF_PIPE" "$MODEL_CACHE"

log "Done."
log "Tip: set a VRAM total so cache math behaves:"
log "  systemctl edit invokeai.service"
log "  [Service]"
log "  Environment=${ENVKEY}=12"
log "Then: systemctl daemon-reload && systemctl restart invokeai.service"
