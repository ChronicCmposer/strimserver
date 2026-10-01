#!/usr/bin/env bash
# Smoke test for the strim-ddns binary against local loopback test doubles.
#
# The Namecheap dynamicdns endpoint answers HTTP 200 for BOTH outcomes, so
# the body is authoritative. This test runs the binary against a tiny static
# C HTTP test double (ddns-test-server, HTTP mode) and exercises the
# body-based success detection:
#   - classic plain-text success ("Good 1.2.3.4")
#   - unchanged IP ("No change")
#   - XML <interface-response> with <ErrCount>0</ErrCount>
#   - failure bodies (plain-text "911" and XML <ErrCount>1)
# plus a request-log assertion that the client URL-escaped and sent the
# host/domain/password/ip query params.
#
# The check subcommand's direct-authoritative resolution is driven against
# the same double's UDP DNS mode: a stand-in recursive resolver (NS
# discovery + NS-hostname resolution, pointed at via the test-only
# DDNS_RESOLVER=127.0.0.1:<port> override) and a per-case authoritative
# server (the direct A query, pointed at via the test-only
# DDNS_AUTHORITATIVE_PORT=<port> override; production uses port 53). Each
# case asserts the stdout contract (one IPv4 or nothing), the exit code, the
# stderr line, and the request-log proof that the resolver saw the NS query
# while the authoritative server saw the direct A query.
#
# Runs on the host (sh_test); the binaries come from runfiles:
#   $1 = the strim-ddns binary
#   $2 = the ddns-test-server binary
set -euo pipefail

ddns="${1:?usage: ddns_smoke_test.sh <strim-ddns> <ddns-test-server>}"
server="${2:?missing ddns-test-server path (arg 2)}"

tmp="$(mktemp -d)"
spid=""
spid_r=""
spid_a=""
cleanup() {
    for pid in "$spid" "$spid_r" "$spid_a"; do
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$tmp"
}
trap cleanup EXIT

# wait_for_port <portfile> <desc> : blocks until a test server printed its
# ephemeral port; echoes it (empty on failure).
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
        kill "$spid" "$spid_r" "$spid_a" 2>/dev/null || true
        wait "$spid" "$spid_r" "$spid_a" 2>/dev/null || true
        spid=""
        spid_r=""
        spid_a=""
        echo "FAIL: test server did not report a port ($desc)" >&2
        return 1
    fi
    echo "$port"
}

# kill_server <pid-var> : stop one tracked test server and clear its var.
kill_server() {
    local -n pid_ref="$1"
    if [ -n "$pid_ref" ]; then
        kill "$pid_ref" 2>/dev/null || true
        wait "$pid_ref" 2>/dev/null || true
        pid_ref=""
    fi
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

    kill_server spid

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

# start_dns_pair <auth-config> : start the recursive resolver role (fixed
# behavior) plus one authoritative role configured by auth-config; fills
# resolver_port / auth_port.
start_dns_pair() {
    local auth_config="$1"
    local pfile_r="$tmp/port_r.$$" pfile_a="$tmp/port_a.$$"

    "$server" dns resolver fixed "$reqlog_r" > "$pfile_r" 2>/dev/null &
    spid_r=$!
    "$server" dns authoritative "$auth_config" "$reqlog_a" > "$pfile_a" 2>/dev/null &
    spid_a=$!

    resolver_port="$(wait_for_port "$pfile_r" "resolver")" || return 1
    auth_port="$(wait_for_port "$pfile_a" "authoritative: $auth_config")" || return 1
}

# run_dns_check_case <auth-config> <expected-rc> [<expected-ip>]
#   Drives the full direct-authoritative flow: NS discovery + NS-hostname
#   resolution against the resolver role (DDNS_RESOLVER), then the direct A
#   query against the authoritative role (DDNS_AUTHORITATIVE_PORT).
#   expected-rc: 0 (resolved; stdout must equal the expected-ip and stderr
#   must carry the success line) or 1 (not resolved; stdout must be empty).
#   Also asserts the resolver log saw the NS query for example.com and the
#   authoritative log saw the direct A query for testhost.example.com.
run_dns_check_case() {
    local auth_config="$1" want_rc="$2" want_ip="${3:-}"
    local out="$tmp/out.$$" err="$tmp/err.$$"
    reqlog_r="$tmp/reqlog_r.$$"
    reqlog_a="$tmp/reqlog_a.$$"
    local resolver_port="" auth_port=""

    start_dns_pair "$auth_config" || return 1

    set +e
    DDNS_RESOLVER="127.0.0.1:$resolver_port" \
    DDNS_AUTHORITATIVE_PORT="$auth_port" \
        "$ddns" check testhost example.com > "$out" 2> "$err"
    local rc=$?
    set -e

    kill_server spid_r
    kill_server spid_a

    if [ "$want_rc" = 0 ]; then
        if [ "$rc" -ne 0 ]; then
            cat "$err" >&2
            echo "FAIL: check expected rc=0, got $rc (config: $auth_config)" >&2
            return 1
        fi
        local got="$(cat "$out")"
        if [ "$got" != "$want_ip" ]; then
            cat "$err" >&2
            echo "FAIL: check expected stdout '$want_ip', got '$got' (config: $auth_config)" >&2
            return 1
        fi
        if ! grep -qF "check testhost.example.com -> $want_ip (via ns1.example.com)" "$err"; then
            cat "$err" >&2
            echo "FAIL: check missing stderr success line (config: $auth_config)" >&2
            return 1
        fi
    else
        if [ "$rc" -ne 1 ]; then
            cat "$err" >&2
            echo "FAIL: check expected rc=1, got $rc (config: $auth_config)" >&2
            return 1
        fi
        if [ -s "$out" ]; then
            cat "$err" >&2
            echo "FAIL: check expected empty stdout, got output (config: $auth_config)" >&2
            return 1
        fi
        if ! grep -qE "check testhost\.example\.com not resolved" "$err"; then
            cat "$err" >&2
            echo "FAIL: check missing stderr not-resolved line (config: $auth_config)" >&2
            return 1
        fi
    fi
    if ! grep -qF "DNS example.com NS" "$reqlog_r"; then
        cat "$reqlog_r" >&2
        echo "FAIL: resolver log missing NS query for example.com (config: $auth_config)" >&2
        return 1
    fi
    if ! grep -qF "DNS testhost.example.com A" "$reqlog_a"; then
        cat "$reqlog_a" >&2
        echo "FAIL: authoritative log missing direct A query (config: $auth_config)" >&2
        return 1
    fi
    rm -f "$out" "$err" "$reqlog_r" "$reqlog_a"
}

# --- update subcommand (HTTP mode) ---

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

# --- check subcommand: direct authoritative resolution (UDP DNS mode) ---

# Single A record on the authoritative server resolves to 1.2.3.4.
run_dns_check_case "single:1.2.3.4" 0 "1.2.3.4"

# CNAME then A (multi-record answer): the A record wins.
run_dns_check_case "cname:alias.example.com,5.6.7.8" 0 "5.6.7.8"

# NXDOMAIN from the authoritative server: not resolved.
run_dns_check_case "nxdomain" 1 ""

# SERVFAIL from the authoritative server: not resolved.
run_dns_check_case "servfail" 1 ""

# REFUSED from the authoritative server: not resolved.
run_dns_check_case "refused" 1 ""

# NOERROR with no answers: not resolved.
run_dns_check_case "empty" 1 ""

# CNAME only, no A: not resolved.
run_dns_check_case "only-cname:alias.example.com" 1 ""

# --- check subcommand: usage errors ---

# Missing host/domain: usage error (exit 2), nothing on stdout (the usage
# text goes to stderr).
set +e
"$ddns" check > "$tmp/usage_out.$$" 2> "$tmp/usage_err.$$"
usage_rc=$?
set -e
if [ "$usage_rc" -ne 2 ]; then
    cat "$tmp/usage_err.$$" >&2
    echo "FAIL: check with no args expected rc=2, got $usage_rc" >&2
    exit 1
fi
if [ -s "$tmp/usage_out.$$" ]; then
    cat "$tmp/usage_err.$$" >&2
    echo "FAIL: check with no args expected empty stdout" >&2
    exit 1
fi
if ! grep -q "usage:" "$tmp/usage_err.$$"; then
    cat "$tmp/usage_err.$$" >&2
    echo "FAIL: check with no args expected a usage line on stderr" >&2
    exit 1
fi
rm -f "$tmp/usage_out.$$" "$tmp/usage_err.$$"

echo "PASS: strim-ddns smoke test"