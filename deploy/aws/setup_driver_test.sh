#!/usr/bin/env bash
# setup_driver_test.sh -- behavioural tests for nvidia_ensure_driver_floor.
#
# Every case runs the function against testutil_fake_gpu.sh with
# NVIDIA_STAGE_DIR / NVIDIA_FIRMWARE_ROOT / NVIDIA_RESUME_MARKER redirected
# into a temp dir and SUDO=fake-sudo. The recorded call log is then asserted
# for ordering: stage before uninstall, drain before rmmod, depmod before
# rmmod, rmmod before modprobe, and no `reboot` anywhere.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nvidia.sh
source "$script_dir/lib/nvidia.sh"
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
  export SUDO=fake-sudo
}

end_case() {
  fake_gpu_cleanup
  PATH="$case_path"
  command rm -rf "$case_tmp"
  unset NVIDIA_STAGE_DIR NVIDIA_FIRMWARE_ROOT NVIDIA_RESUME_MARKER SUDO \
    FAKE_REPORTED_DRIVER FAKE_RPM_INSTALLED FAKE_RUN_MANAGED FAKE_UNINSTALL_RC \
    FAKE_RMMOD_BUSY FAKE_DNF_UPGRADES_DRIVER FAKE_PKG_AVAILABLE FAKE_SMI_RC \
    FAKE_SMI_MISSING FAKE_MODPROBE_RC FAKE_MODULE_LOADED FAKE_STRIMSERVER_ACTIVE \
    FAKE_FABRICMANAGER_UNIT FAKE_ARCH FAKE_NEVRA FAKE_HOLDER
}

# First recorded line matching the ERE, or empty.
call_index() { fake_gpu_first_index "$1"; }
before() {
  local first second
  first="$(call_index "$1")"
  second="$(call_index "$2")"
  [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]]
}
has_call() { grep -Eq "$1" "$FAKE_GPU_CALLS"; }

# --- 1. upgrade path (RPM installed, below floor) ----------------------------
case_upgrade() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "upgrade: exits 0" test "$rc" -eq 0
  check "upgrade: stages the pinned RPM" has_call 'dnf download'
  check "upgrade: installs the staged RPM" has_call 'dnf install.*--allowerasing'
  check "upgrade: runs depmod -a" has_call 'depmod -a'
  check "upgrade: stops strimserver.service" has_call 'systemctl stop strimserver.service'
  check "upgrade: stops nvidia-persistenced" has_call 'systemctl stop nvidia-persistenced'
  check "upgrade: stops containerd.service" has_call 'systemctl stop containerd.service'
  check "upgrade: drains before rmmod" before 'systemctl stop strimserver.service' 'rmmod nvidia'
  check "upgrade: stages before installing" before 'dnf download' 'dnf install'
  check "upgrade: drains before installing" before 'systemctl stop strimserver.service' 'dnf install'
  check "upgrade: stops containerd before installing" before 'systemctl stop containerd.service' 'dnf install'
  check "upgrade: holder check runs before installing" before 'fuser -v /dev/nvidia' 'dnf install'
  check "upgrade: selects the amd64 NEVRA" has_call 'dnf download.*nvidia-open-3:620\.70\.06-1\.el9'
  check "upgrade: does not select the arm64 NEVRA" bash -c '! grep -q "nvidia-open-620.70.06-1.amzn2023.noarch" "$1"' _ "$FAKE_GPU_CALLS"
  check "upgrade: depmod before rmmod" before 'depmod -a' 'rmmod nvidia'
  check "upgrade: rmmod before modprobe" before 'rmmod nvidia' 'modprobe nvidia'
  check "upgrade: restores nvidia-persistenced" has_call 'systemctl start nvidia-persistenced'
  check "upgrade: never restarts containerd itself" bash -c '! grep -q "systemctl restart containerd" "$1"' _ "$FAKE_GPU_CALLS"
  check "upgrade: never runs reboot" bash -c '! grep -qi "reboot" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- 2. no-op at the floor ---------------------------------------------------
case_noop() {
  begin_case
  export FAKE_REPORTED_DRIVER=620.70.06 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "no-op: exits 0" test "$rc" -eq 0
  check "no-op: performs no download" bash -c '! grep -q "dnf download" "$1"' _ "$FAKE_GPU_CALLS"
  check "no-op: performs no rmmod" bash -c '! grep -q "rmmod" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- 3. newer driver is never downgraded ------------------------------------
case_newer() {
  begin_case
  export FAKE_REPORTED_DRIVER=630.1.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "newer: exits 0" test "$rc" -eq 0
  check "newer: performs no download" bash -c '! grep -q "dnf download" "$1"' _ "$FAKE_GPU_CALLS"
  check "newer: performs no install" bash -c '! grep -q "dnf install" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- 4. package missing: stage fails before anything destructive ------------
case_package_missing() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_PKG_AVAILABLE=0
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "package missing: fails" test "$rc" -ne 0
  check "package missing: message names the download failure" bash -c 'grep -qi "download\|package" <<<"$1"' _ "$out"
  check "package missing: no uninstall attempted" bash -c '! grep -q "nvidia-uninstall" "$1"' _ "$FAKE_GPU_CALLS"
  check "package missing: no rmmod attempted" bash -c '! grep -q "rmmod" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- 5. .run-managed host, uninstall fails ----------------------------------
case_uninstall_failure() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1 FAKE_UNINSTALL_RC=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "uninstall failure: fails" test "$rc" -ne 0
  check "uninstall failure: message names uninstall" bash -c 'grep -qi "uninstall" <<<"$1"' _ "$out"
  check "uninstall failure: stage precedes uninstall" before 'dnf download' 'nvidia-uninstall'
  check "uninstall failure: no dnf install after the failure" bash -c '! grep -q "dnf install" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- 6. rmmod busy (holder still present) -----------------------------------
case_rmmod_busy() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_RMMOD_BUSY=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "rmmod busy: fails" test "$rc" -ne 0
  check "rmmod busy: message names rmmod/in-use" bash -c 'grep -Eqi "rmmod|in use" <<<"$1"' _ "$out"
  check "rmmod busy: never reaches modprobe" bash -c '! grep -q "modprobe" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

# --- 7. install did not actually raise the version --------------------------
case_still_below_floor() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_UPGRADES_DRIVER=0
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "still-below-floor: fails" test "$rc" -ne 0
  check "still-below-floor: message names the floor" bash -c 'grep -qi "still\|below\|floor" <<<"$1"' _ "$out"
  end_case
}

# --- 8. no nvidia-smi binary, RPM installed ---------------------------------
case_no_smi_binary() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_SMI_MISSING=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "no nvidia-smi + RPM: exits 0" test "$rc" -eq 0
  check "no nvidia-smi + RPM: still stages the RPM" has_call 'dnf download'
  end_case
}

# --- 9. nvidia-smi present but non-zero (module unloaded) -------------------
case_smi_nonzero() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_SMI_RC=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "nvidia-smi rc!=0 + RPM: exits 0" test "$rc" -eq 0
  check "nvidia-smi rc!=0 + RPM: stages the RPM" has_call 'dnf download'
  end_case
}

# --- 10. .run-managed host upgrades successfully -----------------------------
# Exercises the nvidia-uninstall path so the drain/holder ordering can be
# asserted against BOTH the uninstall and the RPM install.
case_run_managed_upgrade() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1
  export FAKE_NEVRA="nvidia-open-3:620.70.06-1.el9.x86_64"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "run-managed: exits 0" test "$rc" -eq 0
  check "run-managed: drains before uninstall" before 'systemctl stop strimserver.service' 'nvidia-uninstall'
  check "run-managed: stops containerd before uninstall" before 'systemctl stop containerd.service' 'nvidia-uninstall'
  check "run-managed: holder check before uninstall" before 'fuser -v /dev/nvidia' 'nvidia-uninstall'
  check "run-managed: drains before installing" before 'systemctl stop strimserver.service' 'dnf install'
  check "run-managed: holder check before installing" before 'fuser -v /dev/nvidia' 'dnf install'
  check "run-managed: uninstall before installing" before 'nvidia-uninstall' 'dnf install'
  end_case
}

# --- 11. arm64 host selects the arm64 NEVRA ---------------------------------
case_arm64_nevra() {
  begin_case
  export FAKE_ARCH=aarch64 FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_NEVRA="nvidia-open-620.70.06-1.amzn2023.noarch"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "arm64: exits 0" test "$rc" -eq 0
  check "arm64: selects the arm64 NEVRA" has_call 'dnf download.*nvidia-open-620\.70\.06-1\.amzn2023\.noarch'
  check "arm64: does not select the amd64 NEVRA" bash -c '! grep -q "nvidia-open-3:620.70.06-1.el9" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

case_upgrade
case_noop
case_newer
case_package_missing
case_uninstall_failure
case_rmmod_busy
case_still_below_floor
case_no_smi_binary
case_smi_nonzero
case_run_managed_upgrade
case_arm64_nevra

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall setup-driver tests passed\n'
