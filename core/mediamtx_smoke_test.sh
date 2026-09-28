#!/usr/bin/env bash
# Smoke test for the mediamtx OCI image content and the musl-static C helpers
# that replaced the old busybox/glibc shell-toolchain image.
#
# The old image shipped busybox + glibc + envsubst and ran every binary
# through the ld-linux loader; the new image is a bare static-Go mediamtx
# plus the static musl /entrypoint C binary, and /notify is a host
# bind-mount (never inside the image). This test runs on the host (sh_test)
# against:
#   $1 = the mediamtx files tar (the image layer srcs, as built by pkg_tar)
#   $2 = the /entrypoint binary from runfiles (the tar also carries a copy)
#   $3 = the /notify binary from runfiles
#   $4 = the /notify_stub loopback HTTP test double from runfiles
set -euo pipefail

tar="${1:?usage: mediamtx_smoke_test.sh <mediamtx files tar> [entrypoint] [notify] [notify_stub]}"
notify_bin="${3:?missing /notify binary path (arg 3)}"
notify_stub_bin="${4:?missing /notify_stub binary path (arg 4)}"

tmp="$(mktemp -d)"
stub_pid=""
cleanup() {
    if [ -n "$stub_pid" ]; then
        kill "$stub_pid" 2>/dev/null || true
        wait "$stub_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

tar -xf "$tar" -C "$tmp"
entrypoint_runfiles="${2:-$tmp/entrypoint}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# A dynamic ELF carries a PT_INTERP program header (the loader path); a
# static musl binary has none, so `readelf -l | grep interp` must not match.
assert_static() {
    local f="$1"
    [ -x "$f" ] || fail "$f is not executable"
    if readelf -l "$f" 2>/dev/null | grep -qi 'interp'; then
        fail "$f has a PT_INTERP (dynamic glibc), expected musl-static"
    fi
    echo "ok: $f is statically linked"
}

assert_contains() {
    local needle="$1"
    local file="$2"
    grep -Fq -- "$needle" "$file" || fail "'$needle' not found in $file"
}

echo "+ /mediamtx --version runs directly (no loader)"
"$tmp/mediamtx" --version

echo "+ /entrypoint and /notify are static musl ELFs"
assert_static "$tmp/entrypoint"
assert_static "$entrypoint_runfiles"
assert_static "$notify_bin"
assert_static "$notify_stub_bin"

echo "+ /entrypoint --render-only"
sock="$tmp/mediamtx.sock"
touch "$sock"
printf 'KEY="value"\nNORMALIZED_MPEGTS_SOCKET="%s"\nSRT_PUBLISH_PASSPHRASE=""\n' "$sock" > "$tmp/strimserver.env"
printf 'key=${KEY} dollar=$KEY literal=$$ nope=$NOPE\n' > "$tmp/template"
output="$tmp/rendered"
STRIMSERVER_ENV_FILE="$tmp/strimserver.env" \
STRIMSERVER_TEMPLATE="$tmp/template" \
STRIMSERVER_OUTPUT="$output" \
    "$tmp/entrypoint" --render-only
assert_contains 'key=value' "$output"
assert_contains 'dollar=value' "$output"
assert_contains 'literal=$' "$output"
assert_contains 'nope=' "$output"
[ ! -e "$sock" ] || fail "/entrypoint did not unlink NORMALIZED_MPEGTS_SOCKET ($sock)"
echo "ok: render-only expanded the template and unlinked the socket"

echo "+ /notify against notify_stub (success path)"
log="$tmp/notify_stub.log"
port=""
start_stub() {
    local attempt i
    for attempt in {1..25}; do
        port=$(( (RANDOM % 20000) + 20000 ))
        "$notify_stub_bin" "$port" >"$log" 2>&1 &
        stub_pid=$!
        for i in {1..100}; do
            if ! kill -0 "$stub_pid" 2>/dev/null; then
                break
            fi
            if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
                exec 3>&- 3<&- 2>/dev/null || true
                return 0
            fi
            sleep 0.05
        done
        kill "$stub_pid" 2>/dev/null || true
        wait "$stub_pid" 2>/dev/null || true
        stub_pid=""
    done
    fail "could not start notify_stub on an ephemeral port"
}
start_stub

echo "+ notify ingress0 ready -> stub 200, notify exits 0"
CONTROLLER_HTTP_PORT="$port" "$notify_bin" ingress0 ready
grep -Eq '"path"[[:space:]]*:[[:space:]]*"ingress0"' "$log" || fail "stub log lacks \"path\":\"ingress0\""
grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"' "$log" || fail "stub log lacks \"status\":\"ready\""
echo "ok: notify delivered path=ingress0 status=ready"

echo "+ notify ingress0 fail -> stub 500, notify exits nonzero"
if CONTROLLER_HTTP_PORT="$port" "$notify_bin" ingress0 fail; then
    fail "notify exited 0 when the stub returned 500"
fi
echo "ok: notify failed loudly on HTTP 500"

echo "+ notify bad args -> nonzero"
if CONTROLLER_HTTP_PORT="$port" "$notify_bin" ingress0; then
    fail "notify with a missing status exited 0"
fi
if CONTROLLER_HTTP_PORT="$port" "$notify_bin"; then
    fail "notify with no args exited 0"
fi
echo "ok: notify rejects missing path/status"

echo "mediamtx smoke test ok"