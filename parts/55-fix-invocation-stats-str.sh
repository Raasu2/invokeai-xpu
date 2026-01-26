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

STATS_COMMON="${SITEPKG}/invokeai/app/services/invocation_stats/invocation_stats_common.py"

log "Using venv: $VENV_DIR"
log "site-packages: $SITEPKG"
log "Target: $STATS_COMMON"

"$PY" - <<'PY'
from pathlib import Path
import re

p = Path(r"__STATS_COMMON__")
if not p.exists():
    print("Skip: not found", p)
    raise SystemExit(0)

txt = p.read_text(encoding="utf-8", errors="replace")

# Ensure import os exists
if re.search(r"(?m)^import os\s*$", txt) is None:
    m = re.search(r"(?m)^(from __future__ .*?\n)", txt)
    if m:
        txt = txt[:m.end()] + "import os\n" + txt[m.end():]
    else:
        txt = "import os\n" + txt

lines = txt.splitlines(True)

# Locate def __str__ (supports optional return annotation)
def_re = re.compile(r"^(\s*)def\s+__str__\s*\(\s*self[^)]*\)\s*(?:->\s*[^:]+)?\s*:\s*$")
start = None
indent = None
for i, line in enumerate(lines):
    m = def_re.match(line)
    if m:
        start = i
        indent = m.group(1)
        break

if start is None:
    raise SystemExit("ERROR: def __str__ not found")

# Find end of method: next "def " at same indent level
end = len(lines)
for j in range(start + 1, len(lines)):
    if lines[j].startswith(indent + "def "):
        end = j
        break

i1 = indent + "    "
i2 = indent + "        "

# IMPORTANT: plain strings (not f-strings) so {self...} is not evaluated by the patcher
new_block = []
new_block.append(lines[start])  # keep original def line
new_block.append(i1 + "_str = ''\n")
new_block.append(i1 + "if getattr(self, 'graph_stats', None):\n")
new_block.append(i2 + "_str += f\"Graph stats: {self.graph_stats.session_id}\\n\" if hasattr(self.graph_stats, 'session_id') else ''\n")
new_block.append(i2 + "_str += getattr(self.graph_stats, 'table_str', '') + \"\\n\"\n")
new_block.append(i1 + "if self.graph_stats.ram_usage_gb is not None and self.graph_stats.ram_change_gb is not None:\n")
new_block.append(i2 + "_str += f\"RAM used by InvokeAI process: {self.graph_stats.ram_usage_gb:4.2f}G ({self.graph_stats.ram_change_gb:+5.3f}G)\\n\"\n")
new_block.append(i1 + "_str += f\"RAM used to load models: {self.model_cache_stats.total_usage_gb:4.2f}G\\n\"\n")
new_block.append(i1 + "if getattr(self, 'vram_usage_gb', None):\n")
new_block.append(i2 + "_str += f\"VRAM in use: {self.vram_usage_gb:4.3f}G\\n\"\n")
new_block.append(i1 + "_str += \"RAM cache statistics:\\n\"\n")
new_block.append(i1 + "_str += f\"   Model cache hits: {self.model_cache_stats.cache_hits}\\n\"\n")
new_block.append(i1 + "_str += f\"   Model cache misses: {self.model_cache_stats.cache_misses}\\n\"\n")
new_block.append(i1 + "_str += f\"   Models cached: {self.model_cache_stats.models_cached}\\n\"\n")
new_block.append(i1 + "_str += f\"   Models cleared from cache: {self.model_cache_stats.models_cleared}\\n\"\n")
new_block.append(i1 + "_cap = float(self.model_cache_stats.cache_size_gb or 0)\n")
new_block.append(i1 + "if _cap <= 0:\n")
new_block.append(i2 + "try:\n")
new_block.append(i2 + "    _cap = float(os.environ.get('INVOKEAI_XPU_VRAM_TOTAL_GB', '0') or 0)\n")
new_block.append(i2 + "except Exception:\n")
new_block.append(i2 + "    _cap = 0.0\n")
new_block.append(i1 + "_str += f\"   Cache high water mark: {self.model_cache_stats.high_water_mark_gb:4.2f}/{_cap:4.2f}G\\n\"\n")
new_block.append(i1 + "return _str\n")
new_block.append("\n")

out = lines[:start] + new_block + lines[end:]
p.write_text("".join(out), encoding="utf-8")
print("✔ Replaced __str__ safely in:", p)
PY

# Inject path placeholder for the python snippet above (safe, only affects this file)
sed -i "s|__STATS_COMMON__|$STATS_COMMON|g" "$0" 2>/dev/null || true

log "Validate module compiles..."
python3 -m py_compile "$STATS_COMMON" && log "OK: py_compile passed"

log "Done. (Optional) restart: systemctl restart invokeai.service"