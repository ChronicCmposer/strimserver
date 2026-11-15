#!/usr/bin/env bash
# deploy_budget_test.sh -- the baked-AMI fast path must stay cheap.
#
# On a host that already has the driver, containerd config, htop and the
# OpenSSH RPM baked in, a full deploy must:
#   * run no real sleep and no blocking DDNS loop;
#   * never invoke dnf, setup-gpu.sh, or nvidia_ensure_driver_floor;
#   * NOT restart containerd when /etc/containerd/config.toml is already
#     canonical;
#   * import the three images as background jobs with one wait barrier that
#     finishes before the systemd service install;
#   * abort naming the failing image when a single import fails.
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
call_index() { awk -v pat="$1" '$0 ~ pat { print NR; exit }' "${FAKE_GPU_CALLS:?}"; }
count_calls() { grep -Ec "$1" "${FAKE_GPU_CALLS:?}" || true; }

begin_case() {
  case_tmp="$(mktemp -d)"
  case_out="$case_tmp/deploy.out"
  case_path="$PATH"
  export FAKE_ARCH=x86_64 FAKE_PROC_VERSION=620.70.06 FAKE_REPORTED_DRIVER=620.70.06
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
    FAKE_MOUNTPOINT_RC FAKE_CONTAINERD_ACTIVE FAKE_CONTAINERD_START_RC \
    FAKE_CONTAINERD_STAY_INACTIVE FAKE_DDNS_START_RC \
    FAKE_DDNS_VERIFY_START_RC FAKE_DDNS_STOP_RC FAKE_SYSTEMCTL_BLOCK_SECONDS \
    FAKE_INVOCATION_ID DEPLOY_M1_ELAPSED_OVERRIDE \
    DEPLOY_ROOT DEPLOY_LOGS_ROOT DEPLOY_LOCK_FILE 2>/dev/null || true
}

run_deploy() {
  local rc
  ( cd "$FAKE_DEPLOY_ROOT" && bash "$deploy_sh" ) >"$case_out" 2>&1
  rc=$?
  printf '%s' "$rc"
}

# --- case 1: full fast path budget ------------------------------------------
fast_path_budget_case() {
  begin_case
  local rc
  rc="$(run_deploy)"

  check "budget: deploy.sh exits 0" test "$rc" -eq 0
  check "budget: no real sleep on the fast path" test ! -s "$FAKE_DEPLOY_SLEEP_LOG"
  check "budget: no dnf invocation" test "$(count_calls '^dnf ')" -eq 0
  check "budget: no setup-gpu.sh invocation" not_called 'setup-gpu\.sh'
  check "budget: deploy.sh does not call nvidia_ensure_driver_floor" \
    bash -c '! grep -q "nvidia_ensure_driver_floor" "$1"' _ "$deploy_sh"
  check "budget: canonical config means no containerd restart" \
    test "$(count_calls 'systemctl restart containerd')" -eq 0
  check "budget: all three images imported" \
    test "$(count_calls '^sudo ctr -n strimserver i import (controller|ffmpeg|mediamtx)-container[.]tar')" -eq 3
  local import_idx install_idx
  import_idx="$(call_index ' i import ')"
  install_idx="$(call_index 'strimserver[.]service')"
  check "budget: import barrier completes before the service install" \
    bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$import_idx" "$install_idx"
  end_case
}
check "full fast path stays within budget" fast_path_budget_case

# --- case 2: a changed config restarts containerd once, BEFORE imports ------
changed_config_case() {
  begin_case
  printf "version = 2\nroot = '/stale'\n" \
    >"$FAKE_SYSROOT/etc/containerd/config.toml"
  local rc restart_idx import_idx
  rc="$(run_deploy)"
  check "changed config: deploy.sh exits 0" test "$rc" -eq 0
  check "changed config: containerd restarted exactly once" \
    test "$(count_calls '^sudo systemctl restart containerd')" -eq 1
  restart_idx="$(call_index '^sudo systemctl restart containerd')"
  import_idx="$(call_index '^sudo ctr .* i import ')"
  check "changed config: restart happens before image import" \
    bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$restart_idx" "$import_idx"
  end_case
}
check "a changed config restarts containerd once before imports" changed_config_case

# --- case 3: the three imports run in parallel ------------------------------
parallel_import_case() {
  export FAKE_CTR_DELAY=0.5
  begin_case
  local rc spread
  rc="$(run_deploy)"
  check "parallel: deploy.sh exits 0" test "$rc" -eq 0
  check "parallel: three import timestamps recorded" \
    test "$(wc -l <"$FAKE_CTR_STARTS")" -eq 3
  spread="$(awk 'NR==1{min=$1;max=$1} {if($1<min)min=$1; if($1>max)max=$1} END{print max-min}' "$FAKE_CTR_STARTS")"
  # Serial imports with a 0.5s each would span >= 1.0s; parallel spans ~0s.
  check "parallel: import start spread is far below serial (${spread}ns)" \
    test "$spread" -lt 450000000
  end_case
}
check "the three image imports run as background jobs" parallel_import_case

# --- case 4: one failing import aborts, naming the image --------------------
failed_import_case() {
  export FAKE_CTR_FAIL_IMAGE=ffmpeg
  begin_case
  local rc
  rc="$(run_deploy)"
  check "failed import: deploy.sh exits non-zero" test "$rc" -ne 0
  check "failed import: names the failing image" grep -q 'ffmpeg' "$case_out"
  check "failed import: no systemd service install after the barrier" \
    not_called 'strimserver\.service'
  end_case
}
check "a single import failure aborts and names the image" failed_import_case

# --- case 5: structural wall-clock budget -----------------------------------
# The configured bounds must sum to <= 240s: M1 target 60 + refresh
# TimeoutStartSec 30 + verify TimeoutStartSec 140 = 230. Wrappers (40/150) are
# backstops outside the budget. Structural, never wall-clock.
structural_budget_case() {
  local m1=60 refresh verify total
  refresh="$(awk -F= '/^TimeoutStartSec=/{print $2; exit}' "$script_dir/strim-ddns.service.template")"
  verify="$(awk -F= '/^TimeoutStartSec=/{print $2; exit}' "$script_dir/strim-ddns-verify.service.template")"
  total=$((m1 + ${refresh:-0} + ${verify:-0}))
  check "budget: refresh TimeoutStartSec is 30" test "${refresh:-}" = "30"
  check "budget: verify TimeoutStartSec is 140" test "${verify:-}" = "140"
  check "budget: systemd verify bound is under the 150s backstop" \
    bash -c '[ "$1" -lt 150 ]' _ "${verify:-0}"
  check "budget: systemd refresh bound is under the 40s backstop" \
    bash -c '[ "$1" -lt 40 ]' _ "${refresh:-0}"
  check "budget: M1 target 60 + refresh 30 + verify 140 <= 240" \
    bash -c '[ "$1" -le 240 ]' _ "$total"
  check "budget: deploy.sh carries the 60s M1 target" \
    grep -qE 'M1_ELAPSED.*-gt 60|over 60s target' "$deploy_sh"
  check "budget: deploy.sh has no unbounded sleep" \
    bash -c '! grep -Eq "(^|[;&|[:space:]])sleep[[:space:]]" "$1"' _ "$deploy_sh"
}
check "configured bounds sum within the 240s budget" structural_budget_case

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall deploy budget tests passed\n'
