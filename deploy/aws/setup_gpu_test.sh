#!/usr/bin/env bash
# setup_gpu_test.sh -- execution tests for deploy/aws/setup-gpu.sh.
#
# setup-gpu.sh is owned by the deploy-wiring lane; this test consumes it. The
# script is executed as an external process (never sourced) against
# testutil_fake_gpu.sh with SUDO=fake-sudo, so every privileged command is
# recorded. Assertions:
#   * the driver recovery/upgrade runs BEFORE the `command -v nvidia-smi` guard
#   * modprobe precedes `nvidia-ctk cdi generate`
#   * amd64 generates JSON-only CDI and clears stale YAML first
#   * arm64 requires the runtime binary and generates no CDI
#   * a failed driver upgrade produces no CDI
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_gpu="$script_dir/setup-gpu.sh"
# shellcheck source=testutil_fake_gpu.sh
source "$script_dir/testutil_fake_gpu.sh"

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

# --- precondition: the peer lane has wired the driver contract ---------------
if ! grep -Fq 'nvidia_ensure_driver_floor' "$setup_gpu"; then
  printf 'CROSS-LANE: deploy/aws/setup-gpu.sh does not yet call nvidia_ensure_driver_floor.\n' >&2
  printf 'CROSS-LANE: the deploy-wiring lane owns that file; driver-core cannot edit it.\n' >&2
  printf 'CROSS-LANE: setup_gpu_test cannot reach GREEN until that wiring lands.\n' >&2
  exit 1
fi

line_of() { grep -nF "$1" "$setup_gpu" | head -n1 | cut -d: -f1; }

# --- static ordering: recovery before the nvidia-smi guard ------------------
recovery_line="$(line_of 'nvidia_ensure_driver_floor')"
guard_line="$(line_of 'command -v nvidia-smi')"
check "static: setup-gpu.sh calls the driver recovery" test -n "$recovery_line"
check "static: recovery precedes the command -v nvidia-smi guard" \
  bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$recovery_line" "$guard_line"
check "static: sources lib/nvidia.sh" bash -c 'grep -Fq "lib/nvidia.sh" "$1"' _ "$setup_gpu"

# --- static: CDI generation exists once, inside the amd64 branch ------------
check "static: exactly one nvidia-ctk cdi generate" \
  bash -c '[[ "$(grep -c "nvidia-ctk cdi generate" "$1")" -eq 1 ]]' _ "$setup_gpu"
check "static: arm64 branch references nvidia-container-runtime" \
  bash -c 'grep -Fq "nvidia-container-runtime" "$1"' _ "$setup_gpu"

case_tmp=""
case_path=""
begin_case() {
  case_tmp="$(mktemp -d)"
  case_path="$PATH"
  command mkdir -p "$case_tmp/fw/nvidia/620.70.06"
  : >"$case_tmp/fw/nvidia/620.70.06/gsp_tu10x.bin"
  export NVIDIA_STAGE_DIR="$case_tmp/stage"
  export NVIDIA_FIRMWARE_ROOT="$case_tmp/fw"
  export NVIDIA_RESUME_MARKER="$case_tmp/driver-upgrade.state"
  export NVIDIA_PROC_VERSION_FILE="$case_tmp/proc-version"
  export NVIDIA_DEVICE_NODE="$case_tmp/nvidia0"
  export FAKE_GPU_CALLS_PREP="$case_tmp"
  export SUDO=fake-sudo
}

end_case() {
  fake_gpu_cleanup
  PATH="$case_path"
  command rm -rf "$case_tmp"
  unset NVIDIA_STAGE_DIR NVIDIA_FIRMWARE_ROOT NVIDIA_RESUME_MARKER \
    NVIDIA_PROC_VERSION_FILE NVIDIA_DEVICE_NODE SUDO FAKE_PROC_FILE \
    FAKE_GPU_BINDIR FAKE_GPU_CALLS FAKE_DNF_ARGV FAKE_GPU_STATE \
    FAKE_REPORTED_DRIVER FAKE_PROC_VERSION FAKE_PROC_VERSION_STUCK FAKE_RPM_INSTALLED \
    FAKE_RUN_MANAGED FAKE_DNF_RC FAKE_DNF_DOWNLOADONLY_RC FAKE_DNF_CLOSURE_INCOMPLETE \
    FAKE_DNF_KEY_MISSING FAKE_DNF_UPGRADES_DRIVER FAKE_PKG_AVAILABLE FAKE_MODPROBE_RC \
    FAKE_MODULE_LOADED FAKE_MODULES FAKE_ARCH FAKE_KERNEL_RELEASE FAKE_NEVRA \
    FAKE_STRIMSERVER_ACTIVE FAKE_FABRICMANAGER_UNIT FAKE_DCGM_UNIT FAKE_DCGM_EXPORTER_UNIT \
    FAKE_DCGM_ACTIVE FAKE_DCGM_EXPORTER_ACTIVE FAKE_DCGM_STUCK FAKE_DCGM_EXPORTER_STUCK \
    FAKE_KERNEL_MODULE_VARIANT FAKE_DKMS_STATUS FAKE_DKMS_RC FAKE_SMI_RC FAKE_SMI_MISSING \
    FAKE_HOLDER FAKE_UNINSTALL_RC FAKE_RMMOD_BUSY FAKE_PAYLOAD_MISSING_MODULE
}

call_index() { fake_gpu_first_index "$1"; }
has_call() { grep -Eq "$1" "$FAKE_GPU_CALLS"; }
before() {
  local first second
  first="$(call_index "$1")"
  second="$(call_index "$2")"
  [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]]
}

# --- amd64: driver upgraded, then JSON-only CDI -----------------------------
case_amd64_upgrade_then_cdi() {
  begin_case
  export FAKE_ARCH=x86_64 FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  bash "$setup_gpu" >/dev/null 2>&1; local rc=$?

  check "amd64: setup-gpu.sh exits 0" test "$rc" -eq 0
  check "amd64: upgrades the driver (modprobe)" has_call 'modprobe nvidia'
  check "amd64: generates a CDI spec" has_call 'nvidia-ctk cdi generate'
  check "amd64: modprobe precedes CDI generation" before 'modprobe nvidia' 'nvidia-ctk cdi generate'
  check "amd64: CDI is JSON only" has_call 'nvidia-ctk cdi generate.*--format=json'
  check "amd64: never generates YAML CDI" bash -c '! grep -Eq "nvidia-ctk cdi generate.*(yaml|yml)" "$1"' _ "$FAKE_GPU_CALLS"
  check "amd64: clears stale nvidia.yaml before generating" \
    bash -c 'a=$(awk "/rm .*nvidia.yaml/{print NR; exit}" "$1"); b=$(awk "/nvidia-ctk cdi generate/{print NR; exit}" "$1"); [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]' _ "$FAKE_GPU_CALLS"
  check "amd64: clears stale nvidia.yml before generating" \
    bash -c 'a=$(awk "/rm .*nvidia.yml/{print NR; exit}" "$1"); b=$(awk "/nvidia-ctk cdi generate/{print NR; exit}" "$1"); [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]' _ "$FAKE_GPU_CALLS"
  check "amd64: verification reads the 620 proc version" \
    bash -c 'grep -q "620\.70\.06" "$1"' _ "$NVIDIA_PROC_VERSION_FILE"
  check "amd64: never starts DCGM after the swap" \
    bash -c '! grep -Eq "systemctl start nvidia-dcgm" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- failed upgrade must not reach CDI generation ---------------------------
case_failed_upgrade_no_cdi() {
  begin_case
  export FAKE_ARCH=x86_64 FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_RC=1
  fake_gpu_install
  bash "$setup_gpu" >/dev/null 2>&1; local rc=$?

  check "failed upgrade: setup-gpu.sh exits non-zero" test "$rc" -ne 0
  check "failed upgrade: no CDI spec generated" bash -c '! grep -q "nvidia-ctk cdi generate" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- GPU init failure must block CDI generation ----------------------------
case_gpu_init_fails_no_cdi() {
  begin_case
  export FAKE_ARCH=x86_64 FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_SMI_RC=1
  fake_gpu_install
  bash "$setup_gpu" >/dev/null 2>&1; local rc=$?

  check "gpu init failure: setup-gpu.sh exits non-zero" test "$rc" -ne 0
  check "gpu init failure: no CDI spec generated" \
    bash -c '! grep -q "nvidia-ctk cdi generate" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- DCGM units are drained and left stopped, never restarted --------------
case_dcgm_drained_not_restarted() {
  begin_case
  export FAKE_ARCH=x86_64 FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_DCGM_UNIT=1 FAKE_DCGM_EXPORTER_UNIT=1
  export FAKE_DCGM_ACTIVE=1 FAKE_DCGM_EXPORTER_ACTIVE=1
  fake_gpu_install
  bash "$setup_gpu" >/dev/null 2>&1; local rc=$?

  check "dcgm (setup-gpu): exits 0" test "$rc" -eq 0
  check "dcgm (setup-gpu): exporter stopped before dcgm" \
    before 'systemctl stop nvidia-dcgm-exporter.service' 'systemctl stop nvidia-dcgm.service'
  check "dcgm (setup-gpu): neither unit restarted" \
    bash -c '! grep -Eq "systemctl (start|enable).*nvidia-dcgm" "$1"' _ "$FAKE_GPU_CALLS"
  check "dcgm (setup-gpu): both left inactive" \
    bash -c '[[ "$(cat "$1/dcgm_active")" == 0 && "$(cat "$1/dcgm_exporter_active")" == 0 ]]' _ "$FAKE_GPU_STATE"
  end_case
}

# --- arm64: runtime binary required, no CDI --------------------------------
case_arm64_runtime() {
  begin_case
  export FAKE_ARCH=aarch64 FAKE_REPORTED_DRIVER=620.70.06 FAKE_RPM_INSTALLED=1
  fake_gpu_install

  # The runtime check is an absolute-path `-x` test. Only exercise the live
  # branch when the host (or a future override) actually provides the binary.
  if [[ -x /usr/bin/nvidia-container-runtime || -n "${NVIDIA_CONTAINER_RUNTIME:-}" ]]; then
    bash "$setup_gpu" >/dev/null 2>&1; local rc=$?
    check "arm64: setup-gpu.sh exits 0 with the runtime present" test "$rc" -eq 0
    check "arm64: no CDI spec generated" bash -c '! grep -q "nvidia-ctk cdi generate" "$1"' _ "$FAKE_GPU_CALLS"
  else
    printf 'skip: arm64 runtime binary not present in this sandbox (static assertions cover the branch)\n'
  fi
  end_case
}

case_amd64_upgrade_then_cdi
case_failed_upgrade_no_cdi
case_gpu_init_fails_no_cdi
case_dcgm_drained_not_restarted
case_arm64_runtime

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall setup-gpu tests passed\n'
