#!/usr/bin/env bash
# Smoke test for the strim-ddns binary against a local loopback HTTP server.
#
# The Namecheap dynamicdns endpoint answers HTTP 200 for BOTH outcomes, so
# the body is authoritative. This test runs the binary against a tiny static
# C HTTP test double (ddns-test-server) and exercises the body-based success
# detection:
#   - classic plain-text success ("Good 1.2.3.4")
#   - unchanged IP ("No change")
#   - XML <interface-response> with <ErrCount>0</ErrCount>
#   - failure bodies (plain-text "911" and XML <ErrCount>1)
# plus a request-log assertion that the client URL-escaped and sent the
# host/domain/password/ip query params. Runs on the host (sh_test); the
# binaries come from runfiles:
#   $1 = the strim-ddns binary
#   $2 = the ddns-test-server binary
set -euo pipefail

ddns="${1:?usage: ddns_smoke_test.sh <strim-ddns> <ddns-test-server>}"
server="${2:?missing ddns-test-server path (arg 2)}"

tmp="$(mktemp -d)"
spid=""
cleanup() {
    if [ -n "$spid" ]; then
        kill "$spid" 2>/dev/null || true
        wait "$spid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

# run_case <response-body> <expected-rc> [<expected-query-substring>]
run_case() {
    local body="$1" want_rc="$2" want_query="${3:-}"
    local portfile="$tmp/port.$$" reqlog="$tmp/reqlog.$$" pwfile="$tmp/pw.$$" out="$tmp/out.$$"
    printf 's3cr3t-pass&word\n' > "$pwfile"

    "$server" "$body" "$reqlog" > "$portfile" 2>/dev/null &
    spid=$!

    local port=""
    for _ in $(seq 1 100); do
        if [ -s "$portfile" ]; then
            port="$(cat "$portfile")"
            break
        fi
        sleep 0.05
    done
    if [ -z "$port" ]; then
        kill "$spid" 2>/dev/null || true
        wait "$spid" 2>/dev/null || true
        spid=""
        echo "FAIL: test server did not report a port (body: $body)" >&2
        return 1
    fi

    set +e
    DDNS_ENDPOINT="http://127.0.0.1:$port/update" "$ddns" testhost example.com "$pwfile" 1.2.3.4 > "$out" 2>&1
    local rc=$?
    set -e

    kill "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    spid=""

    if [ "$want_rc" = 0 ]; then
        if [ "$rc" -ne 0 ]; then
            cat "$out" >&2
            echo "FAIL: expected rc=0, got $rc (body: $body)" >&2
            return 1
        fi
    else
        if [ "$rc" -eq 0 ]; then
            cat "$out" >&2
            echo "FAIL: expected non-zero rc, got 0 (body: $body)" >&2
            return 1
        fi
    fi
    if [ -n "$want_query" ]; then
        if ! grep -qF "$want_query" "$reqlog"; then
            cat "$reqlog" >&2
            echo "FAIL: request log missing '$want_query' (body: $body)" >&2
            return 1
        fi
    fi
    rm -f "$portfile" "$reqlog" "$pwfile" "$out"
}

# Classic plain-text success: "Good <ip>". Assert the client sent the
# URL-escaped query (password '&' must become %26).
run_case "Good 1.2.3.4" 0 "host=testhost&domain=example.com&password=s3cr3t-pass%26word&ip=1.2.3.4"

# IP unchanged.
run_case "No change" 0 ""

# XML interface-response with ErrCount 0 and an empty <errors/>.
run_case "<interface-response><ErrCount>0</ErrCount><errors></errors></interface-response>" 0 "host=testhost"

# XML interface-response with ErrCount 1 (failure).
run_case "<interface-response><ErrCount>1</ErrCount><errors><err1>Domain not found</err1></errors></interface-response>" 1 ""

# Classic plain-text failure.
run_case "911 Domain Not Found" 1 ""

echo "PASS: strim-ddns smoke test"