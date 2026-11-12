#!/usr/bin/env bash
# deploy_helpers_test.sh -- offline unit tests for deploy/aws/lib/deploy.sh.
#
# The deploy helpers are deliberately pure (no `sudo` baked in; the caller
# passes a command prefix) so they can be exercised without root. These tests
# cover the three fresh-instance hazards:
#   * the 70-character SRT passphrase generator must not SIGPIPE under
#     `set -euo pipefail`;
#   * the passphrase file must be 0600, never printed, and must not widen on a
#     re-run;
#   * the containerd root/state rewrite must read the existing config, fail
#     closed when it is unreadable, and be idempotent;
#   * the logs directory must reject a symlink, be 0750, and pre-create the
#     three logs at 0640 root:root.
#
# Privileged ownership cannot be asserted directly as a non-root test user, so
# the fake `sudo` records the requested argv and strips `-o/-g` before running
# the real command. When the suite does run as root the actual owner is
# asserted instead.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$script_dir/lib/deploy.sh"
deploy_sh="$script_dir/deploy.sh"
# shellcheck source=lib/deploy.sh
source "$lib"

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

# --- fake sudo ---------------------------------------------------------------
# Records the requested argv so ownership requests can be asserted, then drops
# `-o <owner>` / `-g <group>` so the non-root test user can perform the op.
# A `chown` is a no-op (the request is still recorded above).
FAKE_SUDO_BINDIR="$(mktemp -d)"
FAKE_SUDO_LOG="$(mktemp)"
export FAKE_SUDO_LOG
cat >"$FAKE_SUDO_BINDIR/sudo" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SUDO_LOG:?}"
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-g)
      shift
      [ "$#" -gt 0 ] && shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ "${args[0]:-}" = "chown" ]; then
  exit 0
fi
exec "${args[@]}"
SHIM
chmod +x "$FAKE_SUDO_BINDIR/sudo"
# `find ... -exec chown root:root` resolves chown via PATH (it is not routed
# through the fake sudo), so provide a no-op recorder for the non-root run.
cat >"$FAKE_SUDO_BINDIR/chown" <<'SHIM'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "${FAKE_SUDO_LOG:?}"
exit 0
SHIM
chmod +x "$FAKE_SUDO_BINDIR/chown"
PATH="$FAKE_SUDO_BINDIR:$PATH"
export PATH

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp" "$FAKE_SUDO_BINDIR" "$FAKE_SUDO_LOG"; }
trap cleanup EXIT INT TERM

owned_as_root_or_requested() {
  local path="$1"
  if [ "$(id -u)" -eq 0 ]; then
    [ "$(stat -c '%U:%G' "$path")" = "root:root" ]
  else
    grep -q -- '-o root' "$FAKE_SUDO_LOG" && grep -q -- '-g root' "$FAKE_SUDO_LOG"
  fi
}

mode_of() { stat -c '%a' "$1"; }

has_exactly_one() {
  local file="$1" pattern="$2" expected="$3" count
  count="$(grep -cE "$pattern" "$file" || true)"
  [ "$count" -eq "$expected" ]
}

# --- deploy_generate_srt_passphrase -----------------------------------------
# Must return exactly 70 [A-Za-z0-9] characters, 20 times, under `set -euo
# pipefail`, with no exit 141 (SIGPIPE from `head -c` closing the pipe).
passphrase_generation_ok() {
  local i generated rc
  for i in $(seq 1 20); do
    generated="$(bash -c 'set -euo pipefail; source "$1"; deploy_generate_srt_passphrase' _ "$lib")"
    rc=$?
    [ "$rc" -eq 0 ] || return 1
    [ "${#generated}" -eq 70 ] || return 1
    [[ "$generated" =~ ^[A-Za-z0-9]{70}$ ]] || return 1
  done
  return 0
}
check "generator returns 70 [A-Za-z0-9] chars 20x under set -euo pipefail" passphrase_generation_ok

# --- deploy_write_srt_passphrase --------------------------------------------
pass_file="$tmp/srt-passphrase"
write_ok() {
  local out
  out="$(deploy_write_srt_passphrase "$pass_file" sudo 2>&1)"
  [ $? -eq 0 ] || return 1
  [ -f "$pass_file" ] || return 1
  [ "$(mode_of "$pass_file")" = "600" ] || return 1
  local value
  value="$(cat "$pass_file")"
  [ "${#value}" -eq 70 ] || return 1
  # The value must never appear on stdout/stderr.
  ! grep -qF -- "$value" <<<"$out" || return 1
  owned_as_root_or_requested "$pass_file"
}
check "write creates a 0600 passphrase file and never prints the value" write_ok

# Re-running must keep the same passphrase and re-tighten a widened mode.
rerun_ok() {
  local before after
  before="$(cat "$pass_file")"
  chmod 0644 "$pass_file"
  deploy_write_srt_passphrase "$pass_file" sudo >/dev/null 2>&1 || return 1
  after="$(cat "$pass_file")"
  [ "$(mode_of "$pass_file")" = "600" ] || return 1
  [ "$before" = "$after" ] || return 1
  owned_as_root_or_requested "$pass_file"
}
check "re-run keeps the passphrase and does not widen permissions" rerun_ok

# --- deploy_prepend_containerd_root_state -----------------------------------
containerd_cfg="$tmp/containerd.toml"
cat >"$containerd_cfg" <<'CFG'
version = 2
root = '/stale/root'
state   =   "/stale/state"
[plugins]
  keep = true
CFG
containerd_idempotent() {
  deploy_prepend_containerd_root_state "$containerd_cfg" "$containerd_cfg" sudo || return 1
  deploy_prepend_containerd_root_state "$containerd_cfg" "$containerd_cfg" sudo || return 1
  has_exactly_one "$containerd_cfg" '^root=' 1 || return 1
  has_exactly_one "$containerd_cfg" '^state=' 1 || return 1
  grep -qx "root='/mnt/nvme/containerd'" "$containerd_cfg" || return 1
  grep -qx "state='/mnt/nvme/containerd-state'" "$containerd_cfg" || return 1
  grep -q '^version = 2$' "$containerd_cfg" || return 1
  grep -q 'keep = true' "$containerd_cfg" || return 1
  # No indented/padded stale assignment survives.
  ! grep -qE '^[[:space:]]+(root|state)[[:space:]]*=' "$containerd_cfg"
}
check "containerd rewrite strips stale root/state, preserves keys, one pair after two runs" containerd_idempotent

containerd_missing_ok() {
  local out="$tmp/missing-out.toml" err
  err="$(deploy_prepend_containerd_root_state "$tmp/does-not-exist.toml" "$out" sudo 2>&1)" || return 1
  [ -f "$out" ] || return 1
  grep -q "no existing config" <<<"$err" || return 1
  has_exactly_one "$out" '^root=' 1 || return 1
  has_exactly_one "$out" '^state=' 1 || return 1
}
check "missing config is treated as empty and logged" containerd_missing_ok

containerd_unreadable_ok() {
  # Root bypasses DAC, so this case is meaningful only for a non-root user.
  [ "$(id -u)" -ne 0 ] || return 0
  local cfg="$tmp/unreadable.toml" out="$tmp/unreadable-out.toml"
  printf "root = '/x'\n" >"$cfg"
  chmod 000 "$cfg"
  deploy_prepend_containerd_root_state "$cfg" "$out" sudo >/dev/null 2>&1 && {
    chmod 600 "$cfg"
    return 1
  }
  chmod 600 "$cfg"
  [ ! -e "$out" ]
}
check "existing-but-unreadable config fails without writing the output" containerd_unreadable_ok

# --- deploy_prepare_logs_directory ------------------------------------------
logs_root="$tmp/logs"
logs_ok() {
  DEPLOY_LOGS_ROOT="$logs_root" deploy_prepare_logs_directory "$logs_root" sudo || return 1
  [ -d "$logs_root" ] || return 1
  [ "$(mode_of "$logs_root")" = "750" ] || return 1
  owned_as_root_or_requested "$logs_root"
  local log
  for log in mediamtx.log normalize.log egress.log; do
    [ -f "$logs_root/$log" ] || return 1
    [ "$(mode_of "$logs_root/$log")" = "640" ] || return 1
  done
}
check "logs dir is 0750 with three 0640 logs" logs_ok

logs_normalize_ok() {
  ( umask 022; : >"$logs_root/late.log" )
  [ "$(mode_of "$logs_root/late.log")" = "644" ] || return 1
  DEPLOY_LOGS_ROOT="$logs_root" deploy_prepare_logs_directory "$logs_root" sudo || return 1
  [ "$(mode_of "$logs_root/late.log")" = "640" ] || return 1
  # Idempotent.
  DEPLOY_LOGS_ROOT="$logs_root" deploy_prepare_logs_directory "$logs_root" sudo || return 1
  [ "$(mode_of "$logs_root")" = "750" ]
}
check "a newly created log is normalized to 0640 and the helper is idempotent" logs_normalize_ok

logs_symlink_rejected() {
  local real="$tmp/real-logs" link="$tmp/link-logs"
  mkdir -p "$real"
  ln -s "$real" "$link"
  DEPLOY_LOGS_ROOT="$link" deploy_prepare_logs_directory "$link" sudo >/dev/null 2>&1 && return 1
  # Target must be untouched (no logs pre-created through the symlink).
  [ -z "$(ls -A "$real")" ]
}
check "a symlinked logs directory is rejected and its target untouched" logs_symlink_rejected

logs_wrong_root_rejected() {
  local wrong="$tmp/not-the-root"
  DEPLOY_LOGS_ROOT="$logs_root" deploy_prepare_logs_directory "$wrong" sudo >/dev/null 2>&1 && return 1
  [ ! -d "$wrong" ]
}
check "a directory that is not the expected root is rejected" logs_wrong_root_rejected

# --- deploy.sh static check -------------------------------------------------
deploy_sh_has_no_passphrase_print() {
  [ -f "$deploy_sh" ] || return 1
  # No printf/echo may emit the passphrase value or interpolate the variable.
  # `$SRT_READ_PASSPHRASE` (the value) must not be printed; the `_FILE` path
  # variable is fine.
  ! grep -qE '(printf|echo)[^#]*\$\{?SRT_READ_PASSPHRASE([^_A-Za-z0-9]|$)' "$deploy_sh" || return 1
  ! grep -qE 'passphrase: %s' "$deploy_sh" || return 1
  # The refactor must source the helper library.
  grep -q 'lib/deploy.sh' "$deploy_sh"
}
check "deploy.sh has no passphrase print and sources lib/deploy.sh" deploy_sh_has_no_passphrase_print

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall deploy helper checks passed\n'
