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
STATS_COMMON="${SITEPKG}/invokeai/app/services/invocation_stats/invocation_stats_common.py"

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
# F1.2: Patch diffusers_pipeline.py mem_get_info call used by
#       _adjust_memory_efficient_attention (your runtime crash)
# ------------------------------------------------------------
log "F1.2: Patch diffusers_pipeline.py torch.xpu.mem_get_info() -> safe fallback..."
"$PY" - <<PY
from pathlib import Path
import re

ENVKEY = "INVOKEAI_XPU_VRAM_TOTAL_GB"

p = Path(r"$DIFF_PIPE")
if not p.exists():
    print("Skip: not found", p)
    raise SystemExit(0)

txt = p.read_text(encoding="utf-8", errors="replace")

# ensure import os exists
if re.search(r"(?m)^import os\s*$", txt) is None:
    # insert after __future__ if present, else at top
    m = re.search(r"(?m)^(from __future__ .*\\n)", txt)
    if m:
        pos = m.end()
        txt = txt[:pos] + "import os\n" + txt[pos:]
    else:
        txt = "import os\n" + txt
    print("Added: import os")

# Replace:
#   mem_free, _ = torch.xpu.mem_get_info(<anything>)
# with a try/except fallback.
pat = r"(?m)^(\s*)mem_free,\s*_\s*=\s*torch\.xpu\.mem_get_info\((.+)\)\s*$"

m = re.search(pat, txt)
if not m:
    print("WARN: did not find torch.xpu.mem_get_info(...) assignment in diffusers_pipeline.py")
else:
    indent = m.group(1)
    arg = m.group(2).strip()
    rep = (
        f"{indent}try:\n"
        f"{indent}    mem_free, _ = torch.xpu.mem_get_info({arg})\n"
        f"{indent}except Exception:\n"
        f"{indent}    # Intel XPU may not support free-memory query; fall back to configured total or 0\n"
        f"{indent}    _gb = float(os.environ.get('{ENVKEY}', '0') or 0)\n"
        f"{indent}    mem_free = int(_gb * (1024 ** 3)) if _gb > 0 else 0\n"
    )
    txt = re.sub(pat, rep, txt, count=1)
    print("Patched mem_get_info fallback in diffusers_pipeline.py")

p.write_text(txt, encoding="utf-8")
print("Wrote:", p)
PY

# ------------------------------------------------------------
# F1.3: Fix invocation_stats_common.py (__str__ must return string)
#       - robustly finds def __str__(...) even with type hints
#       - prevents bash from eating python (quoted heredoc)
# ------------------------------------------------------------
log "F1.3: Fix invocation_stats_common.py (__str__ must return string)..."
"$PY" - <<'PYCODE'
from pathlib import Path
import re

STATS_COMMON = Path(r"__STATS_COMMON__")
if not STATS_COMMON.exists():
    print("Skip: not found", STATS_COMMON)
    raise SystemExit(0)

txt = STATS_COMMON.read_text(encoding="utf-8", errors="replace")

# Ensure import os exists (safe to add)
if re.search(r"(?m)^import os\s*$", txt) is None:
    m = re.search(r"(?m)^(from __future__ .*?\n)", txt)
    if m:
        pos = m.end()
        txt = txt[:pos] + "import os\n" + txt[pos:]
    else:
        txt = "import os\n" + txt
    print("Added: import os")

lines = txt.splitlines(True)

# Find "def __str__(...)" with optional return annotation
def_pat = re.compile(r"^(\s*)def\s+__str__\s*\(\s*self[^)]*\)\s*(?:->\s*[^:]+)?\s*:\s*$")

start = None
indent = None
for i, line in enumerate(lines):
    m = def_pat.match(line)
    if m:
        start = i
        indent = m.group(1)
        break

if start is None:
    print("ERROR: Could not locate def __str__(...) block")
    raise SystemExit(2)

# Find end of block: next "def " at same indent level
end = len(lines)
for j in range(start + 1, len(lines)):
    if lines[j].startswith(indent + "def "):
        end = j
        break

block = lines[start:end]

# Does this __str__ build a string variable called _str?
has__str_var = any(re.search(r"(?m)^\s*_str\s*=", l) or "_str +=" in l for l in block)

new_block = []
for l in block:
    # rewrite any return inside __str__
    mret = re.match(r"^(\s*)return\s+(.+)\s*$", l)
    if mret:
        ret_indent = mret.group(1)
        expr = mret.group(2)
        if has__str_var:
            new_block.append(ret_indent + "return _str\n")
        else:
            new_block.append(ret_indent + f"return str({expr})\n")
        continue
    new_block.append(l)

# Ensure there is a return at the end of __str__
if not any(re.match(r"^\s*return\s+", l) for l in new_block):
    # best-effort: if they built _str, return it; otherwise return a safe string
    if has__str_var:
        new_block.append(indent + "    return _str\n")
    else:
        new_block.append(indent + "    return \"\"\n")

# Write back
lines2 = lines[:start] + new_block + lines[end:]
STATS_COMMON.write_text("".join(lines2), encoding="utf-8")
print("Patched:", STATS_COMMON)
PYCODE

# inject the actual path into the heredoc content
# (this avoids bash expanding anything inside the quoted heredoc)
perl -0777 -i -pe 's/__STATS_COMMON__/\Q'"$STATS_COMMON"'\E/g' "$0" 2>/dev/null || true

log "50 done."
log "Restart: systemctl restart invokeai.service"