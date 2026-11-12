#!/usr/bin/env bash
# deploy/aws/lib/deploy.sh -- pure, sourceable helpers for deploy/aws/deploy.sh.
#
# Sourced by deploy/aws/deploy.sh (the fresh-instance deploy flow) and by
# deploy/aws/deploy_helpers_test.sh. There are NO top-level side effects: every
# function is predictable, takes its inputs explicitly, and receives the
# privilege prefix (`sudo`) from the CALL SITE rather than hard-coding it, so
# the helpers can be unit-tested without root.
#
# Call-site contract: `sudo_cmd` is a single command word (e.g. `sudo`) or the
# empty string when the caller is already root.

# Run "$@" behind an optional privilege prefix. Private to this library.
deploy__run() {
  local sudo_cmd="$1"
  shift
  if [ -n "$sudo_cmd" ]; then
    "$sudo_cmd" "$@"
  else
    "$@"
  fi
}

# Print a fresh 70-character [A-Za-z0-9] SRT passphrase on stdout.
#
# `head -c 70` closes the pipe while `tr` is still writing; under the caller's
# `set -o pipefail` that expected SIGPIPE would abort the deploy. Relax pipefail
# only around the pipe, restore it, then assert the length and fail loudly.
deploy_generate_srt_passphrase() {
  local passphrase pipefail_was_set=0
  if shopt -qo pipefail; then
    pipefail_was_set=1
  fi
  set +o pipefail
  passphrase="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 70)"
  if [ "$pipefail_was_set" -eq 1 ]; then
    set -o pipefail
  fi
  if [ "${#passphrase}" -ne 70 ]; then
    printf '[passphrase] ERROR: generated %s characters, expected 70\n' \
      "${#passphrase}" >&2
    return 1
  fi
  printf '%s\n' "$passphrase"
}

# Create or re-tighten <file> as a 0600 root:root SRT passphrase.
#
# The value is never printed. A re-run keeps the operator's existing passphrase
# (only re-tightening mode/owner); a missing/empty file is generated once.
# A missing parent directory is created 0750 root:root, but an existing parent
# (e.g. the /mnt/nvme mount root) is left untouched so the rest of the deploy
# can still traverse it as the SSH user.
deploy_write_srt_passphrase() {
  local file="$1"
  local sudo_cmd="${2:-}"
  local parent passphrase

  if [ -z "$file" ]; then
    printf '[passphrase] ERROR: output file argument is required\n' >&2
    return 1
  fi

  parent="$(dirname "$file")"
  if ! deploy__run "$sudo_cmd" test -d "$parent"; then
    deploy__run "$sudo_cmd" install -d -m 0750 -o root -g root "$parent" || {
      printf '[passphrase] ERROR: cannot create parent directory %s\n' "$parent" >&2
      return 1
    }
  fi

  if deploy__run "$sudo_cmd" test -s "$file"; then
    deploy__run "$sudo_cmd" chmod 0600 "$file" || {
      printf '[passphrase] ERROR: cannot tighten mode on %s\n' "$file" >&2
      return 1
    }
    deploy__run "$sudo_cmd" chown root:root "$file" 2>/dev/null || true
    return 0
  fi

  deploy__run "$sudo_cmd" install -m 0600 -o root -g root /dev/null "$file" || {
    printf '[passphrase] ERROR: cannot create %s\n' "$file" >&2
    return 1
  }
  passphrase="$(deploy_generate_srt_passphrase)" || return 1
  # feed through stdin so the value never appears in a process argv
  printf '%s\n' "$passphrase" | deploy__run "$sudo_cmd" tee "$file" >/dev/null || {
    printf '[passphrase] ERROR: cannot write %s\n' "$file" >&2
    return 1
  }
  deploy__run "$sudo_cmd" chmod 0600 "$file" || {
    printf '[passphrase] ERROR: cannot set 0600 on %s\n' "$file" >&2
    return 1
  }
  return 0
}

# Write <out> = canonical root/state TOML assignments + <config> with any
# existing top-level (or whitespace-indented) root/state assignments removed.
#
# Reading goes through the sudo prefix: a failed read of an EXISTING config is
# fatal and leaves <out> untouched (the old inline block truncated the config if
# the unprivileged read failed). A missing config is treated as empty and
# logged. The result is written atomically so a crash cannot half-write it.
deploy_prepend_containerd_root_state() {
  local config="$1"
  local out="$2"
  local sudo_cmd="${3:-}"
  local existing=""
  local tmp

  if [ -z "$config" ] || [ -z "$out" ]; then
    printf '[containerd] ERROR: config and out arguments are required\n' >&2
    return 1
  fi

  if deploy__run "$sudo_cmd" test -e "$config"; then
    if ! existing="$(deploy__run "$sudo_cmd" cat "$config")"; then
      printf '[containerd] ERROR: cannot read existing config %s; refusing to overwrite it\n' \
        "$config" >&2
      return 1
    fi
  else
    printf '[containerd] no existing config at %s; treating it as empty\n' \
      "$config" >&2
  fi

  tmp="$(mktemp "${out}.tmp.XXXXXX")" || {
    printf '[containerd] ERROR: cannot create a temporary file beside %s\n' "$out" >&2
    return 1
  }
  {
    printf "root='/mnt/nvme/containerd'\n"
    printf "state='/mnt/nvme/containerd-state'\n\n"
    if [ -n "$existing" ]; then
      printf '%s\n' "$existing" |
        grep -vE '^[[:space:]]*(root|state)[[:space:]]*=' || true
    fi
  } >"$tmp"

  if ! mv "$tmp" "$out"; then
    rm -f "$tmp"
    printf '[containerd] ERROR: cannot replace %s\n' "$out" >&2
    return 1
  fi
}

# Prepare the strimserver logs directory: 0750 root:root, with the three known
# log files pre-created 0640 (the containerd shim creates them, so entrypoint
# umask cannot control their mode), and every regular file normalized to 0640.
#
# <dir> must resolve to the expected root (DEPLOY_LOGS_ROOT, default
# /mnt/nvme/logs); a symlink or a different resolved path is rejected before
# any mutation. Existing log files are never truncated.
deploy_prepare_logs_directory() {
  local dir="$1"
  local sudo_cmd="${2:-}"
  local expected="${DEPLOY_LOGS_ROOT:-/mnt/nvme/logs}"
  local resolved expected_resolved log

  if [ -z "$dir" ]; then
    printf '[logs] ERROR: directory argument is required\n' >&2
    return 1
  fi
  if [ -L "$dir" ]; then
    printf '[logs] ERROR: %s is a symlink; refusing to follow it\n' "$dir" >&2
    return 1
  fi
  if ! resolved="$(realpath -m -- "$dir")"; then
    printf '[logs] ERROR: cannot resolve %s\n' "$dir" >&2
    return 1
  fi
  if ! expected_resolved="$(realpath -m -- "$expected")"; then
    printf '[logs] ERROR: cannot resolve expected root %s\n' "$expected" >&2
    return 1
  fi
  if [ "$resolved" != "$expected_resolved" ]; then
    printf '[logs] ERROR: %s resolves to %s, expected %s\n' \
      "$dir" "$resolved" "$expected_resolved" >&2
    return 1
  fi

  deploy__run "$sudo_cmd" install -d -m 0750 -o root -g root "$resolved" || {
    printf '[logs] ERROR: cannot create %s\n' "$resolved" >&2
    return 1
  }
  for log in mediamtx.log normalize.log egress.log; do
    if ! deploy__run "$sudo_cmd" test -e "$resolved/$log"; then
      deploy__run "$sudo_cmd" install -m 0640 -o root -g root /dev/null \
        "$resolved/$log" || {
        printf '[logs] ERROR: cannot pre-create %s\n' "$resolved/$log" >&2
        return 1
      }
    fi
  done
  deploy__run "$sudo_cmd" find -P "$resolved" -xdev -type f \
    -exec chmod 0640 {} + -exec chown root:root {} + || {
    printf '[logs] ERROR: cannot normalize log modes under %s\n' "$resolved" >&2
    return 1
  }
  return 0
}
