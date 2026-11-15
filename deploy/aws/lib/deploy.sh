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

# Print the canonical containerd config source path: deploy/aws/containerd-config.toml.
#
# The repo layout is deploy/aws/lib/deploy.sh and the bundle layout is
# /mnt/nvme/lib/deploy.sh, so the canonical file is always one level above this
# library. Resolving it here keeps a single source of truth instead of
# regenerating the root/state text inline.
deploy__canonical_containerd_config() {
  local lib_dir
  lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1
  printf '%s/../containerd-config.toml\n' "$lib_dir"
}

# Write <out> = canonical containerd config bytes followed by <config> with any
# existing top-level (or whitespace-indented) root/state assignments removed.
#
# The canonical bytes come from deploy/aws/containerd-config.toml (root line,
# state line, one blank separator line, trailing newline) and are copied
# verbatim, never regenerated: <source> overrides the default sibling path for
# tests, and an absent <source> is fatal rather than silently emitting a
# divergent config. Existing settings therefore stay after the separator at
# runtime, with exactly one canonical root/state pair.
#
# Reading goes through the sudo prefix: a failed read of an EXISTING config is
# fatal and leaves <out> untouched (the old inline block truncated the config if
# the unprivileged read failed). A missing config is treated as empty and
# logged. The result is written atomically so a crash cannot half-write it.
deploy_prepend_containerd_root_state() {
  local config="$1"
  local out="$2"
  local sudo_cmd="${3:-}"
  local source="${4:-}"
  local existing=""
  local tmp

  if [ -z "$config" ] || [ -z "$out" ]; then
    printf '[containerd] ERROR: config and out arguments are required\n' >&2
    return 1
  fi

  if [ -z "$source" ]; then
    if ! source="$(deploy__canonical_containerd_config)"; then
      printf '[containerd] ERROR: cannot resolve the canonical containerd config path\n' >&2
      return 1
    fi
  fi
  if ! test -s "$source"; then
    printf '[containerd] ERROR: canonical containerd config %s is missing or empty\n' \
      "$source" >&2
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
    cat -- "$source" || {
      rm -f "$tmp"
      printf '[containerd] ERROR: cannot read canonical containerd config %s\n' \
        "$source" >&2
      return 1
    }
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

# Prepare the strimserver logs directory: 0755 root:root, with the three known
# log files pre-created 0640 (the containerd shim creates them, so entrypoint
# umask cannot control their mode), and every regular file normalized to 0640.
#
# The directory itself is 0755 (world-traversable, not writable): deploy.sh runs
# an unprivileged `tee -a` process substitution and an EXIT trap that writes
# deploy-last.rc, both of which must be able to traverse /mnt/nvme/logs. A 0750
# directory would silently deny them on a fresh volume.
#
# deploy.sh pre-creates its own deploy-<timestamp>.log and deploy-last.rc as
# 0640 ec2-user (so it can prune and write them without sudo), so deploy-*
# artifacts are excluded from normalization; every other regular file still
# becomes root:root 0640.
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

  deploy__run "$sudo_cmd" install -d -m 0755 -o root -g root "$resolved" || {
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
    ! -name 'deploy-*' \
    -exec chmod 0640 {} + -exec chown root:root {} + || {
    printf '[logs] ERROR: cannot normalize log modes under %s\n' "$resolved" >&2
    return 1
  }
  return 0
}

# Merge the transferred DDNS settings into <env_file> (strimserver.env).
#
# Call-site ordering contract: deploy.sh MUST call this BEFORE it issues
# `systemctl enable --now strim-ddns.timer`. The timer is Persistent=true, so
# enabling it can start strim-ddns.service immediately; the unit reads
# DDNS_HOST/DDNS_DOMAIN from this file, so the settings must already be present
# or the first timer-triggered refresh runs with stale/missing values.
#
# Only ENABLE_DDNS, DDNS_HOST, and DDNS_DOMAIN are merged. Each key present in
# <settings_file> replaces every existing assignment (any leading whitespace) and
# is appended once at the end, so re-runs are byte-for-byte idempotent and never
# duplicate a key. Every unrelated env key is preserved. The file is replaced
# atomically via a same-directory temp file, mode 0600. A missing/empty settings
# file is a no-op; a missing <env_file> is fatal because there is nothing safe to
# update.
deploy_write_ddns_env_settings() {
  local env_file="$1"
  local settings_file="$2"
  local key assignment key_pattern tmp
  local -a written_keys=()
  local -a assignments=()

  if [ -z "$env_file" ] || [ -z "$settings_file" ]; then
    printf '[ddns] ERROR: env and settings file arguments are required\n' >&2
    return 1
  fi
  if [ ! -s "$settings_file" ]; then
    return 0
  fi
  if [ ! -f "$env_file" ]; then
    printf '[ddns] ERROR: env file %s does not exist\n' "$env_file" >&2
    return 1
  fi

  for key in ENABLE_DDNS DDNS_HOST DDNS_DOMAIN; do
    assignment="$(grep -m1 "^${key}=" "$settings_file" || true)"
    if [ -z "$assignment" ]; then
      continue
    fi
    written_keys+=("$key")
    assignments+=("$assignment")
  done
  if [ "${#assignments[@]}" -eq 0 ]; then
    return 0
  fi

  tmp="$(mktemp "${env_file}.tmp.XXXXXX")" || {
    printf '[ddns] ERROR: cannot create a temporary file beside %s\n' "$env_file" >&2
    return 1
  }
  key_pattern="$(IFS='|'; printf '%s' "${written_keys[*]}")"
  {
    grep -vE "^[[:space:]]*(${key_pattern})[[:space:]]*=" "$env_file" || true
    printf '%s\n' "${assignments[@]}"
  } >"$tmp"

  if ! chmod 0600 "$tmp" || ! mv -- "$tmp" "$env_file"; then
    rm -f "$tmp"
    printf '[ddns] ERROR: cannot update %s\n' "$env_file" >&2
    return 1
  fi
  return 0
}

# Sync the canonical root/state containerd config to <config>, restarting
# containerd ONLY when the content actually changes.
#
# The baked AMI already ships the canonical config, so a fast-path deploy must
# not bounce containerd for an identical file. Prints exactly one of
#   changed     config was rewritten and containerd restarted
#   unchanged   config already matched; no write, no restart
# and leaves no scratch file behind. <out> is a caller-owned temp path beside
# which the canonical content is assembled atomically by
# deploy_prepend_containerd_root_state. <source> is the canonical repo/bundle
# file and defaults to the sibling containerd-config.toml.
deploy_apply_containerd_config() {
  local config="$1" out="$2" sudo_cmd="${3:-}" source="${4:-}"

  if [ -z "$config" ] || [ -z "$out" ]; then
    printf '[containerd] ERROR: config and out arguments are required\n' >&2
    return 1
  fi

  deploy_prepend_containerd_root_state "$config" "$out" "$sudo_cmd" "$source" || return 1

  if deploy__run "$sudo_cmd" test -e "$config" \
      && deploy__run "$sudo_cmd" cmp -s "$out" "$config"; then
    rm -f "$out"
    printf 'unchanged\n'
    return 0
  fi

  if ! deploy__run "$sudo_cmd" install -m 644 "$out" "$config"; then
    rm -f "$out"
    printf '[containerd] ERROR: cannot install %s\n' "$config" >&2
    return 1
  fi
  rm -f "$out"

  if ! deploy__run "$sudo_cmd" systemctl restart containerd.service; then
    printf '[containerd] ERROR: cannot restart containerd.service\n' >&2
    return 1
  fi
  printf 'changed\n'
  return 0
}
