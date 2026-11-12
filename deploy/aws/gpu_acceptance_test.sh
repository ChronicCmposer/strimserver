#!/usr/bin/env bash
# gpu_acceptance_test.sh -- real-host acceptance gate for the 620.70.06 driver.
#
# Tagged `manual` in BUILD.bazel: it must run on an actual T4/T4G host with the
# GPU visible, not under Bazel's sandbox. Run directly:
#   bash deploy/aws/gpu_acceptance_test.sh
#
# Checks: driver floor 620.70.06, compute capability 7.5, GSP firmware present,
# one NVENC encode, /var/run/cdi/nvidia.json schema 0.7.0 + driver version, and
# containerd >= 1.7.16 (required by CDI spec 0.7.0).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nvidia.sh
source "$script_dir/lib/nvidia.sh"

FIRMWARE_ROOT="${NVIDIA_FIRMWARE_ROOT:-/lib/firmware}"
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"
CDI_JSON="${CDI_JSON:-/var/run/cdi/nvidia.json}"

failures=0
check() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok: %s\n' "$desc"
  else
    printf 'FAIL: %s\n' "$desc" >&2
    failures=$((failures + 1))
  fi
}

# --- driver version ----------------------------------------------------------
driver="$(nvidia_driver_of_smi || true)"
check "driver detected (${driver:-none})" test -n "$driver"
check "driver >= floor $NVIDIA_DRIVER_FLOOR" \
  bash -c 'nvidia_driver_ge "$1" "$2"' _ "$driver" "$NVIDIA_DRIVER_FLOOR"

# --- loaded driver via the STRICT /proc reader ------------------------------
# nvidia-smi reports what userspace sees; /proc reports the loaded module. Both
# must agree the host is on 620 (an on-disk 620 with a loaded 595 is a failure).
proc_driver="$(nvidia__proc_version || true)"
check "proc reports driver >= floor (found ${proc_driver:-none})" \
  bash -c 'nvidia_driver_ge "$1" "$2"' _ "$proc_driver" "$NVIDIA_DRIVER_FLOOR"

# --- GPU device node --------------------------------------------------------
device_node="${NVIDIA_DEVICE_NODE:-/dev/nvidia0}"
check "GPU device node exists at $device_node" test -e "$device_node"

# --- DCGM must be left inactive after the driver swap -----------------------
# strimserver never uses DCGM, and nv-hostengine holds /dev/nvidia*.
if command -v systemctl >/dev/null 2>&1; then
  check "nvidia-dcgm.service is inactive" \
    bash -c '! systemctl is-active --quiet nvidia-dcgm.service'
  check "nvidia-dcgm-exporter.service is inactive" \
    bash -c '! systemctl is-active --quiet nvidia-dcgm-exporter.service'
else
  check "systemctl is available to check DCGM state" false
fi

# --- compute capability (T4/T4G = 7.5) --------------------------------------
cap="$(nvidia_compute_cap_of_smi || true)"
check "compute capability is 7.5 (found ${cap:-none})" test "$cap" = "7.5"

# --- GSP firmware (mandatory for 620 open modules) --------------------------
gsp="$FIRMWARE_ROOT/nvidia/$NVIDIA_DRIVER_FLOOR/gsp_tu10x.bin"
check "GSP firmware present at $gsp" test -f "$gsp"

# --- one NVENC encode --------------------------------------------------------
if command -v "$FFMPEG_BIN" >/dev/null 2>&1; then
  check "h264_nvenc encodes one second" \
    "$FFMPEG_BIN" -hide_banner -loglevel error \
      -f lavfi -i testsrc=size=320x240:rate=30 -t 1 \
      -c:v h264_nvenc -f null -
else
  check "ffmpeg present for the NVENC check ($FFMPEG_BIN)" false
fi

# --- CDI spec: schema 0.7.0 + driver 620 ------------------------------------
if [[ -f "$CDI_JSON" ]]; then
  cdi_schema="$(python3 - "$CDI_JSON" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(json.load(fh).get("cdiVersion", ""))
except Exception:
    print("")
PY
)"
  cdi_driver="$(python3 - "$CDI_JSON" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception:
    print("")
    raise SystemExit(0)
# nvidia-ctk records the driver version in device attributes / annotations.
for dev in doc.get("devices", []):
    for val in (dev.get("attributes") or {}).values():
        if str(val).count(".") == 2 and str(val)[0].isdigit():
            print(val)
            raise SystemExit(0)
print("")
PY
)"
  check "CDI spec schema is 0.7.0 (found ${cdi_schema:-none})" test "$cdi_schema" = "0.7.0"
  check "CDI spec names driver $NVIDIA_DRIVER_FLOOR (found ${cdi_driver:-none})" \
    bash -c 'nvidia_driver_ge "$1" "$2"' _ "$cdi_driver" "$NVIDIA_DRIVER_FLOOR"
else
  check "CDI spec exists at $CDI_JSON" false
fi

# --- containerd >= 1.7.16 (CDI spec 0.7.0 requirement) ----------------------
if command -v containerd >/dev/null 2>&1; then
  raw="$(containerd --version 2>/dev/null | awk '{print $3}')"
  cver="${raw#v}"
  check "containerd >= 1.7.16 (found ${cver:-none})" \
    bash -c 'nvidia_driver_ge "$1" "$2"' _ "$cver" "1.7.16"
else
  check "containerd present" false
fi

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d acceptance check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nGPU acceptance passed\n'
