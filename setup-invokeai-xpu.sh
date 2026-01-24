#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[+] $*\n"; }
warn() { echo -e "\n[!] $*\n" >&2; }
die() { echo -e "\n[ERROR] $*\n" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root (sudo -i)."
fi

export DEBIAN_FRONTEND=noninteractive

# -----------------------------
# 0) Pre-flight: GPU device nodes
# -----------------------------
log "Checking /dev/dri access..."
if [[ ! -d /dev/dri ]]; then
  die "/dev/dri missing. Pass the iGPU/ARC through to the LXC first."
fi

# Robust check (avoid brittle glob patterns)
render_nodes=(/dev/dri/renderD*)
if [[ ! -e "${render_nodes[0]}" ]]; then
  ls -l /dev/dri || true
  die "No /dev/dri/renderD* found. Pass the iGPU/ARC through to the LXC first."
fi

ls -l /dev/dri || true

log "Verifying we can open render node(s)..."
python3 - <<'PY'
import os, glob
nodes = sorted(glob.glob("/dev/dri/renderD*"))
print("render nodes:", nodes)
ok = True
for p in nodes:
    try:
        fd = os.open(p, os.O_RDWR)
        os.close(fd)
        print("OPEN OK:", p)
    except Exception as e:
        ok = False
        print("OPEN FAIL:", p, repr(e))
if not ok:
    raise SystemExit(2)
PY

# -----------------------------
# 1) Base packages + build deps
# -----------------------------
log "Installing base packages and build dependencies..."
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release \
  build-essential git patch pkg-config \
  python3-full python3-venv python3-pip python3-dev \
  python3-yaml \
  jq \
  ocl-icd-libopencl1 clinfo \
  libglib2.0-0 libgl1 libstdc++6 \
  libffi8 libssl3 \
  systemd

# -----------------------------
# 2) Intel GPU user-space runtime (Level Zero + OpenCL)
#    This is the "missing part" that commonly causes:
#      torch.xpu.is_available() == False AND device_count == 0
# -----------------------------
log "Adding Intel GPU APT repo (noble) and installing Level Zero/OpenCL runtime..."
install -d -m 0755 /etc/apt/keyrings

# Intel key
if [[ ! -f /etc/apt/keyrings/intel-gpu.gpg ]]; then
  curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key | gpg --dearmor -o /etc/apt/keyrings/intel-gpu.gpg
fi

# Repo list (noble client)
cat >/etc/apt/sources.list.d/intel-gpu-noble.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/intel-gpu.gpg] https://repositories.intel.com/gpu/ubuntu noble client
EOF

apt-get update -y

# These packages are the important ones from the working LXC:
# - libze-intel-gpu1 provides libze_intel_gpu.so.* (the actual GPU backend)
# - libze_loader.so.1 alone is NOT enough
apt-get install -y --no-install-recommends \
  libze1 libze-dev libze-intel-gpu1 \
  intel-opencl-icd intel-igc-cm \
  libigc1 libigdfcl1 libigdgmm12

log "Confirming Level Zero libraries are visible..."
ldconfig -p | egrep -i 'libze_loader|libze_intel_gpu' || true
if ! ldconfig -p | grep -q 'libze_intel_gpu'; then
  warn "libze_intel_gpu not found in ldconfig cache. XPU discovery will likely fail."
  warn "Check Intel repo install and that libze-intel-gpu1 is installed."
fi

# Optional but useful diagnostics
log "Quick OpenCL sanity check (clinfo)..."
clinfo 2>/dev/null | head -n 30 || true

# -----------------------------
# 3) Create venv at /opt/xpu and install PyTorch XPU wheels
# -----------------------------
VENV=/opt/xpu
log "Creating venv at ${VENV}..."
if [[ ! -d "${VENV}" ]]; then
  python3 -m venv "${VENV}"
fi

# shellcheck disable=SC1091
source "${VENV}/bin/activate"

log "Upgrading pip tooling..."
pip install --upgrade pip setuptools wheel

log "Installing PyTorch XPU wheels..."
# Using PyTorch’s XPU index. Versions match what you showed working:
# torch 2.7.1+xpu, torchvision 0.22.1+xpu, torchaudio 2.7.1+xpu
pip install \
  --index-url https://download.pytorch.org/whl/xpu \
  torch==2.7.1+xpu torchvision==0.22.1+xpu torchaudio==2.7.1+xpu

log "Checking torch.xpu availability..."
"${VENV}/bin/python" - <<'PY'
import torch
print("python:", __import__("sys").executable)
print("torch:", torch.__version__)
print("has torch.xpu:", hasattr(torch, "xpu"))
try:
    avail = torch.xpu.is_available()
    print("xpu available:", avail)
    print("xpu count:", torch.xpu.device_count())
except Exception as e:
    print("xpu check raised:", repr(e))
PY

# If XPU is still false, dump the most relevant diagnostics and STOP early
# so we don’t build the rest on a broken base.
XPU_OK="$("${VENV}/bin/python" - <<'PY'
import torch
try:
    print("1" if torch.xpu.is_available() and torch.xpu.device_count() > 0 else "0")
except Exception:
    print("0")
PY
)"
if [[ "${XPU_OK}" != "1" ]]; then
  warn "torch.xpu is NOT available (device count is zero). Dumping diagnostics:"
  echo "---- /dev/dri ----"
  ls -l /dev/dri || true
  echo "---- groups ----"
  getent group render || true
  getent group video || true
  echo "---- ldconfig ze ----"
  ldconfig -p | egrep -i 'libze_loader|libze_intel_gpu' || true
  echo "---- dpkg intel/ze ----"
  dpkg -l | egrep -i 'intel|opencl|level|ze|igc|igdgmm' || true
  echo "---- env (oneapi/sycl/ze) ----"
  env | egrep -i 'oneapi|sycl|ze_' || true
  die "Fix Level Zero/Intel GPU runtime first (libze-intel-gpu1 / repo) before continuing."
fi

# -----------------------------
# 4) Install InvokeAI + missing deps (PyYAML was missing in your run)
# -----------------------------
log "Installing InvokeAI 6.10.0 and missing python deps..."
pip install invokeai==6.10.0
# This fixes: ModuleNotFoundError: No module named 'yaml'
pip install pyyaml

# -----------------------------
# 5) Apply the XPU + shutil patch to InvokeAI package inside the venv
# -----------------------------
log "Applying InvokeAI XPU patch (xpu support + pnpm workspace fix)..."
SITEPKG="$("${VENV}/bin/python" - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"

PATCH_FILE="/tmp/01-xpu-and-shutil.patch"
cat >"${PATCH_FILE}" <<'PATCH'
diff --git a/invokeai/app/invocations/load_custom_nodes.py b/invokeai/app/invocations/load_custom_nodes.py
index b6d5c381f..c39f3f9f1 100644
--- a/invokeai/app/invocations/load_custom_nodes.py
+++ b/invokeai/app/invocations/load_custom_nodes.py
@@ -1,5 +1,6 @@
 import importlib
 import os
+import shutil
 from pathlib import Path
 from types import ModuleType
 from typing import Any
@@ -62,6 +63,10 @@ def load_custom_nodes() -> None:
         return
 
     # if user has older custom nodes in old location, move them to new location
+    if (custom_nodes_dir.exists() and custom_nodes_dir.is_dir()) and (custom_nodes_dir / "README.md").exists():
+        # if the new custom nodes dir exists and contains a README, assume it is the default and do not move anything
+        return
     if old_custom_nodes_dir.exists() and old_custom_nodes_dir.is_dir() and not custom_nodes_dir.exists():
         logger.info("Found custom nodes in old location. Moving to new location.")
-        old_custom_nodes_dir.rename(custom_nodes_dir)
+        shutil.move(str(old_custom_nodes_dir), str(custom_nodes_dir))

diff --git a/invokeai/app/services/config/config_default.py b/invokeai/app/services/config/config_default.py
index c916b824b..ddc576fc8 100644
--- a/invokeai/app/services/config/config_default.py
+++ b/invokeai/app/services/config/config_default.py
@@ -106,7 +106,7 @@ class InvokeAIAppConfig(BaseModel):
     # --------------------------------------------
     # Device configuration.
     # --------------------------------------------
-    device: Literal["auto", "cpu", "cuda", "mps"] = Field(default="auto", description="Preferred execution device")
+    device: Literal["auto", "cpu", "cuda", "mps", "xpu"] = Field(default="auto", description="Preferred execution device")
     precision: Literal["auto", "float32", "float16", "bfloat16"] = Field(
         default="auto",
         description="Preferred precision. If auto, will be chosen based on the device",
@@ -175,6 +175,8 @@ class InvokeAIAppConfig(BaseModel):
     def default_device(cls):
         if torch.cuda.is_available():
             return "cuda"
+        elif torch.xpu.is_available():
+            return "xpu"
         elif torch.backends.mps.is_available():
             return "mps"
         else:
             return "cpu"
@@ -472,7 +474,7 @@ class InvokeAIAppConfig(BaseModel):
     def model_cache_size_MB(cls, values):
         """Model cache size is in MB. If set to 0, disable caching."""
         model_cache_size_MB = values.get("model_cache_size_MB", 0)
-        if model_cache_size_MB is None or model_cache_size_MB == 0:
+        if model_cache_size_MB is None or model_cache_size_MB == 0:
             model_cache_size_MB = values.get("ram", 0)
         return model_cache_size_MB
@@ -551,7 +553,7 @@ class InvokeAIAppConfig(BaseModel):
     def default_ram(cls):
         """Default to 75% of available RAM"""
         try:
-            return int(psutil.virtual_memory().total / (1024 * 1024) * 0.75)
+            return int(psutil.virtual_memory().total / (1024 * 1024) * 0.75)
         except Exception:
             return 2048

diff --git a/invokeai/app/services/invocation_stats/invocation_stats_default.py b/invokeai/app/services/invocation_stats/invocation_stats_default.py
index 531e7fd0c..1a0b9c21f 100644
--- a/invokeai/app/services/invocation_stats/invocation_stats_default.py
+++ b/invokeai/app/services/invocation_stats/invocation_stats_default.py
@@ -21,6 +21,8 @@ class InvocationStatsService:
             return torch.cuda.max_memory_allocated()
         if device.type == "mps":
             return torch.mps.current_allocated_memory()
+        if device.type == "xpu":
+            return torch.xpu.max_memory_allocated()
         return None

diff --git a/invokeai/backend/model_manager/load/memory_snapshot.py b/invokeai/backend/model_manager/load/memory_snapshot.py
index 6bc722aa1..8b6a7b012 100644
--- a/invokeai/backend/model_manager/load/memory_snapshot.py
+++ b/invokeai/backend/model_manager/load/memory_snapshot.py
@@ -34,6 +34,10 @@ class MemorySnapshot(BaseModel):
             available = mem_total_bytes - allocated
             return cls(allocated=allocated, available=available, total=mem_total_bytes)
 
+        if torch.xpu.is_available():
+            mem_free_bytes, mem_total_bytes = torch.xpu.mem_get_info(device)
+            allocated = mem_total_bytes - mem_free_bytes
+            available = mem_total_bytes - allocated
+            return cls(allocated=allocated, available=available, total=mem_total_bytes)
+
         return cls.from_cpu()

diff --git a/invokeai/backend/model_manager/load/model_cache/dev_utils.py b/invokeai/backend/model_manager/load/model_cache/dev_utils.py
index 8f4d7a0be..1057b1f65 100644
--- a/invokeai/backend/model_manager/load/model_cache/dev_utils.py
+++ b/invokeai/backend/model_manager/load/model_cache/dev_utils.py
@@ -8,6 +8,7 @@ import torch
 from invokeai.backend.model_manager.load.model_cache.model_cache import ModelCache, ModelCacheConfig
 
 MB = 1024 * 1024
+GB = 1024 * MB
 
 
 def get_cache_size_str(model_cache: ModelCache) -> str:
@@ -35,6 +36,9 @@ def get_cache_size_str(model_cache: ModelCache) -> str:
 
     if torch.cuda.is_available():
         return f"{torch.cuda.mem_get_info()[1] / GB:.1f} GB"
+    elif torch.xpu.is_available():
+        return f"{torch.xpu.mem_get_info()[1] / GB:.1f} GB"
     else:
         return "CPU"

diff --git a/invokeai/backend/model_manager/load/model_cache/model_cache.py b/invokeai/backend/model_manager/load/model_cache/model_cache.py
index 9da8e73ed..0a0d0b2fe 100644
--- a/invokeai/backend/model_manager/load/model_cache/model_cache.py
+++ b/invokeai/backend/model_manager/load/model_cache/model_cache.py
@@ -26,6 +26,8 @@ import torch
 MB = 1024 * 1024
 GB = 1024 * MB
 
@@ -143,6 +145,8 @@ class ModelCache:
             self._execution_device = torch.device("cuda")
         elif self._execution_device_str == "mps":
             self._execution_device = torch.device("mps")
+        elif self._execution_device_str == "xpu":
+            self._execution_device = torch.device("xpu")
         elif self._execution_device_str == "cpu":
             self._execution_device = torch.device("cpu")
         else:
@@ -280,6 +284,8 @@ class ModelCache:
             self._execution_device = torch.device("cuda")
         elif execution_device_str == "mps":
             self._execution_device = torch.device("mps")
+        elif execution_device_str == "xpu":
+            self._execution_device = torch.device("xpu")
         elif execution_device_str == "cpu":
             self._execution_device = torch.device("cpu")
         else:
@@ -490,6 +494,8 @@ class ModelCache:
         """Get the amount of VRAM currently in use by the cache."""
         if self._execution_device.type == "cuda":
             return torch.cuda.memory_allocated()
+        elif self._execution_device.type == "xpu":
+            return torch.xpu.memory_allocated()
         elif self._execution_device.type == "mps":
             return torch.mps.current_allocated_memory()
         else:
@@ -528,6 +534,8 @@ class ModelCache:
         total_cuda_vram_bytes: int | None = None
         if self._execution_device.type == "cuda":
             _, total_cuda_vram_bytes = torch.cuda.mem_get_info(self._execution_device)
+        elif self._execution_device.type == "xpu":
+            _, total_cuda_vram_bytes = torch.xpu.mem_get_info(self._execution_device)
 
         # Apply heuristic 1.
         # ------------------
@@ -657,6 +665,9 @@ class ModelCache:
 
         if torch.cuda.is_available():
             log += "  {:<30} {:.1f} MB\n".format("CUDA Memory Allocated:", torch.cuda.memory_allocated() / MB)
+        elif torch.xpu.is_available():
+            log += "  {:<30} {:.1f} MB\n".format("XPU Memory Allocated:", torch.xpu.memory_allocated() / MB)
+
         log += "  {:<30} {}\n".format("Total models:", len(self._cached_models))
 
         if include_entry_details and len(self._cached_models) > 0:
diff --git a/invokeai/backend/stable_diffusion/diffusers_pipeline.py b/invokeai/backend/stable_diffusion/diffusers_pipeline.py
index de5253f07..349ef3ef6 100644
--- a/invokeai/backend/stable_diffusion/diffusers_pipeline.py
+++ b/invokeai/backend/stable_diffusion/diffusers_pipeline.py
@@ -221,6 +221,8 @@ class StableDiffusionGeneratorPipeline(StableDiffusionPipeline):
             mem_free = psutil.virtual_memory().free
         elif self.unet.device.type == "cuda":
             mem_free, _ = torch.cuda.mem_get_info(TorchDevice.normalize(self.unet.device))
+        elif self.unet.device.type == "xpu":
+            mem_free, _ = torch.xpu.mem_get_info(TorchDevice.normalize(self.unet.device))
         else:
             raise ValueError(f"unrecognized device {self.unet.device}")
         # input tensor of [1, 4, h/8, w/8]
diff --git a/invokeai/backend/textual_inversion.py b/invokeai/backend/textual_inversion.py
index b83d769a8..c884265b7 100644
--- a/invokeai/backend/textual_inversion.py
+++ b/invokeai/backend/textual_inversion.py
@@ -67,7 +67,7 @@ class TextualInversionModelRaw(RawModel):
         return result
 
     def to(self, device: Optional[torch.device] = None, dtype: Optional[torch.dtype] = None) -> None:
-        if not torch.cuda.is_available():
+        if not torch.cuda.is_available() and not torch.xpu.is_available():
             return
         for emb in [self.embedding, self.embedding_2]:
             if emb is not None:
diff --git a/invokeai/backend/util/attention.py b/invokeai/backend/util/attention.py
index 88dc6e5ce..f89c46417 100644
--- a/invokeai/backend/util/attention.py
+++ b/invokeai/backend/util/attention.py
@@ -22,6 +22,8 @@ def auto_detect_slice_size(latents: torch.Tensor) -> str:
         mem_free = psutil.virtual_memory().free
     elif latents.device.type == "cuda":
         mem_free, _ = torch.cuda.mem_get_info(latents.device)
+    elif latents.device.type == "xpu":
+        mem_free, _ = torch.xpu.mem_get_info(latents.device)
     else:
         raise ValueError(f"unrecognized device {latents.device}")
 
diff --git a/invokeai/backend/util/devices.py b/invokeai/backend/util/devices.py
index 83ce05502..066969c59 100644
--- a/invokeai/backend/util/devices.py
+++ b/invokeai/backend/util/devices.py
@@ -8,6 +8,7 @@ from invokeai.app.services.config.config_default import get_config
 TorchPrecisionNames = Literal["float32", "float16", "bfloat16"]
 CPU_DEVICE = torch.device("cpu")
+XPU_DEVICE = torch.device("xpu")
 CUDA_DEVICE = torch.device("cuda")
 MPS_DEVICE = torch.device("mps")
 
@@ -43,6 +44,7 @@ class TorchDevice:
     """Abstraction layer for torch devices."""
 
     CPU_DEVICE = torch.device("cpu")
+    XPU_DEVICE = torch.device("xpu")
     CUDA_DEVICE = torch.device("cuda")
     MPS_DEVICE = torch.device("mps")
 
@@ -54,6 +56,8 @@ class TorchDevice:
             device = torch.device(app_config.device)
         elif torch.cuda.is_available():
             device = CUDA_DEVICE
+        elif torch.xpu.is_available():
+            device = XPU_DEVICE
         elif torch.backends.mps.is_available():
             device = MPS_DEVICE
         else:
@@ -77,6 +81,14 @@ class TorchDevice:
                 return cls._to_dtype(config.precision)
 
+        elif device.type == "xpu" and torch.xpu.is_available():
+            if config.precision == "auto":
+                return cls._to_dtype("float16")
+            else:
+                return cls._to_dtype(config.precision)
+
         elif device.type == "mps" and torch.backends.mps.is_available():
             if config.precision == "auto":
                 return cls._to_dtype("float16")
@@ -91,7 +103,10 @@ class TorchDevice:
     def get_torch_device_name(cls) -> str:
         device = cls.choose_torch_device()
-        return torch.cuda.get_device_name(device) if device.type == "cuda" else device.type.upper()
+        if device.type == "cuda":
+            return torch.cuda.get_device_name(device)
+        else:
+            return device.type.upper()
 
     @classmethod
     def normalize(cls, device: Union[str, torch.device]) -> torch.device:
@@ -108,6 +123,8 @@ class TorchDevice:
             torch.mps.empty_cache()
         if torch.cuda.is_available():
             torch.cuda.empty_cache()
+        if torch.xpu.is_available():
+            torch.xpu.empty_cache()
 
     @classmethod
     def _to_dtype(cls, precision_name: TorchPrecisionNames) -> torch.dtype:
diff --git a/invokeai/backend/util/test_utils.py b/invokeai/backend/util/test_utils.py
index add394e71..9344e168b 100644
--- a/invokeai/backend/util/test_utils.py
+++ b/invokeai/backend/util/test_utils.py
@@ -12,7 +12,12 @@ from invokeai.backend.model_manager import BaseModelType, LoadedModel, ModelType
 
 @pytest.fixture(scope="session")
 def torch_device():
-    return "cuda" if torch.cuda.is_available() else "cpu"
+    if torch.cuda.is_available():
+        return "cuda"
+    elif torch.xpu.is_available():
+        return "xpu"
+    else:
+        return "cpu"
diff --git a/invokeai/frontend/web/pnpm-workspace.yaml b/invokeai/frontend/web/pnpm-workspace.yaml
index 7c326294a..e20027479 100644
--- a/invokeai/frontend/web/pnpm-workspace.yaml
+++ b/invokeai/frontend/web/pnpm-workspace.yaml
@@ -1,3 +1,6 @@
 onlyBuiltDependencies:
   - '@swc/core'
   - esbuild
+
+packages:
+  - .
PATCH

# Apply patch in site-packages root so paths like "invokeai/..." resolve
pushd "${SITEPKG}" >/dev/null
patch -p1 -N < "${PATCH_FILE}" || true
popd >/dev/null

# -----------------------------
# 6) Create InvokeAI root + systemd service
# -----------------------------
log "Creating InvokeAI root at /data/invokeai..."
mkdir -p /data/invokeai
mkdir -p /data/invokeai/databases
mkdir -p /data/invokeai/config

SERVICE_FILE=/etc/systemd/system/invokeai.service
log "Writing systemd service: ${SERVICE_FILE}"

cat >"${SERVICE_FILE}" <<'EOF'
[Unit]
Description=InvokeAI (Uvicorn) - XPU
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/data/invokeai

# Environment for InvokeAI
Environment=INVOKEAI_ROOT=/data/invokeai

Environment=VIRTUAL_ENV=/opt/xpu
Environment=PATH=/opt/xpu/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Clear potentially harmful selectors if inherited
Environment=ONEAPI_DEVICE_SELECTOR=
Environment=SYCL_DEVICE_FILTER=
Environment=UR_ADAPTERS=

# Intel XPU / Level Zero defaults
Environment=ZE_ENABLE_PCI_ID_DEVICE_ORDER=1
Environment=SYCL_CACHE_PERSISTENT=1
Environment=SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1

# Library paths (venv + torch + system)
Environment=LD_LIBRARY_PATH=/opt/xpu/lib:/opt/xpu/lib/python3.12/site-packages/torch/lib:/usr/lib/x86_64-linux-gnu:/usr/local/lib

# Prove XPU availability at startup
ExecStartPre=/opt/xpu/bin/python -c "import torch; print('torch',torch.__version__); print('xpu avail', torch.xpu.is_available()); print('count', torch.xpu.device_count())"

# Run uvicorn directly using venv python
ExecStart=/opt/xpu/bin/python -m uvicorn invokeai.app.api_app:app --host 0.0.0.0 --port 9090

Restart=always
RestartSec=2

TimeoutStopSec=20
KillSignal=SIGINT

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

log "Enabling and starting invokeai.service..."
systemctl daemon-reload
systemctl enable --now invokeai.service

log "Done. Useful commands:"
cat <<'CMDS'
# Tail logs live:
journalctl -u invokeai.service -f

# Check XPU detection (systemd startup precheck lines):
journalctl -u invokeai.service -b --no-pager | egrep -i "torch|xpu avail|device count|Failed to initialize XPU|XPU device count" | tail -n 80

# Check from venv directly:
 /opt/xpu/bin/python - <<'PY'
import torch
print("torch:", torch.__version__)
print("xpu available:", torch.xpu.is_available())
print("xpu count:", torch.xpu.device_count())
PY

# Service status:
systemctl status invokeai.service --no-pager -l

# Verify Level Zero libs:
ldconfig -p | egrep -i 'libze_loader|libze_intel_gpu'
CMDS
