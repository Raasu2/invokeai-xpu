#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."

CONF="/etc/invokeai-xpu/install.conf"
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

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

FILE="${SITEPKG}/invokeai/app/services/invocation_stats/invocation_stats_default.py"
[[ -f "$FILE" ]] || die "Target file not found: $FILE"

log "Using venv: $VENV_DIR"
log "site-packages: $SITEPKG"
log "Target: $FILE"

cp -a "$FILE" "${FILE}.bak"

"$PY" - <<'PY' "$FILE"
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8", errors="replace")

old_1 = '        vram_in_use = torch.cuda.memory_allocated() if torch.cuda.is_available() else 0.0'
new_1 = '''        if torch.cuda.is_available():
            vram_in_use = torch.cuda.memory_allocated()
        elif torch.xpu.is_available():
            vram_in_use = torch.xpu.memory_allocated()
        else:
            vram_in_use = 0.0'''

old_2 = '            delta_vram_gb = ((torch.cuda.memory_allocated() - vram_in_use) / GB) if torch.cuda.is_available() else 0.0'
new_2 = '''            if torch.cuda.is_available():
                delta_vram_gb = (torch.cuda.memory_allocated() - vram_in_use) / GB
            elif torch.xpu.is_available():
                delta_vram_gb = (torch.xpu.memory_allocated() - vram_in_use) / GB
            else:
                delta_vram_gb = 0.0'''

old_3 = '        vram_usage_gb = torch.cuda.memory_allocated() / GB if torch.cuda.is_available() else None'
new_3 = '''        if torch.cuda.is_available():
            vram_usage_gb = torch.cuda.memory_allocated() / GB
        elif torch.xpu.is_available():
            vram_usage_gb = torch.xpu.memory_allocated() / GB
        else:
            vram_usage_gb = None'''

changes = 0

if old_1 in s:
    s = s.replace(old_1, new_1, 1)
    changes += 1
elif 'elif torch.xpu.is_available():\n            vram_in_use = torch.xpu.memory_allocated()' in s:
    pass
else:
    raise SystemExit("Did not find expected vram_in_use line to patch")

if old_2 in s:
    s = s.replace(old_2, new_2, 1)
    changes += 1
elif 'elif torch.xpu.is_available():\n                delta_vram_gb = (torch.xpu.memory_allocated() - vram_in_use) / GB' in s:
    pass
else:
    raise SystemExit("Did not find expected delta_vram_gb line to patch")

if old_3 in s:
    s = s.replace(old_3, new_3, 1)
    changes += 1
elif 'elif torch.xpu.is_available():\n            vram_usage_gb = torch.xpu.memory_allocated() / GB' in s:
    pass
else:
    raise SystemExit("Did not find expected vram_usage_gb line to patch")

p.write_text(s, encoding="utf-8")
print(f"Patched: {p}")
print(f"Changes applied: {changes}")
PY

log "Compiling target"
"$PY" -m py_compile "$FILE"

log "Diff vs backup"
diff -u "${FILE}.bak" "$FILE" || true

log "Done."
