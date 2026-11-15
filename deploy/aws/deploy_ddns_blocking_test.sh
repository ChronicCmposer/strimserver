#!/usr/bin/env bash
# deploy_ddns_blocking_test.sh -- deploy.sh's blocking two-milestone contract.
#
# Replaces the former deploy_ddns_async_test.sh. With ENABLE_DDNS=true the deploy
# now BLOCKS on two bounded unit starts after M1:
#   sudo timeout -k 5 40  systemctl start strim-ddns.service        (refresh)
#   sudo timeout -k 5 150 systemctl start strim-ddns-verify.service (verify)
# Every install/render/reload/enable/disable happens before the M1 line; the
# success-only payload cleanup and the M2 line come after. The test drives the
# whole flow against testutil_fake_gpu.sh's deploy sandbox (fake sudo/sysroot +
# ctr/systemctl/journalctl/timeout/mountpoint), so no root or /mnt/nvme is used.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_sh="$script_dir/deploy.sh"
refresh_template="$script_dir/strim-ddns.service.template"
verify_template="$script_dir/strim-ddns-verify.service.template"
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
line_of() { grep -nF -- "$1" "$2" | head -1 | cut -d: -f1; }

begin_case() {
  case_tmp="$(mktemp -d)"
  case_out="$case_tmp/deploy.out"
  case_path="$PATH"
  export FAKE_ARCH=x86_64 FAKE_PROC_VERSION=620.70.06 FAKE_REPORTED_DRIVER=620.70.06
  export FAKE_PUBLIC_IP=203.0.113.10
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
    FAKE_INVOCATION_ID DEPLOY_M1_ELAPSED_OVERRIDE FAKE_PGREP_RC \
    DEPLOY_ROOT DEPLOY_LOGS_ROOT DEPLOY_LOCK_FILE 2>/dev/null || true
}

enable_ddns() {
  printf 'ENABLE_DDNS=true\nDDNS_HOST=strim\nDDNS_DOMAIN=example.com\n' \
    >"$FAKE_DEPLOY_ROOT/config/strimserver.env"
  printf 'ddns-secret\n' >"$FAKE_DEPLOY_ROOT/ddns-password"
}

run_deploy() {
  local rc
  ( cd "$FAKE_DEPLOY_ROOT" && bash "$deploy_sh" ) >"$case_out" 2>&1
  rc=$?
  printf '%s' "$rc"
}

start_deploy_bg() {
  ( cd "$FAKE_DEPLOY_ROOT" && exec env --default-signal=HUP --default-signal=INT --default-signal=TERM bash "$deploy_sh" ) >"$case_out" 2>&1 &
  deploy_pid=$!
}

wait_for_call() {
  local pattern="$1" waited=0
  while [ "$waited" -lt 200 ]; do
    if grep -Eq "$pattern" "${FAKE_GPU_CALLS:?}" 2>/dev/null; then
      return 0
    fi
    /bin/sleep 0.05
    waited=$((waited + 1))
  done
  return 1
}

# ===========================================================================
# static contract checks (the artifact is the contract)
# ===========================================================================
static_checks() {
  # Every systemctl start/stop/disable is wrapped as sudo timeout -k 5 <n> ...
  awk '/systemctl (start|stop|disable)/ && !/printf/ && !/sudo timeout -k 5 [0-9]+ systemctl (start|stop|disable)/ { bad=1 } END { exit bad ? 1 : 0 }' "$deploy_sh" || return 1
  grep -q "trap '' PIPE HUP INT TERM" "$deploy_sh" || return 1
  grep -q 'trap deploy_finish EXIT' "$deploy_sh" || return 1
  grep -q "trap 'exit 129' HUP" "$deploy_sh" || return 1
  grep -q "trap 'exit 130' INT" "$deploy_sh" || return 1
  grep -q "trap 'exit 143' TERM" "$deploy_sh" || return 1
  grep -q 'flock -n 9' "$deploy_sh" || return 1
  # The lock file is created with its mode pinned (idempotent on reruns); a bare
  # sudo touch would leave a pre-existing 0600 file unreadable by exec 9<.
  grep -qF 'sudo install -m 0644 -o root -g root /dev/null "$LOCK_FILE"' "$deploy_sh" || return 1
  ! grep -qF 'sudo touch "$LOCK_FILE"' "$deploy_sh" || return 1
  grep -qF 'exec 9<"$LOCK_FILE"' "$deploy_sh" || return 1
  grep -q 'flock -u 9' "$deploy_sh" || return 1
  # Read-only observers close fd 9. The orphan-import guard (not fd inheritance)
  # is what makes a SIGKILLed deploy block a rerun.
  grep -q 'strim-ddns-verify.service 9<&-' "$deploy_sh" || return 1
  grep -qF 'exec tee -a --output-error=warn "$DEPLOY_LOG"' "$deploy_sh" || return 1
  grep -q 'exec 9<&-; exec tee' "$deploy_sh" || return 1
  # A live in-flight import orphan is rejected with exit 5 after flock.
  grep -qF "timeout -k 5 5 pgrep -f 'ctr .* i import'" "$deploy_sh" || return 1
  # The withdrawn fd-9-in-children claim must be gone.
  ! grep -q 'children keep fd 9' "$deploy_sh" || return 1
  ! grep -q 'still holds the deploy lock' "$deploy_sh" || return 1
  # Deploy log dir is traversable by the unprivileged tee and trap writer.
  grep -qF 'sudo install -d -m 0755 -o root -g root "$LOG_DIRECTORY"' "$deploy_sh" || return 1
  ! grep -q 'install -d -m 0750' "$deploy_sh" || return 1
  # DDNS env merge is the lib helper, not an inline re-implementation.
  grep -qF 'deploy_write_ddns_env_settings "$ENV_FILE" "$DDNS_CONFIG_FILE"' "$deploy_sh" || return 1
  ! grep -q 'ddns_assignment' "$deploy_sh" || return 1
  ! grep -q 'for ddns_key in' "$deploy_sh" || return 1
  # No unbounded sleep and no 24-attempt loop in deploy.sh itself.
  ! grep -Eq '(^|[;&|[:space:]])sleep[[:space:]]' "$deploy_sh" || return 1
  ! grep -q 'seq 1 24' "$deploy_sh" || return 1
  # The DDNS settings are resolved before the refresh timer is enabled.
  local env_line timer_line
  env_line="$(line_of 'ENABLE_DDNS="${ENABLE_DDNS:-false}"' "$deploy_sh")"
  timer_line="$(line_of 'enable --now strim-ddns.timer' "$deploy_sh")"
  [ -n "$env_line" ] && [ -n "$timer_line" ] && [ "$env_line" -lt "$timer_line" ] || return 1
  # Config validation and IMDS resolution precede the import barrier.
  local config_line imds_line import_line
  config_line="$(line_of 'ddns_missing' "$deploy_sh")"
  imds_line="$(line_of 'get_public_ip' "$deploy_sh")"
  import_line="$(line_of 'import_names=(controller' "$deploy_sh")"
  [ -n "$config_line" ] && [ -n "$imds_line" ] && [ -n "$import_line" ] \
    && [ "$config_line" -lt "$import_line" ] && [ "$imds_line" -lt "$import_line" ] || return 1
  # The orphan-import guard runs after the flock and before consuming work.
  local flock_line pgrep_line mount_line
  flock_line="$(line_of 'flock -n 9' "$deploy_sh")"
  pgrep_line="$(line_of 'pgrep -f ' "$deploy_sh")"
  mount_line="$(line_of 'mountpoint -q /mnt/nvme' "$deploy_sh")"
  [ -n "$flock_line" ] && [ -n "$pgrep_line" ] && [ -n "$mount_line" ] \
    && [ "$flock_line" -lt "$pgrep_line" ] && [ "$pgrep_line" -lt "$mount_line" ]
}
check "static: pinned trap/flock/fd-9/preamble-order contract" static_checks
check "static: no bare systemctl start/stop/disable" \
  bash -c 'awk "/systemctl (start|stop|disable)/ && !/printf/ && !/sudo timeout -k 5 [0-9]+ systemctl (start|stop|disable)/ { bad=1 } END { exit bad ? 1 : 0 }" "$1"' _ "$deploy_sh"
check "static: every IMDS curl is bounded by --max-time 5" \
  bash -c 'n=$(grep -Ec "(^|[^[:alnum:]_])curl " "$1"); b=$(grep -E "(^|[^[:alnum:]_])curl " "$1" | grep -c -- "--max-time 5"); [ "$n" -gt 0 ] && [ "$n" -eq "$b" ]' _ "$script_dir/imdslib.sh"

# ===========================================================================
# 1. enabled happy path
# ===========================================================================
ddns_enabled_happy_case() {
  begin_case
  enable_ddns
  local rc
  rc="$(run_deploy)"

  check "enabled: deploy.sh exits 0" test "$rc" -eq 0
  check "enabled: M1 line present" grep -q '^M1: service ready (' "$case_out"
  check "enabled: M2 line present" grep -q '^M2: DDNS verified, deploy complete (' "$case_out"
  check "enabled: M2 is the last output line" \
    bash -c '[ "$(grep -v "^$" "$1" | tail -1)" = "$(grep "^M2:" "$1")" ]' _ "$case_out"
  check "enabled: M1 precedes M2" \
    bash -c 'a=$(grep -n "^M1:" "$1" | cut -d: -f1); b=$(grep -n "^M2:" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$case_out"

  # The DDNS block (between M1 and M2) performs no setup work.
  sed -n '/^M1:/,/^M2:/p' "$case_out" >"$case_tmp/ddns_block.txt"
  check "enabled: DDNS block has no install" bash -c '! grep -Eq "install " "$1"' _ "$case_tmp/ddns_block.txt"
  check "enabled: DDNS block has no render" bash -c '! grep -q "sed " "$1"' _ "$case_tmp/ddns_block.txt"
  check "enabled: DDNS block has no daemon-reload" bash -c '! grep -q "daemon-reload" "$1"' _ "$case_tmp/ddns_block.txt"
  check "enabled: DDNS block has no enable/disable" bash -c '! grep -Eq "enable --now|systemctl disable" "$1"' _ "$case_tmp/ddns_block.txt"
  check "enabled: DDNS block has no import" bash -c '! grep -q "i import" "$1"' _ "$case_tmp/ddns_block.txt"

  # Exactly the two bounded starts, refresh before verify, timeout inside sudo.
  check "enabled: refresh is sudo timeout -k 5 40 systemctl start" \
    has_call 'sudo timeout -k 5 40 systemctl start strim-ddns.service$'
  check "enabled: verify is sudo timeout -k 5 150 systemctl start" \
    has_call 'sudo timeout -k 5 150 systemctl start strim-ddns-verify.service$'
  local refresh_idx verify_idx
  refresh_idx="$(call_index 'sudo timeout -k 5 40 systemctl start strim-ddns.service$')"
  verify_idx="$(call_index 'sudo timeout -k 5 150 systemctl start strim-ddns-verify.service$')"
  check "enabled: refresh starts before verify" \
    bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$refresh_idx" "$verify_idx"

  # The strim-ddns image joined the parallel import barrier (before M1).
  local import_idx refresh_idx2
  import_idx="$(call_index ' i import strim-ddns-container.tar')"
  refresh_idx2="$(call_index 'sudo timeout -k 5 40 systemctl start strim-ddns.service$')"
  check "enabled: strim-ddns image imported before the DDNS block" \
    bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$import_idx" "$refresh_idx2"
  check "enabled: strim-ddns image imported only once" \
    test "$(count_calls '^sudo ctr .* i import strim-ddns-container.tar')" -eq 1

  # Pre-M1 setup: verify unit installed, rendered, and disabled (migration).
  local unit="$FAKE_SYSROOT/etc/systemd/system/strim-ddns-verify.service"
  check "enabled: rendered verify unit installed" test -f "$unit"
  check "enabled: verify unit bakes the expected IP" grep -q '203.0.113.10' "$unit"
  check "enabled: no __EXPECTED_IP__ placeholder remains" bash -c '! grep -q "__EXPECTED_IP__" "$1"' _ "$unit"
  check "enabled: verify unit drops the stderr redirect (defect #12)" \
    bash -c '! grep -q "2>/dev/null" "$1"' _ "$unit"
  check "enabled: verify unit owns attempt counting" grep -q 'attempt ' "$unit"
  check "enabled: verify unit emits verified-after line" grep -q 'verified after ' "$unit"
  check "enabled: verify unit has no fixed attempt count" bash -c '! grep -q "seq 1 24" "$1"' _ "$unit"
  check "enabled: verify unit passes the expected IP positionally" \
    grep -qF 'check "$$DDNS_HOST" "$$DDNS_DOMAIN" "203.0.113.10"' "$unit"

  local disable_idx timer_idx
  disable_idx="$(call_index 'sudo timeout -k 5 10 systemctl disable strim-ddns-verify.service')"
  timer_idx="$(call_index 'systemctl enable --now strim-ddns.timer')"
  check "enabled: verify unit disabled (migration) before the timer is enabled" \
    bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$disable_idx" "$timer_idx"

  # Journal follower is cursor-scoped and records the invocation-scoped tail.
  check "enabled: cursor captured via sudo journalctl --show-cursor" \
    has_call 'sudo journalctl --show-cursor -n 0'
  check "enabled: follower uses --after-cursor ... -f -u verify" \
    has_call 'sudo journalctl --after-cursor .* -f -u strim-ddns-verify.service'
  check "enabled: deploy-last.rc recorded 0" \
    test "$(cat "$FAKE_DEPLOY_ROOT/logs/deploy-last.rc")" = "0"
  check "enabled: deploy log exists and ends with M2" \
    bash -c 'f=$(ls -1t "$1"/deploy-*.log | head -1); [ "$(grep -v "^$" "$f" | tail -1)" = "$(grep "^M2:" "$f")" ]' _ "$FAKE_DEPLOY_ROOT/logs"
  check "enabled: deploy log pre-created 0640" \
    bash -c '[ "$(stat -c %a "$(ls -1t "$1"/deploy-*.log | head -1)")" = "640" ]' _ "$FAKE_DEPLOY_ROOT/logs"
  check "enabled: deploy log directory is traversable (0755)" \
    bash -c '[ "$(stat -c %a "$1")" = "755" ]' _ "$FAKE_DEPLOY_ROOT/logs"
  check "enabled: tee wrote to the pre-created log (log dir usable)" \
    grep -q 'M2: DDNS verified' "$(ls -1t "$FAKE_DEPLOY_ROOT"/logs/deploy-*.log | head -1)"
  check "enabled: orphan-import guard ran before consuming work" \
    has_call '^pgrep -f ctr .* i import$'
  check "enabled: success cleanup removed deploy.sh" \
    test ! -f "$FAKE_DEPLOY_ROOT/deploy.sh"
  check "enabled: disabled-path disables were not run" \
    not_called 'systemctl disable --now strim-ddns.timer'
  end_case
}
check "enabled DDNS: two-milestone blocking contract" ddns_enabled_happy_case

# ===========================================================================
# 2. refresh failure and backstop
# ===========================================================================
refresh_failure_case() {
  begin_case
  enable_ddns
  export FAKE_DDNS_START_RC=1
  local rc
  rc="$(run_deploy)"

  check "refresh failure: exits 3" test "$rc" -eq 3
  check "refresh failure: names the refresh stage" grep -q 'strim-ddns.service' "$case_out"
  check "refresh failure: M1 was printed, M2 was not" \
    bash -c 'grep -q "^M1:" "$1" && ! grep -q "^M2:" "$1"' _ "$case_out"
  check "refresh failure: images and service install stay in place" \
    has_call ' i import controller-container.tar'
  end_case
}
check "refresh failure exits 3 naming the refresh stage" refresh_failure_case

refresh_backstop_case() {
  begin_case
  enable_ddns
  export FAKE_DDNS_START_RC=124
  local rc
  rc="$(run_deploy)"

  check "refresh backstop: exits 4" test "$rc" -eq 4
  check "refresh backstop: stopped the timed-out unit" \
    has_call 'sudo timeout -k 5 150 systemctl stop strim-ddns.service$'
  check "refresh backstop: names the refresh stage" grep -q 'strim-ddns.service' "$case_out"
  end_case
}
check "refresh backstop (rc 124) stops the unit and exits 4" refresh_backstop_case

# ===========================================================================
# 3. verify failure and backstop
# ===========================================================================
verify_failure_case() {
  begin_case
  enable_ddns
  export FAKE_DDNS_VERIFY_START_RC=1
  local rc
  rc="$(run_deploy)"

  check "verify failure: exits 3" test "$rc" -eq 3
  check "verify failure: names the verify stage" grep -q 'strim-ddns-verify.service' "$case_out"
  check "verify failure: tail scoped by InvocationID" \
    has_call 'sudo journalctl _SYSTEMD_INVOCATION_ID='
  check "verify failure: remediation names the journal unit" \
    grep -q 'journalctl -u strim-ddns-verify' "$case_out"
  check "verify failure: M2 was not printed" bash -c '! grep -q "^M2:" "$1"' _ "$case_out"
  end_case
}
check "verify failure exits 3 naming the verify stage" verify_failure_case

verify_backstop_case() {
  begin_case
  enable_ddns
  export FAKE_DDNS_VERIFY_START_RC=137
  local rc
  rc="$(run_deploy)"

  check "verify backstop: exits 4" test "$rc" -eq 4
  check "verify backstop: stops the wedged verify unit" \
    has_call 'sudo timeout -k 5 150 systemctl stop strim-ddns-verify.service$'
  check "verify backstop: names the verify stage" grep -q 'strim-ddns-verify.service' "$case_out"
  end_case
}
check "verify backstop (rc 137) stops the unit and exits 4" verify_backstop_case

verify_backstop_stop_failure_case() {
  begin_case
  enable_ddns
  export FAKE_DDNS_VERIFY_START_RC=137 FAKE_DDNS_STOP_RC=1
  local rc
  rc="$(run_deploy)"

  check "stop failure: still exits 4" test "$rc" -eq 4
  check "stop failure: loud unit-may-still-be-running warning" \
    grep -q 'unit may still be running; inspect systemctl status strim-ddns-verify.service' "$case_out"
  end_case
}
check "a failing cleanup stop warns loudly and still exits 4" verify_backstop_stop_failure_case

# ===========================================================================
# 4. ENABLE_DDNS=false disable path
# ===========================================================================
ddns_disabled_case() {
  begin_case
  local rc
  rc="$(run_deploy)"

  check "disabled: exits 0" test "$rc" -eq 0
  check "disabled: prints the disabled M2 literally last" \
    bash -c '[ "$(grep -v "^$" "$1" | tail -1)" = "M2: deploy complete (DDNS disabled)" ]' _ "$case_out"
  check "disabled: disables the refresh timer" \
    has_call 'sudo timeout -k 5 10 systemctl disable --now strim-ddns.timer'
  check "disabled: disables verify enablement" \
    has_call 'sudo timeout -k 5 10 systemctl disable strim-ddns-verify.service'
  check "disabled: tolerantly stops both services" \
    has_call 'sudo timeout -k 5 10 systemctl stop strim-ddns.service strim-ddns-verify.service'
  check "disabled: no DDNS units installed" not_called 'install .*strim-ddns'
  check "disabled: no DDNS unit started" not_called 'systemctl start strim-ddns'
  check "disabled: strim-ddns image was not imported" \
    not_called ' i import strim-ddns-container.tar'
  end_case
}
check "ENABLE_DDNS=false runs the bounded disable path and exits 0" ddns_disabled_case

# ===========================================================================
# 5. missing config fails fast before imports
# ===========================================================================
missing_config_case() {
  begin_case
  printf 'ENABLE_DDNS=true\nDDNS_HOST=strim\nDDNS_DOMAIN=\n' \
    >"$FAKE_DEPLOY_ROOT/config/strimserver.env"
  printf 'ddns-secret\n' >"$FAKE_DEPLOY_ROOT/ddns-password"
  local rc
  rc="$(run_deploy)"

  check "missing config: exits 1" test "$rc" -eq 1
  check "missing config: names DDNS_DOMAIN" grep -q 'DDNS_DOMAIN' "$case_out"
  check "missing config: no image import happened" not_called ' i import '
  check "missing config: M1 was not printed" bash -c '! grep -q "^M1:" "$1"' _ "$case_out"
  end_case
}
check "missing DDNS config fails fast (exit 1) before imports" missing_config_case

# ===========================================================================
# 5b. DDNS env merge: lib helper, idempotent, missing env fatal
# ===========================================================================
ddns_env_merge_case() {
  begin_case
  printf 'ENABLE_DDNS=false\nTWITCH_STREAM_KEY="keep-me"\n' \
    >"$FAKE_DEPLOY_ROOT/config/strimserver.env"
  printf 'ENABLE_DDNS=true\nDDNS_HOST=strim\nDDNS_DOMAIN=example.com\n' \
    >"$FAKE_DEPLOY_ROOT/ddns-config"
  printf 'ddns-secret\n' >"$FAKE_DEPLOY_ROOT/ddns-password"
  local rc
  rc="$(run_deploy)"

  check "env merge: exits 0" test "$rc" -eq 0
  check "env merge: injected DDNS_HOST" \
    grep -q '^DDNS_HOST=strim$' "$FAKE_DEPLOY_ROOT/config/strimserver.env"
  check "env merge: injected DDNS_DOMAIN" \
    grep -q '^DDNS_DOMAIN=example.com$' "$FAKE_DEPLOY_ROOT/config/strimserver.env"
  check "env merge: injected ENABLE_DDNS replaces the old value" \
    bash -c '[ "$(grep -c "^ENABLE_DDNS=" "$1")" -eq 1 ] && grep -q "^ENABLE_DDNS=true$" "$1"' _ "$FAKE_DEPLOY_ROOT/config/strimserver.env"
  check "env merge: unrelated key preserved" \
    grep -q '^TWITCH_STREAM_KEY="keep-me"$' "$FAKE_DEPLOY_ROOT/config/strimserver.env"
  check "env merge: transfer file scrubbed" \
    test ! -e "$FAKE_DEPLOY_ROOT/ddns-config"
  end_case
}
check "DDNS settings are merged by the lib helper" ddns_env_merge_case

ddns_missing_env_case() {
  begin_case
  rm -f "$FAKE_DEPLOY_ROOT/config/strimserver.env"
  printf 'ENABLE_DDNS=true\nDDNS_HOST=strim\nDDNS_DOMAIN=example.com\n' \
    >"$FAKE_DEPLOY_ROOT/ddns-config"
  printf 'ddns-secret\n' >"$FAKE_DEPLOY_ROOT/ddns-password"
  local rc
  rc="$(run_deploy)"

  check "missing env: exits 1" test "$rc" -eq 1
  check "missing env: names the missing env file" \
    grep -q 'config/strimserver.env' "$case_out"
  check "missing env: no truncated env was created" \
    test ! -e "$FAKE_DEPLOY_ROOT/config/strimserver.env"
  check "missing env: no import happened" not_called ' i import '
  end_case
}
check "a missing strimserver.env is fatal (no truncated env)" ddns_missing_env_case

# ===========================================================================
# 5c. orphaned import guard -> exit 5
# ===========================================================================
orphan_import_case() {
  begin_case
  export FAKE_PGREP_RC=0
  local rc
  rc="$(run_deploy)"

  check "orphan import: exits 5" test "$rc" -eq 5
  check "orphan import: says another deploy is running" \
    grep -q 'another deploy is running' "$case_out"
  check "orphan import: did nothing else" not_called '^mountpoint '
  end_case
}
check "a live orphaned import exits 5 after acquiring the lock" orphan_import_case

# ===========================================================================
# 6. lock held -> exit 5
# ===========================================================================
lock_held_case() {
  begin_case
  exec 8>"$FAKE_SYSROOT/run/strimserver-deploy.lock"
  flock -n 8
  local rc
  rc="$(run_deploy)"
  exec 8>&-

  check "lock held: exits 5" test "$rc" -eq 5
  check "lock held: says another deploy is running" grep -q 'another deploy is running' "$case_out"
  check "lock held: did nothing else" not_called '^mountpoint '
  end_case
}
check "a held deploy lock exits 5 without doing anything else" lock_held_case

# ===========================================================================
# 7. mountpoint precondition -> exit 1, stdout only (no log)
# ===========================================================================
not_mounted_case() {
  begin_case
  export FAKE_MOUNTPOINT_RC=1
  local rc
  rc="$(run_deploy)"

  check "not mounted: exits 1" test "$rc" -eq 1
  check "not mounted: names /mnt/nvme" grep -q '/mnt/nvme' "$case_out"
  check "not mounted: no deploy log was opened" \
    bash -c '! ls "$1"/deploy-*.log >/dev/null 2>&1' _ "$FAKE_DEPLOY_ROOT/logs"
  check "not mounted: no import" not_called ' i import '
  end_case
}
check "an unmounted /mnt/nvme exits 1 before opening the log" not_mounted_case

# ===========================================================================
# 8. IMDS failure modes
# ===========================================================================
imds_failure_case() {
  begin_case
  export FAKE_PUBLIC_IP=garbage
  local rc
  rc="$(run_deploy)"

  check "IMDS garbage: exits 1" test "$rc" -eq 1
  check "IMDS garbage: exact remediation message" \
    grep -q 'cannot determine public IPv4 from IMDS (no public IP associated?)' "$case_out"
  check "IMDS garbage: no import" not_called ' i import '
  end_case
}
check "a garbage IMDS public IP exits 1 before imports" imds_failure_case

imds_empty_case() {
  begin_case
  export FAKE_PUBLIC_IP=""
  local rc
  rc="$(run_deploy)"
  check "IMDS empty: exits 1" test "$rc" -eq 1
  check "IMDS empty: exact remediation message" \
    grep -q 'cannot determine public IPv4 from IMDS (no public IP associated?)' "$case_out"
  end_case
}
check "an empty IMDS public IP exits 1" imds_empty_case

# ===========================================================================
# 9. containerd ensure-running guard
# ===========================================================================
containerd_stopped_case() {
  begin_case
  export FAKE_CONTAINERD_ACTIVE=0
  local rc
  rc="$(run_deploy)"

  check "containerd stopped: deploy exits 0" test "$rc" -eq 0
  check "containerd stopped: started with the bounded wrapper" \
    has_call 'sudo timeout -k 5 30 systemctl start containerd'
  check "containerd stopped: is-active re-checked after start" \
    test "$(count_calls 'systemctl is-active --quiet containerd')" -ge 2
  end_case
}
check "a stopped containerd is started with the bounded guard" containerd_stopped_case

containerd_running_case() {
  begin_case
  local rc
  rc="$(run_deploy)"
  check "containerd running: no start call" not_called 'systemctl start containerd'
  check "containerd running: deploy exits 0" test "$rc" -eq 0
  end_case
}
check "a running containerd is a no-op" containerd_running_case

containerd_start_fails_case() {
  begin_case
  export FAKE_CONTAINERD_ACTIVE=0 FAKE_CONTAINERD_START_RC=1
  local rc
  rc="$(run_deploy)"
  check "containerd start failure: exits 1" test "$rc" -eq 1
  check "containerd start failure: no import" not_called ' i import '
  end_case
}
check "a containerd start failure exits 1" containerd_start_fails_case

containerd_still_inactive_case() {
  begin_case
  export FAKE_CONTAINERD_ACTIVE=0 FAKE_CONTAINERD_STAY_INACTIVE=1
  local rc
  rc="$(run_deploy)"
  check "containerd still inactive: exits 1" test "$rc" -eq 1
  check "containerd still inactive: no import" not_called ' i import '
  end_case
}
check "a start that leaves containerd inactive exits 1" containerd_still_inactive_case

# ===========================================================================
# 10. M1 overrun is warn-only
# ===========================================================================
m1_overrun_case() {
  begin_case
  export DEPLOY_M1_ELAPSED_OVERRIDE=73
  local rc
  rc="$(run_deploy)"
  check "M1 overrun: still exits 0" test "$rc" -eq 0
  check "M1 overrun: warns over the 60s target" \
    grep -q '^M1: service ready (73s, over 60s target)$' "$case_out"
  end_case
}
check "an M1 overrun is warn-only and keeps exit 0" m1_overrun_case

# ===========================================================================
# 11. signals: HUP -> 129, INT -> 130, TERM -> 143 during the blocking start
# ===========================================================================
signal_case() {
  local sig="$1" expected="$2"
  begin_case
  enable_ddns
  export FAKE_SYSTEMCTL_BLOCK_SECONDS=1
  start_deploy_bg
  if ! wait_for_call 'sudo timeout -k 5 150 systemctl start strim-ddns-verify.service'; then
    check "signal $sig: reached the blocking verify start" false
    end_case
    return
  fi
  kill -"$sig" "$deploy_pid" 2>/dev/null || true
  local rc=0
  wait "$deploy_pid" || rc=$?

  check "signal $sig: exits $expected" test "$rc" -eq "$expected"
  check "signal $sig: stopped the in-flight verify unit" \
    has_call 'sudo timeout -k 5 150 systemctl stop strim-ddns-verify.service$'
  check "signal $sig: deploy-last.rc recorded $expected" \
    test "$(cat "$FAKE_DEPLOY_ROOT/logs/deploy-last.rc" 2>/dev/null)" = "$expected"
  check "signal $sig: deploy log is complete through M1" \
    bash -c 'f=$(ls -1t "$1"/deploy-*.log 2>/dev/null | head -1); [ -n "$f" ] && grep -q "^M1:" "$f"' _ "$FAKE_DEPLOY_ROOT/logs"
  check "signal $sig: M2 was never printed" \
    bash -c '! grep -q "^M2:" "$1"' _ "$case_out"
  unset FAKE_SYSTEMCTL_BLOCK_SECONDS
  end_case
}
check "SIGHUP during the blocking start exits 129 and stops the unit" signal_case HUP 129
check "SIGINT during the blocking start exits 130 and stops the unit" signal_case INT 130
check "SIGTERM during the blocking start exits 143 and stops the unit" signal_case TERM 143

# ===========================================================================
# 12. interrupt during the parallel imports
# ===========================================================================
interrupt_imports_case() {
  begin_case
  export FAKE_CTR_DELAY=0.5
  start_deploy_bg
  if ! wait_for_call ' i import .*container.tar'; then
    check "imports interrupt: reached the import barrier" false
    end_case
    return
  fi
  kill -TERM "$deploy_pid" 2>/dev/null || true
  local rc=0
  wait "$deploy_pid" || rc=$?

  check "imports interrupt: exits 143" test "$rc" -eq 143
  check "imports interrupt: no service install after the barrier" \
    not_called 'install .*strimserver.service'
  check "imports interrupt: deploy-last.rc recorded 143" \
    test "$(cat "$FAKE_DEPLOY_ROOT/logs/deploy-last.rc" 2>/dev/null)" = "143"
  end_case
}
check "an interrupt during the imports exits 143" interrupt_imports_case

# ===========================================================================
# 13. unit template / directive contract
# ===========================================================================
unit_template_case() {
  check "verify template: After= refresh" grep -q '^After=.*strim-ddns.service' "$verify_template"
  check "verify template: no Wants= refresh" bash -c '! grep -q "^Wants=strim-ddns.service" "$1"' _ "$verify_template"
  check "verify template: no [Install] section" bash -c '! grep -q "^\[Install\]" "$1"' _ "$verify_template"
  check "verify template: AssertPathIsMountPoint" grep -q '^AssertPathIsMountPoint=/mnt/nvme' "$verify_template"
  check "verify template: TimeoutStartSec=140" grep -q '^TimeoutStartSec=140' "$verify_template"
  check "verify template: bounded per-attempt timeout 30" grep -q 'timeout 30' "$verify_template"
  check "verify template: sleep 5 between attempts" grep -q 'sleep 5' "$verify_template"
  check "verify template: distinct verify container ID" grep -q 'strim-ddns-verify' "$verify_template"
  check "verify template: pre-attempt kill then delete" \
    bash -c 'awk -v k="tasks kill -s KILL strim-ddns-verify" -v d="containers delete strim-ddns-verify" "{ p=index(\$0,k); if (p>0 && !seen) { kpos=NR*100000+p; seen=1 } q=index(\$0,d); if (q>0) { dpos=NR*100000+q } } END { exit (seen && kpos < dpos) ? 0 : 1 }" "$1"' _ "$verify_template"
  check "verify template: bounded ExecStopPost cleanup" \
    grep -q '^ExecStopPost=-timeout -k 5 10 /usr/bin/ctr -n strimserver tasks kill -s KILL strim-ddns-verify' "$verify_template"

  check "refresh template: TimeoutStartSec=30" grep -q '^TimeoutStartSec=30' "$refresh_template"
  check "refresh template: ConditionPathIsMountPoint" grep -q '^ConditionPathIsMountPoint=/mnt/nvme' "$refresh_template"
  check "refresh template: ExecStartPre=- cleanup" \
    grep -q '^ExecStartPre=-timeout -k 5 10 /usr/bin/ctr -n strimserver tasks kill -s KILL strim-ddns' "$refresh_template"
  check "refresh template: bounded ExecStopPost cleanup" \
    grep -q '^ExecStopPost=-timeout -k 5 10 /usr/bin/ctr -n strimserver tasks kill -s KILL strim-ddns' "$refresh_template"

  check "strimserver unit: AssertPathIsMountPoint" \
    grep -q '^AssertPathIsMountPoint=/mnt/nvme' "$script_dir/strimserver.service.template"
  check "timer: Persistent=true" grep -q '^Persistent=true' "$script_dir/strim-ddns.timer"
}
check "unit templates carry the pinned directives" unit_template_case

# ===========================================================================
# 14. missing verify template fails fast (no inline fallback)
# ===========================================================================
missing_template_fails_case() {
  local missing_dir
  missing_dir="$(mktemp -d)"
  "$FAKE_REAL_CP" "$deploy_sh" "$missing_dir/deploy.sh"
  ln -s "$script_dir/lib" "$missing_dir/lib"
  begin_case
  enable_ddns
  local rc
  ( cd "$FAKE_DEPLOY_ROOT" && bash "$missing_dir/deploy.sh" ) >"$case_out" 2>&1
  rc=$?
  check "missing template: exits non-zero (pre-M1 -> 1)" test "$rc" -eq 1
  check "missing template: names the missing template" \
    grep -q 'strim-ddns-verify.service.template' "$case_out"
  check "missing template: no verify unit installed" \
    test ! -f "$FAKE_SYSROOT/etc/systemd/system/strim-ddns-verify.service"
  end_case
  rm -rf "$missing_dir"
}
check "a missing verify template fails fast without an inline fallback" missing_template_fails_case

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall DDNS blocking tests passed\n'
