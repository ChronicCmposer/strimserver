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
# host/domain/password/ip query params. It also exercises the check
# subcommand's DoH resolution against the same double's /resolve path
# (driven by DDNS_DOH_ENDPOINT): the A-record extraction, the not-resolved
# exit (empty / non-zero Status / non-IPv4 data), the CNAME skip, and a
# request-log assertion of the name=...&type=A query. Runs on the host
# (sh_test); the binaries come from runfiles:
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

# wait_for_port <portfile> <body-description> : blocks until the test server
# printed its ephemeral port; echoes it (empty on failure).
wait_for_port() {
    local portfile="$1" desc="$2" port=""
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
        echo "FAIL: test server did not report a port ($desc)" >&2
        return 1
    fi
    echo "$port"
}

# run_case <response-body> <expected-rc> [<expected-query-substring>] [<subcommand>]
run_case() {
    local body="$1" want_rc="$2" want_query="${3:-}" subcmd="${4:-}"
    local portfile="$tmp/port.$$" reqlog="$tmp/reqlog.$$" pwfile="$tmp/pw.$$" out="$tmp/out.$$"
    printf 's3cr3t-pass&word\n' > "$pwfile"

    "$server" "$body" "$reqlog" > "$portfile" 2>/dev/null &
    spid=$!

    local port=""
    port="$(wait_for_port "$portfile" "body: $body")" || return 1

    local prefix=()
    if [ -n "$subcmd" ]; then
        prefix=("$subcmd")
    fi

    set +e
    DDNS_ENDPOINT="http://127.0.0.1:$port/update" "$ddns" "${prefix[@]}" testhost example.com "$pwfile" 1.2.3.4 > "$out" 2>&1
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

# run_check_case <json-body> <expected-rc> [<expected-ip>]
#   expected-rc: 0 (resolved; stdout must equal the expected-ip) or 1 (not
#   resolved; stdout must be empty). Every case also asserts the client sent
#   the DoH query name=testhost.example.com&type=A to /resolve.
run_check_case() {
    local body="$1" want_rc="$2" want_ip="${3:-}"
    local portfile="$tmp/port.$$" reqlog="$tmp/reqlog.$$" out="$tmp/out.$$"

    "$server" "$body" "$reqlog" > "$portfile" 2>/dev/null &
    spid=$!

    local port=""
    port="$(wait_for_port "$portfile" "body: $body")" || return 1

    set +e
    DDNS_DOH_ENDPOINT="http://127.0.0.1:$port/resolve" "$ddns" check testhost example.com > "$out" 2>&1
    local rc=$?
    set -e

    kill "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    spid=""

    if [ "$want_rc" = 0 ]; then
        if [ "$rc" -ne 0 ]; then
            cat "$out" >&2
            echo "FAIL: check expected rc=0, got $rc (body: $body)" >&2
            return 1
        fi
        local got="$(cat "$out")"
        if [ "$got" != "$want_ip" ]; then
            cat "$out" >&2
            echo "FAIL: check expected stdout '$want_ip', got '$got' (body: $body)" >&2
            return 1
        fi
    else
        if [ "$rc" -ne 1 ]; then
            cat "$out" >&2
            echo "FAIL: check expected rc=1, got $rc (body: $body)" >&2
            return 1
        fi
        if [ -s "$out" ]; then
            cat "$out" >&2
            echo "FAIL: check expected empty stdout, got output (body: $body)" >&2
            return 1
        fi
    fi
    if ! grep -qF "name=testhost.example.com&type=A" "$reqlog"; then
        cat "$reqlog" >&2
        echo "FAIL: check request log missing 'name=testhost.example.com&type=A' (body: $body)" >&2
        return 1
    fi
    rm -f "$portfile" "$reqlog" "$out"
}

# run_check_fallback_case <json-body> <expected-ip>
#   Exercises the Google->Cloudflare fallback path: the primary DoH endpoint
#   (DDNS_DOH_PRIMARY_ENDPOINT) is pointed at a dead loopback port so the
#   transport fails fast, and the fallback endpoint
#   (DDNS_DOH_FALLBACK_ENDPOINT) is pointed at the live loopback test server.
#   Asserts check resolves the single-A JSON from the fallback and that the
#   fallback request carried the Cloudflare JSON Accept header.
run_check_fallback_case() {
    local body="$1" want_ip="$2"
    local portfile="$tmp/port.$$" reqlog="$tmp/reqlog.$$" out="$tmp/out.$$"

    "$server" "$body" "$reqlog" > "$portfile" 2>/dev/null &
    spid=$!

    local port=""
    port="$(wait_for_port "$portfile" "body: $body")" || return 1

    set +e
    DDNS_DOH_PRIMARY_ENDPOINT="http://127.0.0.1:1/resolve" \
    DDNS_DOH_FALLBACK_ENDPOINT="http://127.0.0.1:$port/resolve" \
        "$ddns" check testhost example.com > "$out" 2>&1
    local rc=$?
    set -e

    kill "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    spid=""

    if [ "$rc" -ne 0 ]; then
        cat "$out" >&2
        echo "FAIL: fallback check expected rc=0, got $rc (body: $body)" >&2
        return 1
    fi
    local got="$(cat "$out")"
    if [ "$got" != "$want_ip" ]; then
        cat "$out" >&2
        echo "FAIL: fallback check expected stdout '$want_ip', got '$got' (body: $body)" >&2
        return 1
    fi
    if ! grep -qF "Accept: application/dns-json" "$reqlog"; then
        cat "$reqlog" >&2
        echo "FAIL: fallback request log missing 'Accept: application/dns-json'" >&2
        return 1
    fi
    if ! grep -qF "name=testhost.example.com&type=A" "$reqlog"; then
        cat "$reqlog" >&2
        echo "FAIL: fallback request log missing 'name=testhost.example.com&type=A'" >&2
        return 1
    fi
    rm -f "$portfile" "$reqlog" "$out"
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

# Explicit "update" subcommand: the dispatch wrapper must not regress the
# legacy path exercised above.
run_case "Good 1.2.3.4" 0 "host=testhost" update

# --- check subcommand: DoH A-record resolution via DDNS_DOH_ENDPOINT ---

# Single A record resolves to 1.2.3.4.
run_check_case '{"Status":0,"Answer":[{"type":1,"data":"1.2.3.4"}]}' 0 "1.2.3.4"

# No Answer array: not resolved.
run_check_case '{"Status":0}' 1 ""

# Non-zero DNS Status: not resolved.
run_check_case '{"Status":3}' 1 ""

# Leading CNAME must be skipped; the A record wins.
run_check_case '{"Status":0,"Answer":[{"type":5,"data":"cname."},{"type":1,"data":"5.6.7.8"}]}' 0 "5.6.7.8"

# A record with non-IPv4 data: not resolved.
run_check_case '{"Status":0,"Answer":[{"type":1,"data":"not-an-ip"}]}' 1 ""

# --- check subcommand: Google->Cloudflare fallback ---

# Primary endpoint unreachable (dead loopback port 1, ECONNREFUSED fails
# fast) -> the client must fall through to the fallback endpoint and resolve
# the single-A JSON there, sending the Cloudflare JSON Accept header.
run_check_fallback_case '{"Status":0,"Answer":[{"type":1,"data":"9.9.9.9"}]}' "9.9.9.9"

echo "PASS: strim-ddns smoke test"