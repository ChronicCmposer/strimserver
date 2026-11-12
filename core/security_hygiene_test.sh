#!/usr/bin/env bash
# Security-hygiene gate for the runtime scripts and the deploy secret surface.
#
# Static checks (anchored, line-based):
#   * no shell xtrace enablement in core/controller/entrypoint.sh, core/transcode.sh,
#     or deploy/aws/deploy.sh (set -x, set -o xtrace, PS4, BASH_XTRACEFD, exported
#     SHELLOPTS/BASHOPTS)
#   * both runtime scripts set `umask 027` before sourcing the env file
#   * deploy.sh has no passphrase print, and pins the passphrase/env files to 0600
# Runtime checks:
#   * sentinel runtime test: a TWITCH_STREAM_KEY value never reaches stdout/stderr
#     through the entrypoint or the transcode redaction wrapper
#   * deploy_prepare_logs_directory creates 0750 dirs and 0640 files
#
# Usage under Bazel (args from `$(location ...)`):
#   security_hygiene_test.sh <transcode> <entrypoint.sh> <deploy.sh> <lib/deploy.sh>
# Direct invocation falls back to repo-relative paths.
set -u

fail=0
note_fail() {
    printf 'FAIL: %s\n' "$*" >&2
    fail=$((fail + 1))
}

# --- resolve inputs ----------------------------------------------------------
if [ "$#" -ge 4 ]; then
    TRANSCODE="$1"
    ENTRYPOINT="$2"
    DEPLOY="$3"
    DEPLOY_LIB="$4"
else
    repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
    TRANSCODE="$repo_root/core/transcode.sh"
    ENTRYPOINT="$repo_root/core/controller/entrypoint.sh"
    DEPLOY="$repo_root/deploy/aws/deploy.sh"
    DEPLOY_LIB="$repo_root/deploy/aws/lib/deploy.sh"
fi

for f in "$TRANSCODE" "$ENTRYPOINT" "$DEPLOY"; do
    [ -f "$f" ] || note_fail "missing required input: $f"
done

# --- static: no xtrace enablement -------------------------------------------
XTRACE_RE='^[[:space:]]*(set[[:space:]]+-[a-zA-Z]*x[a-zA-Z]*([[:space:]]|$)|set[[:space:]]+-o[[:space:]]+xtrace|(export[[:space:]]+)?(PS4|BASH_XTRACEFD)=|export[[:space:]]+(SHELLOPTS|BASHOPTS)([[:space:]=]|$))'

check_no_xtrace() {
    label="$1"
    file="$2"
    [ -f "$file" ] || return 0
    hits="$(grep -nE "$XTRACE_RE" "$file" || true)"
    if [ -n "$hits" ]; then
        note_fail "$label enables shell xtrace or trace hooks:"
        printf '%s\n' "$hits" >&2
    fi
}

check_no_xtrace "core/controller/entrypoint.sh" "$ENTRYPOINT"
check_no_xtrace "core/transcode.sh" "$TRANSCODE"
check_no_xtrace "deploy/aws/deploy.sh" "$DEPLOY"

# --- static: umask 027 precedes env sourcing --------------------------------
check_umask_before_source() {
    label="$1"
    file="$2"
    [ -f "$file" ] || return 0
    umask_line="$(grep -nE '^[[:space:]]*umask[[:space:]]+027([[:space:]]|$)' "$file" | head -n1 | cut -d: -f1)"
    source_line="$(grep -nE '^[[:space:]]*(\.|source)[[:space:]]+.*(\$ENV_FILE|STRIMSERVER_ENV_FILE)' "$file" | head -n1 | cut -d: -f1)"
    if [ -z "$umask_line" ]; then
        note_fail "$label does not set 'umask 027'"
        return
    fi
    if ! grep -q 'STRIMSERVER_ENV_FILE' "$file"; then
        note_fail "$label does not support \$STRIMSERVER_ENV_FILE"
        return
    fi
    if [ -z "$source_line" ]; then
        note_fail "$label does not source the env file"
        return
    fi
    if [ "$umask_line" -ge "$source_line" ]; then
        note_fail "$label sets umask 027 after sourcing the env file (umask line $umask_line, source line $source_line)"
    fi
}

check_umask_before_source "core/controller/entrypoint.sh" "$ENTRYPOINT"
check_umask_before_source "core/transcode.sh" "$TRANSCODE"

# --- static: deploy secret surface ------------------------------------------
if [ -f "$DEPLOY" ]; then
    # A passphrase may be written to its 0600 file, but never to stdout/stderr/logs.
    passphrase_prints="$(grep -nE '^[[:space:]]*(printf|echo|print)[^#]*\$SRT_READ_PASSPHRASE([^_[:alnum:]]|$)' "$DEPLOY" \
        | grep -vE '> *"?\$SRT_READ_PASSPHRASE_FILE' || true)"
    if [ -n "$passphrase_prints" ]; then
        note_fail "deploy/aws/deploy.sh prints the SRT passphrase:"
        printf '%s\n' "$passphrase_prints" >&2
    fi

    if ! grep -qE '(chmod[[:space:]]+0?600[^#]*SRT_READ_PASSPHRASE_FILE|install[[:space:]][^#]*-m[[:space:]]*0?600[^#]*SRT_READ_PASSPHRASE_FILE)' "$DEPLOY"; then
        if ! grep -qE '^[[:space:]]*umask[[:space:]]+077([[:space:]]|$)' "$DEPLOY"; then
            note_fail "deploy/aws/deploy.sh does not pin the SRT passphrase file to 0600"
        fi
    fi

    if ! grep -qE '(chmod[[:space:]]+0?600[^#]*(strimserver\.env|\$ENV_FILE"?[[:space:]]*$)|install[[:space:]][^#]*-m[[:space:]]*0?600[^#]*strimserver\.env)' "$DEPLOY"; then
        note_fail "deploy/aws/deploy.sh does not pin the runtime env file to 0600"
    fi
fi

# --- runtime fixtures -------------------------------------------------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/security-hygiene.XXXXXX")" || {
    printf 'FATAL: cannot create temp dir\n' >&2
    exit 1
}
trap 'rm -rf "$tmp"' EXIT INT TERM

sentinel="SENTINEL-DO-NOT-LOG-9f3a1c"

# --- runtime: entrypoint does not leak the key ------------------------------
entry_env="$tmp/entrypoint.env"
cat >"$entry_env" <<EOF
TWITCH_STREAM_KEY=$sentinel
SRT_PUBLISH_PASSPHRASE=another-sentinel-value
EOF

controller_stub="$tmp/controller-stub"
cat >"$controller_stub" <<'EOF'
#!/bin/sh
printf 'controller-stub started\n'
EOF
chmod +x "$controller_stub"

if [ -f "$ENTRYPOINT" ]; then
    out="$tmp/entrypoint.out"
    err="$tmp/entrypoint.err"
    status=0
    STRIMSERVER_ENV_FILE="$entry_env" STRIMSERVER_CONTROLLER="$controller_stub" \
        sh "$ENTRYPOINT" >"$out" 2>"$err" || status=$?
    if [ "$status" -ne 0 ]; then
        note_fail "entrypoint exited $status (stub controller); stderr: $(cat "$err")"
    fi
    if grep -qF "$sentinel" "$out" "$err"; then
        note_fail "entrypoint leaked TWITCH_STREAM_KEY to stdout/stderr"
    fi
    if ! grep -q 'starting controller' "$out"; then
        note_fail "entrypoint did not print its non-secret start message"
    fi
fi

# --- runtime: transcode redacts the key and preserves ffmpeg status ---------
ffmpeg_stub="$tmp/ffmpeg-stub"
cat >"$ffmpeg_stub" <<'EOF'
#!/bin/sh
# Mimic ffmpeg: arguments and diagnostics go to stderr only.
printf 'ffmpeg-stub args: %s\n' "$*" >&2
printf 'ffmpeg-stub key: %s\n' "$TWITCH_STREAM_KEY" >&2
exit "${STUB_FFMPEG_EXIT:-0}"
EOF
chmod +x "$ffmpeg_stub"

transcode_env="$tmp/transcode.env"
cat >"$transcode_env" <<EOF
FFMPEG_LOG_LEVEL=error
FFMPEG_NICE=0
STRIMSERVER_RTSP_PORT=8554
NORMALIZED_MPEGTS_SOCKET=$tmp/normalized.sock
TWITCH_INGEST_SERVER=ingest.example.invalid
TWITCH_STREAM_KEY=$sentinel
BANDWIDTH_TEST=false
SCALED_VIDEO_HEIGHT_PIXELS=720
EGRESS_VIDEO_BITRATE=3000k
EGRESS_VIDEO_MAXRATE=3000k
EGRESS_VIDEO_MINRATE=3000k
EGRESS_VIDEO_BUFSIZE=6000k
EGRESS_AUDIO_BITRATE=160k
EOF

if [ -f "$TRANSCODE" ]; then
    out="$tmp/transcode.out"
    err="$tmp/transcode.err"
    status=0
    STRIMSERVER_ENV_FILE="$transcode_env" FFMPEG_BIN="$ffmpeg_stub" \
        STUB_FFMPEG_EXIT=7 sh "$TRANSCODE" single_stage_egress >"$out" 2>"$err" || status=$?
    if [ "$status" -ne 7 ]; then
        note_fail "transcode did not preserve the ffmpeg exit status 7 (got $status)"
    fi
    if grep -qF "$sentinel" "$out" "$err"; then
        note_fail "transcode leaked TWITCH_STREAM_KEY to stdout/stderr:"
        grep -nF "$sentinel" "$out" "$err" >&2 || true
    fi
    if ! grep -q 'REDACTED' "$err"; then
        note_fail "transcode stderr did not pass through the redaction filter"
    fi
    if ! grep -q 'stage=single_stage_egress' "$out"; then
        note_fail "transcode did not print its non-secret stage message"
    fi
fi

# --- runtime: log-directory helper modes ------------------------------------
if [ -f "$DEPLOY_LIB" ]; then
    logs_dir="$tmp/helper-logs"
    fakebin="$tmp/fakebin"
    mkdir -p "$fakebin"
    cat >"$fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
# Unprivileged test double: drop root ownership flags, then run the command.
new=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|-g) shift 2 ;;
        -o=*|-g=*) shift ;;
        *) new+=("$1"); shift ;;
    esac
done
exec "${new[@]}"
EOF
    chmod +x "$fakebin/sudo"
    # Ownership cannot be asserted unprivileged; the helper's mode changes are.
    cat >"$fakebin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$fakebin/chown"

    if PATH="$fakebin:$PATH" DEPLOY_LOGS_ROOT="$logs_dir" bash -c '
        set +eu
        . "$1"
        mkdir -p "$2"
        : >"$2/sample.log"
        deploy_prepare_logs_directory "$2" sudo
    ' _ "$DEPLOY_LIB" "$logs_dir" >/dev/null 2>"$tmp/helper.err"; then
        if [ -d "$logs_dir" ]; then
            dir_mode="$(stat -c %a "$logs_dir" 2>/dev/null || stat -f %Lp "$logs_dir")"
            if [ "$dir_mode" != "750" ]; then
                note_fail "deploy_prepare_logs_directory set dir mode $dir_mode (want 750)"
            fi
            file_mode="$(stat -c %a "$logs_dir/sample.log" 2>/dev/null || stat -f %Lp "$logs_dir/sample.log")"
            if [ "$file_mode" != "640" ]; then
                note_fail "deploy_prepare_logs_directory set file mode $file_mode (want 640)"
            fi
        else
            note_fail "deploy_prepare_logs_directory did not create the logs dir"
        fi
    else
        note_fail "sourcing deploy/aws/lib/deploy.sh / calling deploy_prepare_logs_directory failed: $(cat "$tmp/helper.err")"
    fi
fi

if [ "$fail" -ne 0 ]; then
    printf '\nsecurity hygiene: %d check(s) failed\n' "$fail" >&2
    exit 1
fi

printf 'security hygiene: all checks passed\n'
