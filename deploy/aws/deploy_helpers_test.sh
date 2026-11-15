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
#   * the logs directory must reject a symlink, be 0755 (traversable by the
#     unprivileged tee / EXIT-trap writer), and pre-create the three logs at
#     0640 root:root while leaving deploy-* artifacts alone.
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
# deploy_apply_containerd_config restarts containerd through `sudo systemctl`;
# record the call so the no-restart-on-unchanged contract is observable.
cat >"$FAKE_SUDO_BINDIR/systemctl" <<'SHIM'
#!/usr/bin/env bash
# No logging: the recording fake sudo already records the `sudo systemctl ...`
# argv, so logging again here would double-count the restart assertion.
exit 0
SHIM
chmod +x "$FAKE_SUDO_BINDIR/systemctl"
PATH="$FAKE_SUDO_BINDIR:$PATH"
export PATH

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp" "$FAKE_SUDO_BINDIR" "$FAKE_SUDO_LOG"; }
trap cleanup EXIT INT TERM

# The canonical containerd config is the ACTUAL repo artifact
# deploy/aws/containerd-config.toml (64 bytes: root assignment, state
# assignment, one blank separator line). It is a Bazel `data` runfile, so the
# suite compares helper output against the real file rather than a synthetic
# must-as-well fixture; this catches a drift between the helper and the
# installed artifact.
canonical_containerd_config="$script_dir/containerd-config.toml"
[ -s "$canonical_containerd_config" ] || {
  printf 'FATAL: canonical containerd config %s is missing\n' \
    "$canonical_containerd_config" >&2
  exit 1
}

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
  deploy_prepend_containerd_root_state "$containerd_cfg" "$containerd_cfg" sudo \
    "$canonical_containerd_config" || return 1
  deploy_prepend_containerd_root_state "$containerd_cfg" "$containerd_cfg" sudo \
    "$canonical_containerd_config" || return 1
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
  err="$(deploy_prepend_containerd_root_state "$tmp/does-not-exist.toml" "$out" sudo \
    "$canonical_containerd_config" 2>&1)" || return 1
  [ -f "$out" ] || return 1
  grep -q "no existing config" <<<"$err" || return 1
  has_exactly_one "$out" '^root=' 1 || return 1
  has_exactly_one "$out" '^state=' 1 || return 1
}
check "missing config is treated as empty and logged" containerd_missing_ok

# A missing (or empty) config must be emitted as EXACTLY the actual repo
# artifact deploy/aws/containerd-config.toml (64 bytes): root line, state line,
# blank separator, trailing newline.
containerd_missing_is_canonical_64_bytes() {
  local out="$tmp/canonical-missing.toml"
  deploy_prepend_containerd_root_state "$tmp/does-not-exist.toml" "$out" sudo \
    "$canonical_containerd_config" 2>/dev/null || return 1
  cmp -s "$out" "$canonical_containerd_config" || return 1
  cmp -s "$out" "$script_dir/containerd-config.toml" || return 1
  [ "$(wc -c <"$out")" -eq 64 ]
}
check "missing/empty config emits the actual repo canonical 64 bytes exactly" containerd_missing_is_canonical_64_bytes

# The canonical text is installed from a source file, not generated inline: a
# helper given a different canonical source must reproduce those bytes verbatim.
containerd_installs_canonical_source() {
  local source="$tmp/other-canonical.toml" out="$tmp/other-canonical-out.toml"
  printf "root='/custom/containerd'\nstate='/custom/containerd-state'\n\n" \
    >"$source"
  deploy_prepend_containerd_root_state "$tmp/no-existing.toml" "$out" sudo \
    "$source" 2>/dev/null || return 1
  cmp -s "$out" "$source"
}
check "the helper installs its canonical source file byte-for-byte" containerd_installs_canonical_source

# Default source resolution must point at the repo/bundle sibling file, so a
# call site that passes no source still installs deploy/aws/containerd-config.toml.
containerd_default_source_is_repo_sibling() {
  local resolved
  resolved="$(deploy__canonical_containerd_config)" || return 1
  [ "$(realpath -m -- "$resolved")" = \
    "$(realpath -m -- "$script_dir/containerd-config.toml")" ]
}
check "default canonical source is the repo sibling containerd-config.toml" containerd_default_source_is_repo_sibling

# An existing config with unrelated settings must be preserved in full: no key
# loss, and exactly one canonical root/state pair after the separator.
containerd_preserves_existing_keys() {
  local cfg="$tmp/preserve.toml"
  cat >"$cfg" <<'CFG'
version = 2
root = '/stale/root'
state = '/stale/state'
oom_score_adj = -999
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.example/pause:3.9"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"
CFG
  deploy_prepend_containerd_root_state "$cfg" "$cfg" sudo \
    "$canonical_containerd_config" || return 1
  has_exactly_one "$cfg" '^root=' 1 || return 1
  has_exactly_one "$cfg" '^state=' 1 || return 1
  grep -qx 'version = 2' "$cfg" || return 1
  grep -qx 'oom_score_adj = -999' "$cfg" || return 1
  grep -qx '  sandbox_image = "registry.example/pause:3.9"' "$cfg" || return 1
  grep -qx '    runtime_type = "io.containerd.runc.v2"' "$cfg" || return 1
  ! grep -qE '^[[:space:]]+(root|state)[[:space:]]*=' "$cfg" || return 1
  grep -qx "root='/mnt/nvme/containerd'" "$cfg" || return 1
  grep -qx "state='/mnt/nvme/containerd-state'" "$cfg"
}
check "existing unrelated config keys survive with one canonical root/state pair" containerd_preserves_existing_keys

# An existing config whose read fails must abort without writing <out>.
#
# Root bypasses DAC so chmod 000 is not a real denial for uid 0; rather than
# short-circuit to a vacuous pass, inject the failure at the exact syscall the
# helper makes: a `sudo` shim that fails `cat <config>` with a non-zero status,
# which is precisely what an unreadable file (or a denied sudo read) produces.
# This exercises the fail-closed branch honestly for root and non-root alike.
containerd_unreadable_fails_without_writing() {
  local cfg="$tmp/unreadable.toml" out="$tmp/unreadable-out.toml"
  local fail_sudo="$tmp/failing-read-sudo"
  printf "root = '/x'\n" >"$cfg" || return 1
  cat >"$fail_sudo" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "cat" ]; then
  exit 1
fi
exec "$@"
SHIM
  chmod +x "$fail_sudo" || return 1
  deploy_prepend_containerd_root_state "$cfg" "$out" "$fail_sudo" \
    "$canonical_containerd_config" >/dev/null 2>&1 && return 1
  [ ! -e "$out" ]
}
check "existing-but-unreadable config fails without writing the output" containerd_unreadable_fails_without_writing

# --- deploy_prepare_logs_directory ------------------------------------------
logs_root="$tmp/logs"
logs_ok() {
  DEPLOY_LOGS_ROOT="$logs_root" deploy_prepare_logs_directory "$logs_root" sudo || return 1
  [ -d "$logs_root" ] || return 1
  # 0755 (not 0750): the unprivileged tee process substitution and the EXIT-trap
  # deploy-last.rc write must be able to traverse the directory.
  [ "$(mode_of "$logs_root")" = "755" ] || return 1
  owned_as_root_or_requested "$logs_root"
  local log
  for log in mediamtx.log normalize.log egress.log; do
    [ -f "$logs_root/$log" ] || return 1
    [ "$(mode_of "$logs_root/$log")" = "640" ] || return 1
  done
}
check "logs dir is 0755 with three 0640 logs" logs_ok

logs_normalize_ok() {
  ( umask 022; : >"$logs_root/late.log" )
  [ "$(mode_of "$logs_root/late.log")" = "644" ] || return 1
  DEPLOY_LOGS_ROOT="$logs_root" deploy_prepare_logs_directory "$logs_root" sudo || return 1
  [ "$(mode_of "$logs_root/late.log")" = "640" ] || return 1
  # Idempotent.
  DEPLOY_LOGS_ROOT="$logs_root" deploy_prepare_logs_directory "$logs_root" sudo || return 1
  [ "$(mode_of "$logs_root")" = "755" ]
}
check "a newly created log is normalized to 0640 and the helper is idempotent" logs_normalize_ok

# deploy.sh pre-creates deploy-<timestamp>.log and deploy-last.rc owned by the
# deploy user (0640). Normalization must leave those deploy-* artifacts alone
# while still normalizing every other regular file to root:root 0640.
logs_deploy_artifacts_excluded() {
  local deploy_log="$logs_root/deploy-20260101T000000Z.log"
  local deploy_rc="$logs_root/deploy-last.rc"
  ( umask 077; : >"$deploy_log"; : >"$deploy_rc" )
  [ "$(mode_of "$deploy_log")" = "600" ] || return 1
  [ "$(mode_of "$deploy_rc")" = "600" ] || return 1
  : >"$FAKE_SUDO_LOG"
  DEPLOY_LOGS_ROOT="$logs_root" deploy_prepare_logs_directory "$logs_root" sudo || return 1
  # Deploy artifacts keep the caller's mode (ec2-user 0600/0640), not root 0640.
  [ "$(mode_of "$deploy_log")" = "600" ] || return 1
  [ "$(mode_of "$deploy_rc")" = "600" ] || return 1
  # And no chown/chmod normalization was requested for them.
  ! grep -q 'deploy-20260101T000000Z.log' "$FAKE_SUDO_LOG" || return 1
  ! grep -q 'deploy-last.rc' "$FAKE_SUDO_LOG"
}
check "deploy-* artifacts are excluded from log normalization" logs_deploy_artifacts_excluded

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

# --- deploy_apply_containerd_config -----------------------------------------
# (a) on-disk config already equals the canonical form: no restart and the
#     file is left byte-for-byte untouched.
containerd_unchanged_no_restart() {
  local cfg="$tmp/canonical.toml" before state
  cp "$script_dir/containerd-config.toml" "$cfg" || return 1
  before="$(cksum "$cfg")"
  : >"$FAKE_SUDO_LOG"
  state="$(deploy_apply_containerd_config "$cfg" "$tmp/canon-out.toml" sudo \
    "$canonical_containerd_config")" || return 1
  [ "$state" = "unchanged" ] || return 1
  ! grep -q 'systemctl restart containerd' "$FAKE_SUDO_LOG" || return 1
  [ "$before" = "$(cksum "$cfg")" ] || return 1
  [ ! -e "$tmp/canon-out.toml" ]
}
check "canonical containerd config is left untouched without a restart" containerd_unchanged_no_restart

# (b) a differing config is rewritten exactly once and containerd restarted
#     exactly once.
containerd_changed_one_restart() {
  local cfg="$tmp/changed.toml" state
  printf "version = 2\nroot = '/stale'\n[plugins]\n  keep = true\n" >"$cfg"
  : >"$FAKE_SUDO_LOG"
  state="$(deploy_apply_containerd_config "$cfg" "$tmp/changed-out.toml" sudo \
    "$canonical_containerd_config")" || return 1
  [ "$state" = "changed" ] || return 1
  [ "$(grep -c 'systemctl restart containerd.service' "$FAKE_SUDO_LOG")" -eq 1 ] || return 1
  grep -qx "root='/mnt/nvme/containerd'" "$cfg" || return 1
  grep -qx "state='/mnt/nvme/containerd-state'" "$cfg" || return 1
  grep -q 'keep = true' "$cfg" || return 1
  [ ! -e "$tmp/changed-out.toml" ]
}
check "a changed containerd config is rewritten with exactly one restart" containerd_changed_one_restart

# --- deploy_write_ddns_env_settings -----------------------------------------
# deploy.sh must write the transferred DDNS settings into strimserver.env BEFORE
# `systemctl enable --now strim-ddns.timer`, so a timer-triggered start reads the
# correct DDNS_HOST/DDNS_DOMAIN. The helper owns that write: atomic, idempotent,
# and duplicate-free while preserving every unrelated env key.
ddns_dir="$tmp/ddns-env"
mkdir -p "$ddns_dir"
ddns_env="$ddns_dir/strimserver.env"
cat >"$ddns_env" <<'ENV'
ENABLE_DDNS=false
DDNS_HOST=old
DDNS_HOST=duplicate
DDNS_DOMAIN=old.example
TWITCH_STREAM_KEY=keep-me
OTHER_SETTING=1
ENV
ddns_settings="$tmp/ddns-config"
printf 'ENABLE_DDNS=true\nDDNS_HOST=new\nDDNS_DOMAIN=new.example\n' >"$ddns_settings"

ddns_write_ok() {
  deploy_write_ddns_env_settings "$ddns_env" "$ddns_settings" || return 1
  [ "$(mode_of "$ddns_env")" = "600" ] || return 1
  has_exactly_one "$ddns_env" '^ENABLE_DDNS=' 1 || return 1
  has_exactly_one "$ddns_env" '^DDNS_HOST=' 1 || return 1
  has_exactly_one "$ddns_env" '^DDNS_DOMAIN=' 1 || return 1
  grep -qx 'ENABLE_DDNS=true' "$ddns_env" || return 1
  grep -qx 'DDNS_HOST=new' "$ddns_env" || return 1
  grep -qx 'DDNS_DOMAIN=new.example' "$ddns_env" || return 1
  grep -qx 'TWITCH_STREAM_KEY=keep-me' "$ddns_env" || return 1
  grep -qx 'OTHER_SETTING=1' "$ddns_env" || return 1
  # No scratch file is left behind beside the env file.
  ! compgen -G "$ddns_env.tmp.*" >/dev/null
}
check "DDNS settings replace stale values, dedupe, and preserve other keys" ddns_write_ok

ddns_idempotent() {
  local before after
  before="$(cksum "$ddns_env")"
  deploy_write_ddns_env_settings "$ddns_env" "$ddns_settings" || return 1
  after="$(cksum "$ddns_env")"
  [ "$before" = "$after" ]
}
check "re-applying the DDNS settings is byte-for-byte idempotent" ddns_idempotent

ddns_partial_settings_keep_other_lines() {
  local partial="$tmp/ddns-partial"
  printf 'DDNS_HOST=partial\n' >"$partial"
  deploy_write_ddns_env_settings "$ddns_env" "$partial" || return 1
  has_exactly_one "$ddns_env" '^DDNS_HOST=' 1 || return 1
  grep -qx 'DDNS_HOST=partial' "$ddns_env" || return 1
  # Keys absent from the settings file keep their current values.
  grep -qx 'ENABLE_DDNS=true' "$ddns_env" || return 1
  grep -qx 'DDNS_DOMAIN=new.example' "$ddns_env"
}
check "settings that omit some keys leave those keys untouched" ddns_partial_settings_keep_other_lines

ddns_empty_settings_is_noop() {
  local empty="$tmp/ddns-empty" before
  : >"$empty"
  before="$(cksum "$ddns_env")"
  deploy_write_ddns_env_settings "$ddns_env" "$empty" || return 1
  [ "$before" = "$(cksum "$ddns_env")" ]
}
check "an empty settings file is a no-op" ddns_empty_settings_is_noop

ddns_missing_env_fails_loud() {
  local missing="$tmp/no-such-env/strimserver.env"
  deploy_write_ddns_env_settings "$missing" "$ddns_settings" >/dev/null 2>&1 && return 1
  [ ! -e "$missing" ]
}
check "a missing env file fails loudly and is not created" ddns_missing_env_fails_loud

# --- atomic replace: scratch file must share the target's directory ----------
# rename(2) is atomic only within one filesystem, so the scratch file must be
# created in the target's own directory rather than /tmp. Observe the actual
# `mv <tmp> <target>` call: a shim records both dirnames and delegates to the
# real mv, proving the helper's temp file is a sibling of the target.
assert_all_renames_are_same_directory() {
  local log="$1" left right
  [ -s "$log" ] || return 1
  while IFS='|' read -r left right; do
    [ "$left" = "$right" ] || return 1
  done <"$log"
}

atomic_replace_same_directory() {
  local real_mv shim_dir
  real_mv="$(command -v mv)" || return 1
  shim_dir="$tmp/atomic-bin"
  mkdir -p "$shim_dir" || return 1
  export ATOMIC_REAL_MV="$real_mv" ATOMIC_MV_LOG="$tmp/atomic-mv.log"
  cat >"$shim_dir/mv" <<'SHIM'
#!/usr/bin/env bash
args=("$@")
if [ "${args[0]:-}" = "--" ]; then
  args=("${args[@]:1}")
fi
[ "${#args[@]}" -ge 2 ] || exit 1
printf '%s|%s\n' "$(dirname -- "${args[0]}")" "$(dirname -- "${args[1]}")" \
  >> "${ATOMIC_MV_LOG:?}"
exec "${ATOMIC_REAL_MV:?}" "$@"
SHIM
  chmod +x "$shim_dir/mv" || return 1

  local ccfg="$tmp/atomic-containerd.toml" cout="$tmp/atomic-containerd-out.toml"
  printf "version = 2\nroot = '/stale'\n" >"$ccfg" || return 1
  : >"$ATOMIC_MV_LOG"
  PATH="$shim_dir:$PATH" deploy_prepend_containerd_root_state "$ccfg" "$cout" sudo \
    "$canonical_containerd_config" >/dev/null 2>&1 || return 1
  assert_all_renames_are_same_directory "$ATOMIC_MV_LOG" || return 1

  local denv="$tmp/atomic-env/strimserver.env" dsettings="$tmp/atomic-settings"
  mkdir -p "$(dirname -- "$denv")" || return 1
  printf 'BASE_SETTING=1\n' >"$denv" || return 1
  printf 'DDNS_HOST=atomic\n' >"$dsettings" || return 1
  : >"$ATOMIC_MV_LOG"
  PATH="$shim_dir:$PATH" deploy_write_ddns_env_settings "$denv" "$dsettings" \
    >/dev/null 2>&1 || return 1
  assert_all_renames_are_same_directory "$ATOMIC_MV_LOG"
}
check "atomic replace creates its scratch file in the target directory" atomic_replace_same_directory

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
