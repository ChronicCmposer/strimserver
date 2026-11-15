#!/usr/bin/env bash
# deploy_floor_check_test.sh -- execution tests for deploy/aws/deploy.sh's
# baked-AMI fast path.
#
# deploy.sh no longer runs setup-gpu.sh on the host. The driver floor is baked
# into the AMI, so deploy.sh must:
#   * fail FAST with actionable remediation when the loaded driver is below the
#     NVIDIA_DRIVER_FLOOR (naming the baked AMI, the /strimserver/ami/baked/latest
#     SSM parameter, and setup-gpu.sh), without invoking setup-gpu.sh or
#     nvidia_ensure_driver_floor;
#   * generate the amd64 CDI JSON spec at deploy time
#     (nvidia-ctk cdi generate --format=json --output=/var/run/cdi/nvidia.json)
#     and keep the /etc/cdi copy, all without setup-gpu.sh.
#
# The whole flow runs against testutil_fake_gpu.sh + its optional deploy
# sandbox (DEPLOY_ROOT + fake-sudo sysroot), so no root or /mnt/nvme is needed.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_sh="$script_dir/deploy.sh"
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
has_call() { grep -Eq "$1" "${FAKE_GPU_CALLS:?}"; }
not_called() { ! grep -Eq "$1" "${FAKE_GPU_CALLS:?}"; }

begin_case() {
  case_tmp="$(mktemp -d)"
  case_out="$case_tmp/deploy.out"
  case_path="$PATH"
  fake_gpu_install
  fake_deploy_install
  fake_deploy_seed_baseline
}

end_case() {
  fake_deploy_cleanup
  fake_gpu_cleanup
  PATH="$case_path"
  rm -rf "$case_tmp"
  unset NVIDIA_PROC_VERSION_FILE NVIDIA_DEVICE_NODE NVIDIA_STAGE_DIR \
    NVIDIA_FIRMWARE_ROOT NVIDIA_RESUME_MARKER SUDO FAKE_ARCH FAKE_PROC_VERSION \
    FAKE_REPORTED_DRIVER FAKE_RPM_INSTALLED FAKE_PUBLIC_IP FAKE_CTR_DELAY \
    FAKE_CTR_FAIL_IMAGE FAKE_GPU_BINDIR FAKE_GPU_CALLS FAKE_GPU_STATE \
    FAKE_DNF_ARGV FAKE_PROC_FILE FAKE_SUDO_ACTIVE FAKE_DEPLOY_BINDIR \
    FAKE_DEPLOY_ROOT FAKE_SYSROOT FAKE_DEPLOY_SLEEP_LOG FAKE_CTR_STARTS \
    DEPLOY_ROOT DEPLOY_LOGS_ROOT 2>/dev/null || true
}

run_deploy() {
  local rc
  ( cd "$FAKE_DEPLOY_ROOT" && bash "$deploy_sh" ) >"$case_out" 2>&1
  rc=$?
  printf '%s' "$rc"
}

# --- case 1: below-floor loaded driver fails fast with remediation ----------
below_floor_case() {
  export FAKE_ARCH=x86_64 FAKE_PROC_VERSION=610.0.0 FAKE_REPORTED_DRIVER=610.0.0
  begin_case
  local rc
  rc="$(run_deploy)"

  check "below floor: deploy.sh exits 1" test "$rc" -eq 1
  check "below floor: names the baked AMI" grep -q 'baked AMI' "$case_out"
  check "below floor: names the SSM parameter" \
    grep -q '/strimserver/ami/baked/latest' "$case_out"
  check "below floor: names setup-gpu.sh as remediation" \
    grep -q 'setup-gpu\.sh' "$case_out"
  check "below floor: aborts before CDI generation" \
    not_called 'nvidia-ctk cdi generate'
  check "below floor: aborts before image import" not_called ' i import '
  check "below floor: does not restart containerd" \
    not_called 'systemctl restart containerd'
  end_case
}
check "below-floor driver fails fast and aborts early" below_floor_case

# --- case 2: floor met -> amd64 CDI generated at deploy time ----------------
floor_met_cdi_case() {
  export FAKE_ARCH=x86_64 FAKE_PROC_VERSION=620.70.06 FAKE_REPORTED_DRIVER=620.70.06
  begin_case
  local rc
  rc="$(run_deploy)"

  check "floor met: deploy.sh exits 0" test "$rc" -eq 0
  check "floor met: generates JSON CDI at /var/run/cdi" \
    has_call 'nvidia-ctk cdi generate --format=json --output=/var/run/cdi/nvidia.json'
  check "floor met: copies the spec into /etc/cdi" \
    has_call 'sudo cp /var/run/cdi/nvidia.json /etc/cdi/nvidia.json'
  check "floor met: /var/run/cdi/nvidia.json exists" \
    test -f "$FAKE_SYSROOT/var/run/cdi/nvidia.json"
  check "floor met: /etc/cdi/nvidia.json exists" \
    test -f "$FAKE_SYSROOT/etc/cdi/nvidia.json"
  check "floor met: clears stale YAML before generating" \
    bash -c 'a=$(awk "/rm .*nvidia.yaml/{print NR; exit}" "$1"); b=$(awk "/nvidia-ctk cdi generate/{print NR; exit}" "$1"); [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]' \
    _ "$FAKE_GPU_CALLS"
  local dropin="$FAKE_SYSROOT/etc/systemd/system/containerd.service.d/10-strimserver-nvme.conf"
  check "floor met: installs the canonical containerd NVMe drop-in" test -f "$dropin"
  check "floor met: drop-in bytes match the repo file" \
    bash -c 'cmp -s "$1" "$2"' _ "$dropin" "$script_dir/containerd-nvme.conf"
  check "floor met: daemon-reload after the drop-in install" \
    has_call 'systemctl daemon-reload'
  end_case
}
check "floor met: amd64 CDI spec generated at deploy time" floor_met_cdi_case

# --- static: the runtime fast path never shells out to setup-gpu.sh ---------
fast_path_static_checks() {
  grep -q 'lib/nvidia.sh' "$deploy_sh" || return 1
  ! grep -qE '^[[:space:]]*bash[[:space:]]+\./setup-gpu\.sh' "$deploy_sh" || return 1
  ! grep -q 'nvidia_ensure_driver_floor' "$deploy_sh" || return 1
  grep -q 'NVIDIA_DRIVER_FLOOR' "$deploy_sh" || return 1
  # The NVMe drop-in is installed from the repo file with compare-before-apply.
  grep -q 'containerd-nvme.conf' "$deploy_sh" || return 1
  grep -q 'cmp -s "\$DEPLOY_ROOT/containerd-nvme.conf"' "$deploy_sh" || return 1
}
check "static: deploy.sh asserts the floor without setup-gpu.sh" fast_path_static_checks

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall deploy floor-check tests passed\n'
