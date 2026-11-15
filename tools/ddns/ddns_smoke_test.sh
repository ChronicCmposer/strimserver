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
# host/domain/password/ip query params, and that an empty DDNS_IP sends NO
# ip= parameter (the endpoint records the requester IPv4).
#
# The check subcommand's per-nameserver agreement semantics are driven against
# the same double's UDP DNS mode. The resolver role is configured with a
# multi-NS set ("multi:ns1.example.com=127.0.0.2,ns2.example.com=127.0.0.3");
# distinct loopback addresses route each NS to its own authoritative server,
# all bound to one shared UDP port. Cases assert:
#   - every nameserver returns the expected IP -> exit 0, one stdout IPv4,
#     one line per NS;
#   - one nameserver disagrees -> non-zero, per-NS lines show the divergence;
#   - one nameserver unreachable -> non-zero, its line shows "none";
#   - a missing expected IP is a usage error (exit 2), never agreement-only
#     success: the expected IP is REQUIRED (3rd arg or DDNS_EXPECTED_IP);
#   - every discovered NS has no IPv4 A record -> non-zero, still one "none"
#     line per NS (defect: previously exited without the per-NS lines);
#   - the check never prints attempt counts ("verified after N attempts").
# Legacy single-NS cases (CNAME, NXDOMAIN, SERVFAIL, REFUSED, empty,
# CNAME-only) exercise the same per-NS flow with one nameserver.
#
# Structural assertions cover values that are not observable over the
# loopback wire: the c-ares budget (4000 ms x 2 tries) is applied to EVERY
# channel (no ares_init_options(..., NULL, 0)), and the update path pins IPv4
# egress (CURLOPT_IPRESOLVE=CURL_IPRESOLVE_V4). They read the binary's own
# source (passed as arg 3) so a regression fails here.
#
# Runs on the host (sh_test); the binaries come from runfiles:
#   $1 = the strim-ddns binary
#   $2 = the ddns-test-server binary
#   $3 = main.c (source-structure assertions)
set -euo pipefail

ddns="${1:?usage: ddns_smoke_test.sh <strim-ddns> <ddns-test-server> <main.c>}"
server="${2:?missing ddns-test-server path (arg 2)}"
main_src="${3:?missing main.c source path (arg 3)}"

tmp="$(mktemp -d)"
spid=""
spid_r=""
spid_a=""
spid_a2=""
cleanup() {
    for pid in "$spid" "$spid_r" "$spid_a" "$spid_a2"; do
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
        kill "$spid" "$spid_r" "$spid_a" "$spid_a2" 2>/dev/null || true
        wait "$spid" "$spid_r" "$spid_a" "$spid_a2" 2>/dev/null || true
        spid=""
        spid_r=""
        spid_a=""
        spid_a2=""
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

# assert_no_attempt_counts <file> : the check owns only the single decision;
# attempt counting belongs to the verify unit template.
assert_no_attempt_counts() {
    if grep -qiE 'attempt|verified after' "$1"; then
        cat "$1" >&2
        echo "FAIL: check output must not contain attempt counts" >&2
        return 1
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

# run_no_ip_case : update with DDNS_IP empty must send no ip= parameter.
run_no_ip_case() {
    local portfile="$tmp/nip_port.$$" reqlog="$tmp/nip_reqlog.$$" pwfile="$tmp/nip_pw.$$" out="$tmp/nip_out.$$"
    printf 'pw\n' > "$pwfile"

    "$server" "Good 1.2.3.4" "$reqlog" > "$portfile" 2>/dev/null &
    spid=$!
    local port=""
    port="$(wait_for_port "$portfile" "no-ip update")" || return 1

    set +e
    env -u DDNS_IP DDNS_ENDPOINT="http://127.0.0.1:$port/update" \
        "$ddns" update testhost example.com "$pwfile" > "$out" 2>&1
    local rc=$?
    set -e

    kill_server spid

    if [ "$rc" -ne 0 ]; then
        cat "$out" >&2
        echo "FAIL: no-ip update expected rc=0, got $rc" >&2
        return 1
    fi
    if ! grep -qF "host=testhost" "$reqlog"; then
        cat "$reqlog" >&2
        echo "FAIL: no-ip update request was not received" >&2
        return 1
    fi
    if grep -qF 'ip=' "$reqlog"; then
        cat "$reqlog" >&2
        echo "FAIL: empty DDNS_IP must not send an ip= parameter" >&2
        return 1
    fi
    rm -f "$portfile" "$reqlog" "$pwfile" "$out"
}

# start_dns_pair <auth-config> : start the recursive resolver role (fixed
# behavior) plus one authoritative role configured by auth-config; fills
# resolver_port / auth_port.
start_dns_pair() {
    local auth_config="$1"
    local pfile_r="$tmp/port_r.$$" pfile_a="$tmp/port_a.$$"

    "$server" dns resolver 127.0.0.1 0 fixed "$reqlog_r" > "$pfile_r" 2>/dev/null &
    spid_r=$!
    "$server" dns authoritative 127.0.0.1 0 "$auth_config" "$reqlog_a" > "$pfile_a" 2>/dev/null &
    spid_a=$!

    resolver_port="$(wait_for_port "$pfile_r" "resolver")" || return 1
    auth_port="$(wait_for_port "$pfile_a" "authoritative: $auth_config")" || return 1
}

# run_dns_check_case <auth-config> <expected-ip> <expected-rc> [<want-ip>]
#   Drives the single-NS direct-authoritative flow: NS discovery + NS-hostname
#   resolution against the resolver role (DDNS_RESOLVER), then the direct A
#   query through the NS's own IPv4 against the authoritative role
#   (DDNS_AUTHORITATIVE_PORT). expected-ip is always passed: the check requires
#   it, and passes only when the NS returns it.
run_dns_check_case() {
    local auth_config="$1" expected="$2" want_rc="$3" want_ip="${4:-}"
    local out="$tmp/out.$$" err="$tmp/err.$$"
    reqlog_r="$tmp/reqlog_r.$$"
    reqlog_a="$tmp/reqlog_a.$$"
    local resolver_port="" auth_port=""

    start_dns_pair "$auth_config" || return 1

    set +e
    DDNS_RESOLVER="127.0.0.1:$resolver_port" \
    DDNS_AUTHORITATIVE_PORT="$auth_port" \
        "$ddns" check testhost example.com "$expected" > "$out" 2> "$err"
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
        if ! grep -qF "check testhost.example.com -> $want_ip" "$err"; then
            cat "$err" >&2
            echo "FAIL: check missing stderr success summary (config: $auth_config)" >&2
            return 1
        fi
        if ! grep -qF "ns ns1.example.com -> $want_ip" "$err"; then
            cat "$err" >&2
            echo "FAIL: check missing per-NS line (config: $auth_config)" >&2
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
        if ! grep -qF "ns ns1.example.com -> none" "$err"; then
            cat "$err" >&2
            echo "FAIL: check missing per-NS 'none' line (config: $auth_config)" >&2
            return 1
        fi
    fi
    assert_no_attempt_counts "$err"
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

# run_multi_ns_check <desc> <ns-map> <ip1> <cfg1> <ip2> <cfg2|""> \
#                    <want-rc> <want-stdout> <want-ns1-line> <want-ns2-line> \
#                    [<expected-ip>]
#   Two nameservers (distinct loopback addresses, one shared authoritative
#   port). cfg2 empty means no server is started for the second NS: it is
#   unreachable. expected-ip, when given, is passed as the check's optional
#   third argument and must be returned by every NS.
run_multi_ns_check() {
    local desc="$1" nsmap="$2" ip1="$3" cfg1="$4" ip2="$5" cfg2="$6"
    local want_rc="$7" want_out="$8" want_ns1="$9" want_ns2="${10}"
    local expected="${11:-}"
    local out="$tmp/mout.$$" err="$tmp/merr.$$"
    local reqlog_r="$tmp/mreq_r.$$" reqlog_a1="$tmp/mreq_a1.$$" reqlog_a2="$tmp/mreq_a2.$$"
    local pfr="$tmp/mpfr.$$" pfa1="$tmp/mpfa1.$$" pfa2="$tmp/mpfa2.$$"

    "$server" dns resolver 127.0.0.1 0 "multi:$nsmap" "$reqlog_r" > "$pfr" 2>/dev/null &
    spid_r=$!
    local rport=""
    rport="$(wait_for_port "$pfr" "multi resolver: $desc")" || return 1

    "$server" dns authoritative "$ip1" 0 "$cfg1" "$reqlog_a1" > "$pfa1" 2>/dev/null &
    spid_a=$!
    local aport=""
    aport="$(wait_for_port "$pfa1" "multi auth1: $desc")" || return 1

    if [ -n "$cfg2" ]; then
        "$server" dns authoritative "$ip2" "$aport" "$cfg2" "$reqlog_a2" > "$pfa2" 2>/dev/null &
        spid_a2=$!
        wait_for_port "$pfa2" "multi auth2: $desc" >/dev/null || return 1
    fi

    set +e
    if [ -n "$expected" ]; then
        DDNS_RESOLVER="127.0.0.1:$rport" DDNS_AUTHORITATIVE_PORT="$aport" \
            "$ddns" check testhost example.com "$expected" > "$out" 2> "$err"
    else
        DDNS_RESOLVER="127.0.0.1:$rport" DDNS_AUTHORITATIVE_PORT="$aport" \
            "$ddns" check testhost example.com > "$out" 2> "$err"
    fi
    local rc=$?
    set -e

    kill_server spid_r
    kill_server spid_a
    kill_server spid_a2

    if [ "$want_rc" = 0 ]; then
        if [ "$rc" -ne 0 ]; then
            cat "$err" >&2
            echo "FAIL: multi-NS '$desc' expected rc=0, got $rc" >&2
            return 1
        fi
    else
        if [ "$rc" -eq 0 ]; then
            cat "$err" >&2
            echo "FAIL: multi-NS '$desc' expected non-zero rc, got 0" >&2
            return 1
        fi
    fi
    local got=""
    got="$(cat "$out")"
    if [ "$got" != "$want_out" ]; then
        cat "$err" >&2
        echo "FAIL: multi-NS '$desc' expected stdout '$want_out', got '$got'" >&2
        return 1
    fi
    if ! grep -qF "$want_ns1" "$err"; then
        cat "$err" >&2
        echo "FAIL: multi-NS '$desc' missing per-NS line '$want_ns1'" >&2
        return 1
    fi
    if [ -n "$want_ns2" ] && ! grep -qF "$want_ns2" "$err"; then
        cat "$err" >&2
        echo "FAIL: multi-NS '$desc' missing per-NS line '$want_ns2'" >&2
        return 1
    fi
    assert_no_attempt_counts "$err"
    rm -f "$out" "$err" "$reqlog_r" "$reqlog_a1" "$reqlog_a2" "$pfr" "$pfa1" "$pfa2"
}

# run_no_ns_address_case : every discovered NS is advertised but has no IPv4 A
# record. The check must still print one "-> none" line per NS before exiting
# 1, so an operator can see which nameservers lack an IPv4 address.
run_no_ns_address_case() {
    local out="$tmp/nout.$$" err="$tmp/nerr.$$"
    local reqlog_r="$tmp/nreq_r.$$" pfr="$tmp/npfr.$$"
    "$server" dns resolver 127.0.0.1 0 \
        "multi:ns1.example.com=nov4,ns2.example.com=nov4" \
        "$reqlog_r" > "$pfr" 2>/dev/null &
    spid_r=$!
    local rport=""
    rport="$(wait_for_port "$pfr" "no-ns-ipv4 resolver")" || return 1

    set +e
    DDNS_RESOLVER="127.0.0.1:$rport" \
        "$ddns" check testhost example.com 1.2.3.4 > "$out" 2> "$err"
    local rc=$?
    set -e

    kill_server spid_r

    if [ "$rc" -ne 1 ]; then
        cat "$err" >&2
        echo "FAIL: no-NS-IPv4 expected rc=1, got $rc" >&2
        return 1
    fi
    if [ -s "$out" ]; then
        cat "$err" >&2
        echo "FAIL: no-NS-IPv4 expected empty stdout" >&2
        return 1
    fi
    if ! grep -qF "ns ns1.example.com -> none" "$err"; then
        cat "$err" >&2
        echo "FAIL: no-NS-IPv4 missing per-NS 'none' line for ns1" >&2
        return 1
    fi
    if ! grep -qF "ns ns2.example.com -> none" "$err"; then
        cat "$err" >&2
        echo "FAIL: no-NS-IPv4 missing per-NS 'none' line for ns2" >&2
        return 1
    fi
    if ! grep -qE "check testhost\.example\.com not resolved" "$err"; then
        cat "$err" >&2
        echo "FAIL: no-NS-IPv4 missing not-resolved line" >&2
        return 1
    fi
    assert_no_attempt_counts "$err"
    rm -f "$out" "$err" "$reqlog_r" "$pfr"
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

# Empty DDNS_IP: no ip= parameter is sent, so Namecheap records the
# requester's IPv4.
run_no_ip_case

# --- check subcommand: per-nameserver agreement (UDP DNS mode) ---

# Every nameserver returns the expected IP: pass, one line per NS.
run_multi_ns_check "all match expected" "ns1.example.com=127.0.0.2,ns2.example.com=127.0.0.3" \
    127.0.0.2 "single:1.2.3.4" \
    127.0.0.3 "single:1.2.3.4" \
    0 "1.2.3.4" \
    "check testhost.example.com ns ns1.example.com -> 1.2.3.4" \
    "check testhost.example.com ns ns2.example.com -> 1.2.3.4" \
    "1.2.3.4"

# One nameserver lags behind with a different IP: fail ("not yet"), and the
# divergence is visible per NS.
run_multi_ns_check "one disagrees" "ns1.example.com=127.0.0.2,ns2.example.com=127.0.0.3" \
    127.0.0.2 "single:1.2.3.4" \
    127.0.0.3 "single:9.9.9.9" \
    1 "" \
    "ns ns1.example.com -> 1.2.3.4" \
    "ns ns2.example.com -> 9.9.9.9" \
    "1.2.3.4"

# One nameserver is unreachable: fail ("not yet"), its line reads none.
run_multi_ns_check "one unreachable" "ns1.example.com=127.0.0.2,ns2.example.com=127.0.0.5" \
    127.0.0.2 "single:1.2.3.4" \
    127.0.0.5 "" \
    1 "" \
    "ns ns1.example.com -> 1.2.3.4" \
    "ns ns2.example.com -> none" \
    "1.2.3.4"

# Expected IP not returned by the NS set: fail.
run_multi_ns_check "expected mismatch" "ns1.example.com=127.0.0.2,ns2.example.com=127.0.0.3" \
    127.0.0.2 "single:1.2.3.4" \
    127.0.0.3 "single:1.2.3.4" \
    1 "" \
    "ns ns1.example.com -> 1.2.3.4" \
    "ns ns2.example.com -> 1.2.3.4" \
    "5.5.5.5"

# Every discovered NS lacks an IPv4 A record: still one "none" line per NS.
run_no_ns_address_case

# --- check subcommand: single-NS direct authoritative resolution ---

# Single A record on the authoritative server resolves to 1.2.3.4.
run_dns_check_case "single:1.2.3.4" "1.2.3.4" 0 "1.2.3.4"

# CNAME then A (multi-record answer): the A record wins.
run_dns_check_case "cname:alias.example.com,5.6.7.8" "5.6.7.8" 0 "5.6.7.8"

# NXDOMAIN from the authoritative server: not resolved.
run_dns_check_case "nxdomain" "1.2.3.4" 1 ""

# SERVFAIL from the authoritative server: not resolved.
run_dns_check_case "servfail" "1.2.3.4" 1 ""

# REFUSED from the authoritative server: not resolved.
run_dns_check_case "refused" "1.2.3.4" 1 ""

# NOERROR with no answers: not resolved.
run_dns_check_case "empty" "1.2.3.4" 1 ""

# CNAME only, no A: not resolved.
run_dns_check_case "only-cname:alias.example.com" "1.2.3.4" 1 ""

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

# Missing expected IP: the check requires it (a bare agreement success is no
# longer accepted). Usage error (exit 2), nothing on stdout, and the message
# names the missing expected IP. DDNS_RESOLVER points at a closed port so a
# regression that proceeds to DNS fails fast instead of hanging.
set +e
env -u DDNS_EXPECTED_IP DDNS_RESOLVER="127.0.0.1:1" \
    "$ddns" check testhost example.com \
    > "$tmp/noexp_out.$$" 2> "$tmp/noexp_err.$$"
noexp_rc=$?
set -e
if [ "$noexp_rc" -ne 2 ]; then
    cat "$tmp/noexp_err.$$" >&2
    echo "FAIL: check without expected IP expected rc=2, got $noexp_rc" >&2
    exit 1
fi
if [ -s "$tmp/noexp_out.$$" ]; then
    cat "$tmp/noexp_err.$$" >&2
    echo "FAIL: check without expected IP expected empty stdout" >&2
    exit 1
fi
if ! grep -qi "expected" "$tmp/noexp_err.$$" ||
    ! grep -q "usage:" "$tmp/noexp_err.$$"; then
    cat "$tmp/noexp_err.$$" >&2
    echo "FAIL: missing expected IP must print a usage error naming it" >&2
    exit 1
fi
rm -f "$tmp/noexp_out.$$" "$tmp/noexp_err.$$"

# --- structural assertions: configured values not visible over the wire ---

# c-ares is configured at 4000 ms x 2 tries (each phase <= 8s, worst case
# ~24s < the verify unit's per-attempt timeout 30).
if ! grep -qF "DDNS_DNS_TIMEOUT_MS 4000L" "$main_src"; then
    echo "FAIL: c-ares timeout must be configured at 4000 ms" >&2
    exit 1
fi
if ! grep -qF "DDNS_DNS_TRIES 2" "$main_src"; then
    echo "FAIL: c-ares tries must be configured at 2" >&2
    exit 1
fi
# EVERY c-ares channel must pass the configured options struct. A bare
# ares_init_options(..., NULL, 0) leaves the production resolver channel on
# library defaults, so NS discovery/hostname resolution ignored the budget.
if ! grep -qF "init_channel_options" "$main_src"; then
    echo "FAIL: c-ares options must be populated by a shared helper" >&2
    exit 1
fi
# Match only real call expressions (an open paren followed by an argument);
# a comment mentioning "ares_init_options()" has "()" and is ignored.
init_calls="$(grep -nE 'ares_init_options\([^)]' "$main_src" || true)"
if [ -z "$init_calls" ]; then
    echo "FAIL: no ares_init_options call site found" >&2
    exit 1
fi
if printf '%s\n' "$init_calls" | grep -q 'NULL'; then
    printf '%s\n' "$init_calls" >&2
    echo "FAIL: ares_init_options must never pass NULL options" >&2
    exit 1
fi
bad_init="$(printf '%s\n' "$init_calls" | grep -v '&options' || true)"
if [ -n "$bad_init" ]; then
    echo "$bad_init" >&2
    echo "FAIL: every ares_init_options call must pass the configured options" >&2
    exit 1
fi
# The update path pins IPv4 egress.
if ! grep -qF "CURLOPT_IPRESOLVE" "$main_src" ||
    ! grep -qF "CURL_IPRESOLVE_V4" "$main_src"; then
    echo "FAIL: update path must set CURLOPT_IPRESOLVE=CURL_IPRESOLVE_V4" >&2
    exit 1
fi

echo "PASS: strim-ddns smoke test"
