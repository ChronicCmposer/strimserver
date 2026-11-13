#!/usr/bin/env bash
# fish_deploy_test.sh -- offline regression test for fish_write_system_config
# and fish_write_system_shells.
#
# The deploy runs under `umask 077`. The old flow `sudo mkdir /etc/fish` +
# `cat /etc/fish/config.fish prompt_login.fish | sudo tee ...` left /etc/fish
# 0700 root:root, so the unprivileged `cat` could not traverse it; it failed
# but still emitted the prompt, truncating config.fish to the prompt body. This
# test drives the fixed helper through a recording fake `sudo` to prove the
# directory/file modes, content composition, and that the privileged config is
# never read by an unprivileged `cat`.
#
# No root, no network, no real /etc writes: everything lives under mktemp -d.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FISH_DEPLOY_LIB_ONLY=1
# shellcheck source=fish-deploy.sh
source "$script_dir/fish-deploy.sh"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

# deploy.sh runs under this umask; the helper's explicit modes must win over it.
umask 077

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

mode_of() { stat -c '%a' "$1"; }

# --- fixtures ----------------------------------------------------------------
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
sudo_log="$tmp/sudo.log"
cat_log="$tmp/cat.log"
: >"$sudo_log"
: >"$cat_log"

cat >"$fake_bin/sudo" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SUDO_LOG:?}"
exec "$@"
SHIM
chmod +x "$fake_bin/sudo"

cat >"$fake_bin/cat" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CAT_LOG:?}"
exec /bin/cat "$@"
SHIM
chmod +x "$fake_bin/cat"
PATH="$fake_bin:$PATH"
FAKE_SUDO_LOG="$sudo_log"
FAKE_CAT_LOG="$cat_log"
TMPDIR="$tmp/tmpdir"
mkdir -p "$TMPDIR"
export PATH FAKE_SUDO_LOG FAKE_CAT_LOG TMPDIR

prompt_file="$tmp/prompt_login.fish"
cat >"$prompt_file" <<'PROMPT'
set -gx PROMPT_REGRESSION_MARKER 1
PROMPT

config_file="$tmp/system/etc/fish/config.fish"
config_dir="$(dirname "$config_file")"

# --- exercise ----------------------------------------------------------------
fish_write_system_config "$config_file" "$prompt_file" "$fake_bin/sudo"

# --- assertions --------------------------------------------------------------
check "parent directory is created 0755" \
  test "$(mode_of "$config_dir")" = "755"
check "config file is installed 0644" \
  test "$(mode_of "$config_file")" = "644"
check "header line appears exactly once" \
  test "$(grep -cE '^if status is-interactive$' "$config_file")" = "1"
check "host color header appears exactly once" \
  test "$(grep -cE '^set -gx fish_color_host_remote brcyan$' "$config_file")" = "1"
check "prompt body is appended" \
  grep -qx 'set -gx PROMPT_REGRESSION_MARKER 1' "$config_file"
check "no duplicate header block" \
  test "$(grep -cE '^[[:space:]]*fish_vi_key_bindings$' "$config_file")" = "1"
check "fake sudo recorded install -d" \
  grep -q -- 'install -d -m 0755' "$sudo_log"
check "fake sudo recorded install -m 0644" \
  grep -q -- 'install -m 0644' "$sudo_log"
check "unprivileged cat never read the config" \
  bash -c '! grep -Fxq -- "$1" "$2"' _ "$config_file" "$cat_log"
check "temp file is removed" \
  test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"

# --- fish_write_system_shells ------------------------------------------------
# The deploy runs under `umask 077`; a plain `sudo cp /etc/shells
# /etc/shells.original` leaves the copy 0600 root:root and the unprivileged
# `cat` then fails. These cases prove the helper repairs the mode, composes
# fish + original, installs 0644, and stays idempotent.
fish_shell="/usr/local/bin/fish"

shells_root="$tmp/shells"
mkdir -p "$shells_root"

# Case 1: absent original -> seeded from the current shells file.
absent_dir="$shells_root/absent"
mkdir -p "$absent_dir"
absent_original="$absent_dir/shells.original"
absent_shells="$absent_dir/shells"
printf '/bin/bash\n/bin/sh\n' >"$absent_shells"
: >"$sudo_log"

fish_write_system_shells "$fish_shell" "$absent_original" "$absent_shells" "$fake_bin/sudo"

check "absent original: original created 0644" \
  test "$(mode_of "$absent_original")" = "644"
check "absent original: shells file 0644" \
  test "$(mode_of "$absent_shells")" = "644"
check "absent original: fish shell is first entry" \
  test "$(head -n 1 "$absent_shells")" = "$fish_shell"
check "absent original: original entries preserved after fish" \
  test "$(tail -n +2 "$absent_shells")" = "$(printf '/bin/bash\n/bin/sh')"
check "absent original: fish shell appears exactly once" \
  test "$(grep -Fxc "$fish_shell" "$absent_shells")" = "1"
check "absent original: fake sudo chmodded 0644 original" \
  grep -q -- "chmod 0644 $absent_original" "$sudo_log"
check "absent original: temp file is removed" \
  test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"

# Case 2: existing original left 0600 by the inherited umask.
repair_dir="$shells_root/repair"
mkdir -p "$repair_dir"
repair_original="$repair_dir/shells.original"
repair_shells="$repair_dir/shells"
printf '/bin/bash\n/usr/bin/zsh\n' >"$repair_original"
printf '/bin/sh\n' >"$repair_shells"
chmod 0600 "$repair_original"
: >"$sudo_log"

fish_write_system_shells "$fish_shell" "$repair_original" "$repair_shells" "$fake_bin/sudo"

check "0600 original: chmodded back to 0644" \
  test "$(mode_of "$repair_original")" = "644"
check "0600 original: shells file 0644" \
  test "$(mode_of "$repair_shells")" = "644"
check "0600 original: chmod recorded before read" \
  grep -q -- "chmod 0644 $repair_original" "$sudo_log"
check "0600 original: fish + existing entries composed" \
  test "$(cat "$repair_shells")" = "$(printf '%s\n/bin/bash\n/usr/bin/zsh' "$fish_shell")"
check "0600 original: temp file is removed" \
  test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"

# Case 3: repeat invocation is idempotent.
repair_first="$(cat "$repair_shells")"
: >"$sudo_log"

fish_write_system_shells "$fish_shell" "$repair_original" "$repair_shells" "$fake_bin/sudo"

check "repeat: content unchanged" \
  test "$(cat "$repair_shells")" = "$repair_first"
check "repeat: original preserved unchanged" \
  test "$(cat "$repair_original")" = "$(printf '/bin/bash\n/usr/bin/zsh')"
check "repeat: fish shell not duplicated" \
  test "$(grep -Fxc "$fish_shell" "$repair_shells")" = "1"
check "repeat: modes remain 0644" \
  bash -c 'test "$1" = 644 && test "$2" = 644' _ \
  "$(mode_of "$repair_original")" "$(mode_of "$repair_shells")"
check "repeat: temp file is removed" \
  test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall fish deploy checks passed\n'
