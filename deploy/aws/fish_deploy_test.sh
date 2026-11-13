#!/usr/bin/env bash
# fish_deploy_test.sh -- offline regression test for fish_write_system_config.
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

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall fish deploy checks passed\n'
