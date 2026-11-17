#!/usr/bin/env bash
# stackctl_render_env_test.sh -- execution tests for render_env() in
# deploy/aws/stackctl-setup.sh.
#
# render_env() must render the runtime env from the PACKAGED strimserver.env at
# ${NVME_MOUNT}/strimserver.env and overlay the SSM-fetched Twitch stream key
# onto its TWITCH_STREAM_KEY= line. The template is no longer the render source.
#
# The script is sourced through its BASH_SOURCE main guard, then render_env() is
# called directly against a temp NVME_MOUNT fixture. fetch_ssm_securestring is
# faked to model the environment by returning a pinned value; the success and
# overlay cases use the real sed/grep/chmod/chown/mktemp/mv/stat. Failure cases
# prepend PATH shims (fake sed/chmod/chown) that model a failing environment --
# failing only on the exact input under test and delegating every other call to
# the real binary -- never an expected output.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
real_sed="$(command -v sed)"
real_chmod="$(command -v chmod)"
real_chown="$(command -v chown)"

failures=0
skipped=0
ok=0
check() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok: %s\n' "$desc"
    ok=$((ok + 1))
  else
    printf 'FAIL: %s\n' "$desc" >&2
    failures=$((failures + 1))
  fi
}
# A skip is never reported as pass: it is counted and printed explicitly.
skip() {
  printf 'skip: %s\n' "$1"
  skipped=$((skipped + 1))
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fixture_root="$work/nvme"
mkdir -p "$fixture_root"

# Environment the script reads at source time. STACKCTL_REGION keeps
# resolve_region() off the network.
export STACKCTL_REGION="us-east-1"

# Ownership is only proven by chowning to a DIFFERENT existing user, which needs
# privilege. As root pick another real account so the assertion discriminates;
# otherwise render to the invoking user (chown-to-self) and SKIP the ownership
# assertion honestly rather than comparing the creator against itself.
invoking_user="$(id -un)"
can_assert_owner=0
service_user="$invoking_user"
if [ "$(id -u)" -eq 0 ]; then
  for candidate in nobody daemon bin; do
    if [ "$candidate" != "$invoking_user" ] && id "$candidate" >/dev/null 2>&1; then
      service_user="$candidate"
      can_assert_owner=1
      break
    fi
  done
fi
export STRIMSERVER_SERVICE_USER="$service_user"
export NVME_MOUNT="$fixture_root"

# Restrictive umask: render_env must pin mode/ownership at creation.
umask 077

# shellcheck source=stackctl-setup.sh
source "$script_dir/stackctl-setup.sh"
# The sourced script enables errexit; keep every assertion running here.
set +e

# --- fixture seam ----------------------------------------------------------
# A test that cannot point NVME_MOUNT at the fixture cannot exercise render_env
# without touching the host's real mount. Refuse to run rather than write to
# /mnt/nvme.
if [ "$NVME_MOUNT" != "$fixture_root" ]; then
  printf 'FAIL: fixture seam: NVME_MOUNT is %s, expected %s\n' \
    "$NVME_MOUNT" "$fixture_root" >&2
  failures=$((failures + 1))
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi

packaged="$NVME_MOUNT/strimserver.env"
rendered="$NVME_MOUNT/config/strimserver.env"
stderr_file="$work/stderr"

reset_fixture() {
  rm -rf "$NVME_MOUNT"
  mkdir -p "$NVME_MOUNT"
}

write_packaged_env() {
  cat >"$packaged"
}

# The fake models the environment: it returns the pinned key, not an expected
# file. Callers set fake_key before invoking render_env.
fake_key=""
fetch_ssm_securestring() {
  printf '%s' "$fake_key"
}

render_env_call() {
  ( render_env ) 2>"$stderr_file"
}

base_env() {
  cat <<'EOF'
# fixture env
CONTAINERD_SOCKET="/containerd.sock"
EGRESS_SNAPSHOT_ID="fixture-egress-xyz"
TWITCH_STREAM_KEY=""
BANDWIDTH_TEST="false"
EOF
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# install_attr_failure_shim <command> <real-binary>
# Installs a PATH shim for chmod/chown that exits 1 ONLY when an argument names
# the staged `.strimserver.env.*` temp, delegating every other invocation to the
# real binary (so the config-dir chown still succeeds). It models a failing
# environment, never an expected output, and prints the shim's bin dir.
install_attr_failure_shim() {
  local command_name="$1" real_binary="$2" bin_dir="$work/${1}bin"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/$command_name" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *.strimserver.env.*) exit 1 ;;
  esac
done
exec ${real_binary} "\$@"
EOF
  "$real_chmod" +x "$bin_dir/$command_name"
  printf '%s' "$bin_dir"
}

# --- success: packaged env rendered with the key overlaid ------------------
reset_fixture
base_env | write_packaged_env
fake_key="pinned-fake-key"
src_hash_before="$(sha_of "$packaged")"
render_env_call
rc=$?

check "success: render_env exits 0" test "$rc" -eq 0
check "success: output exists at config/strimserver.env" test -f "$rendered"
check "success: non-TWITCH lines preserved verbatim" \
  bash -c 'diff -q <(grep -v "^TWITCH_STREAM_KEY=" "$1") <(grep -v "^TWITCH_STREAM_KEY=" "$2") >/dev/null' \
  _ "$packaged" "$rendered"
check "success: distinctive packaged value survives" \
  grep -qx 'EGRESS_SNAPSHOT_ID="fixture-egress-xyz"' "$rendered"
check "success: TWITCH_STREAM_KEY carries the fake SSM key" \
  grep -qx 'TWITCH_STREAM_KEY="pinned-fake-key"' "$rendered"
check "success: output mode is 600" \
  test "$(stat -c %a "$rendered" 2>/dev/null)" = "600"
# Structural pins paired with the runtime assertions: render_env must explicitly
# chmod 600 and chown the STAGED temp, and both must precede the atomic install.
# These match an actual command position (line start, optional indent) so the
# `die "failed to chmod 600 ${tmp_env}"` diagnostic text cannot satisfy them;
# the chmod pattern additionally requires the command to end at "||" or EOL.
check "structural: chmod 600 on the staged temp precedes install" \
  awk '
    /mktemp[[:space:]].*strimserver[.]env/ { made = NR }
    /^[[:space:]]*chmod[[:space:]]+600[[:space:]]+"[$]tmp_env"[[:space:]]*(\|\||$)/ { mode = NR }
    /^[[:space:]]*mv[[:space:]]+"[$]tmp_env"[[:space:]]+"[$]target"/ { inst = NR }
    END { exit !(made && mode && inst && made < mode && mode < inst) }
  ' "$script_dir/stackctl-setup.sh"
check "structural: chown of the staged temp precedes install" \
  awk '
    /mktemp[[:space:]].*strimserver[.]env/ { made = NR }
    /^[[:space:]]*chown[[:space:]].*"[$]tmp_env"/ { own = NR }
    /^[[:space:]]*mv[[:space:]]+"[$]tmp_env"[[:space:]]+"[$]target"/ { inst = NR }
    END { exit !(made && own && inst && made < own && own < inst) }
  ' "$script_dir/stackctl-setup.sh"
if [ "$can_assert_owner" -eq 1 ]; then
  check "success: output owner follows SERVICE_USER" \
    test "$(stat -c %U "$rendered" 2>/dev/null)" = "$service_user"
else
  skip "success: output owner follows SERVICE_USER (cannot chown to another user; re-run as root)"
fi
check "success: no leftover render temp files" \
  bash -c '[ -z "$(find "$1" -maxdepth 1 -name ".strimserver.env.*" -print -quit)" ]' \
  _ "$NVME_MOUNT/config"
check "success: packaged source is byte-identical before/after" \
  test "$(sha_of "$packaged")" = "$src_hash_before"

# The scoped EXIT trap must be disarmed on success: a second render_env call in
# the same shell must still work and must not trip a stale cleanup trap.
repeat_render() {
  ( render_env >/dev/null 2>&1 && render_env >/dev/null 2>&1 )
}
reset_fixture
base_env | write_packaged_env
fake_key="repeat-key"
check "success: a second render_env call in the same shell still works" \
  repeat_render
check "success: repeated render leaves no leftover temp files" \
  bash -c '[ -z "$(find "$1" -maxdepth 1 -name ".strimserver.env.*" -print -quit)" ]' \
  _ "$NVME_MOUNT/config"

# --- failure: chmod of the staged temp fails (no half-installed target) ----
# A fake chmod fails ONLY on the staged temp (its argument names the mktemp
# file) and delegates every other invocation to the real chmod. This forces the
# post-render chmod arm to fail after the temp exists and asserts the property
# D10 names: non-zero exit, the chmod diagnostic, no target, no leftover temp.
reset_fixture
base_env | write_packaged_env
fake_key="pinned-fake-key"
chmod_bin="$(install_attr_failure_shim chmod "$real_chmod")"
saved_path="$PATH"
PATH="$chmod_bin:$PATH"
render_env_call
rc=$?
PATH="$saved_path"
check "chmod failure: render_env exits non-zero" test "$rc" -ne 0
check "chmod failure: diagnostic names the chmod failure" \
  grep -q 'failed to chmod 600' "$stderr_file"
check "chmod failure: target is not installed" test ! -e "$rendered"
check "chmod failure: no leftover render temp files" \
  bash -c '[ -z "$(find "$1" -maxdepth 1 -name ".strimserver.env.*" -print -quit)" ]' \
  _ "$NVME_MOUNT/config"
# --- failure: chown of the staged temp fails (no half-installed target) ----
# A fake chown fails ONLY on the staged temp and delegates every other
# invocation to the real chown, so the config-dir chown still succeeds. This
# exercises the ownership-failure window without touching privilege: non-zero
# exit, the chown diagnostic naming the staged temp, no target, no leftover temp.
reset_fixture
base_env | write_packaged_env
fake_key="pinned-fake-key"
chown_bin="$(install_attr_failure_shim chown "$real_chown")"
saved_path="$PATH"
PATH="$chown_bin:$PATH"
render_env_call
rc=$?
PATH="$saved_path"
check "chown failure: render_env exits non-zero" test "$rc" -ne 0
check "chown failure: diagnostic names the chown failure" \
  grep -q 'failed to chown' "$stderr_file"
check "chown failure: diagnostic names the staged temp" \
  grep -Eq 'failed to chown .*\.strimserver\.env\.' "$stderr_file"
check "chown failure: target is not installed" test ! -e "$rendered"
check "chown failure: no leftover render temp files" \
  bash -c '[ -z "$(find "$1" -maxdepth 1 -name ".strimserver.env.*" -print -quit)" ]' \
  _ "$NVME_MOUNT/config"

# --- failure: packaged env missing -----------------------------------------
reset_fixture
render_env_call
rc=$?
check "missing env: render_env exits non-zero" test "$rc" -ne 0
check "missing env: diagnostic says the env is missing from the bundle" \
  grep -q 'is missing from the release bundle' "$stderr_file"

# --- failure: packaged env has no TWITCH_STREAM_KEY= line ------------------
reset_fixture
cat >"$packaged" <<'EOF'
CONTAINERD_SOCKET="/containerd.sock"
EGRESS_SNAPSHOT_ID="fixture-egress-xyz"
EOF
render_env_call
rc=$?
check "missing key line: render_env exits non-zero" test "$rc" -ne 0
check "missing key line: diagnostic names TWITCH_STREAM_KEY" \
  grep -q 'TWITCH_STREAM_KEY' "$stderr_file"

# --- failure: packaged env is unreadable (grep exit >=2 != "no key line") --
# A real unreadable file makes grep exit 2. Root ignores the mode, so the case
# is skipped honestly when it cannot be induced.
reset_fixture
base_env | write_packaged_env
chmod 000 "$packaged"
if [ ! -r "$packaged" ]; then
  render_env_call
  rc=$?
  check "unreadable env: render_env exits non-zero" test "$rc" -ne 0
  check "unreadable env: diagnostic names the env and the grep exit code" \
    grep -Eq 'could not read packaged .*strimserver\.env.*grep exit [2-9]' "$stderr_file"
  check "unreadable env: not mislabelled as a missing key line" \
    bash -c '! grep -q "has no TWITCH_STREAM_KEY= line" "$1"' _ "$stderr_file"
else
  chmod 600 "$packaged"
  skip "unreadable env: cannot make a file unreadable as this user (root); run unprivileged"
fi

# --- overlay: sed metacharacters in the key render literally ----------------
reset_fixture
base_env | write_packaged_env
fake_key='s3cr\et|with/&meta'
render_env_call
rc=$?
check "metachar: render_env exits 0" test "$rc" -eq 0
check "metachar: key renders literally in the file" \
  grep -qxF 'TWITCH_STREAM_KEY="s3cr\et|with/&meta"' "$rendered"
check "metachar: sourcing the output yields the exact key" \
  bash -c 'set -a; . "$1"; set +a; [[ "$TWITCH_STREAM_KEY" == "$2" ]]' \
  _ "$rendered" "$fake_key"

# --- failure: render fails AFTER mktemp (failure-path temp cleanup) --------
# A fake sed models a failing environment: it exits 1 ONLY on the overlay
# invocation (the one whose script names TWITCH_STREAM_KEY) and delegates every
# other call to the real sed. It encodes no expected output, only a failure, so
# the rm -f "$tmp" arm in render_env is genuinely exercised.
reset_fixture
base_env | write_packaged_env
fake_key="pinned-fake-key"
fake_bin="$work/fakebin"
mkdir -p "$fake_bin"
cat >"$fake_bin/sed" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *'^TWITCH_STREAM_KEY='*) exit 1 ;;
  esac
done
exec ${real_sed} "\$@"
EOF
chmod +x "$fake_bin/sed"
saved_path="$PATH"
PATH="$fake_bin:$PATH"
render_env_call
rc=$?
PATH="$saved_path"
check "render failure: render_env exits non-zero" test "$rc" -ne 0
check "render failure: diagnostic names the render failure" \
  grep -q 'failed to render' "$stderr_file"
check "render failure: no leftover render temp files" \
  bash -c '[ -z "$(find "$1" -maxdepth 1 -name ".strimserver.env.*" -print -quit)" ]' \
  _ "$NVME_MOUNT/config"

# --- failure: escaping the key fails (sed transform status is checked) -----
# A fake sed models a failing escape step: it exits 1 ONLY on the escape
# invocation (its script carries the [\|&] class) and delegates the rest.
reset_fixture
base_env | write_packaged_env
fake_key="pinned-fake-key"
escape_bin="$work/escapebin"
mkdir -p "$escape_bin"
cat >"$escape_bin/sed" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *'s/['*) exit 1 ;;
  esac
done
exec ${real_sed} "\$@"
EOF
chmod +x "$escape_bin/sed"
saved_path="$PATH"
PATH="$escape_bin:$PATH"
render_env_call
rc=$?
PATH="$saved_path"
check "escape failure: render_env exits non-zero" test "$rc" -ne 0
check "escape failure: diagnostic names the TWITCH_STREAM_KEY escape" \
  grep -q 'failed to escape TWITCH_STREAM_KEY' "$stderr_file"

# --- overlay: an already-set packaged key is replaced, not appended --------
reset_fixture
cat >"$packaged" <<'EOF'
EGRESS_SNAPSHOT_ID="fixture-egress-xyz"
TWITCH_STREAM_KEY="stale-packaged-value"
BANDWIDTH_TEST="false"
EOF
fake_key="fresh-ssm-key"
render_env_call
rc=$?
check "existing value: render_env exits 0" test "$rc" -eq 0
check "existing value: replaced with the SSM key" \
  grep -qx 'TWITCH_STREAM_KEY="fresh-ssm-key"' "$rendered"
check "existing value: exactly one TWITCH_STREAM_KEY line" \
  test "$(grep -c '^TWITCH_STREAM_KEY=' "$rendered")" -eq 1

if [ "$failures" -ne 0 ]; then
  printf '\ncompleted: %d ok, %d skipped, %d failed\n' "$ok" "$skipped" "$failures" >&2
  exit 1
fi
printf '\ncompleted: %d ok, %d skipped\n' "$ok" "$skipped"
