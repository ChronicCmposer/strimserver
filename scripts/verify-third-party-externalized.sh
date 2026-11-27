#!/usr/bin/env bash
# Verify the "third-party minimal externalization" migration (design §10).
#
# This script encodes two tiers of checks:
#
#   Always-on (fast, no build): the §10 structural checks, the stale-reference
#   git-grep gates, the MODULE.bazel vendored-comment gate, the dependency-level
#   `bazel query` gate, and the D10 include-collision `bazel aquery` gate. The
#   D10 gate's authoritative test is the include-path flag check
#   (-I/-iquote/-isystem); the literal aquery-text scan is informational only,
#   because `--include_commandline` lists the library's own input headers
#   (contract-mandated `src/microhttpd/*.h`) and so matches on a correct tree.
#   These are exactly the gates that guard against re-adding vendored source and
#   forbidden //third_party dependencies; they must run in every invocation.
#
#   Matrix (heavy): the §10 build/test/fetch commands, the check-deps audits,
#   and the MODULE.bazel.lock diff. These need fetched repositories and long
#   builds, so they are gated behind RUN_BAZEL_MATRIX=1 and off by default.
#
# Usage:
#   scripts/verify-third-party-externalized.sh              # structural + graph gates
#   RUN_BAZEL_MATRIX=1 scripts/verify-third-party-externalized.sh   # full §10 matrix
#
# Exit status is 0 only when every executed check passes; any failure exits 1.
#
# Design reference: /var/lib/opencode/dev/designs/third-party-minimal.rev4.md §10.
set -uo pipefail

RUN_BAZEL_MATRIX="${RUN_BAZEL_MATRIX:-0}"

failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
info() { printf 'INFO: %s\n' "$*"; }
skip() { printf 'SKIP: %s\n' "$*"; }

# Resolve the repo root so the script works from any cwd; fail loud if not a repo.
if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "FAIL: not inside a git work tree" >&2
    exit 1
fi
cd "${repo_root}" || { echo "FAIL: cannot cd to ${repo_root}" >&2; exit 1; }

# --- §10 structural checks: vendored source must be gone ---------------------
check_absent() {
    local path="$1"
    if [ -e "${path}" ]; then
        fail "vendored path still exists: ${path}"
    else
        pass "absent: ${path}"
    fi
}

# --- §10 stale-reference gate: no old //third_party labels outside third_party.
# rc 1 from git grep means "no matches" (the desired outcome); any other
# non-zero rc is a grep failure and must not be mistaken for success.
check_no_stale_labels() {
    local out rc
    out="$(git grep -n '//third_party/\(yyjson\|libmicrohttpd\|wslay\)' \
        -- '*.bazel' '*.c' '*.h' ':!third_party/**' \
           ':!tools/check-deps/BUILD.bazel' ':!MODULE.bazel')"
    rc=$?
    if [ "${rc}" -eq 1 ]; then
        pass "no stale //third_party labels outside third_party/"
        return
    fi
    if [ "${rc}" -ne 0 ]; then
        fail "git grep for stale labels failed: rc=${rc}"
        return
    fi
    printf '%s\n' "${out}" >&2
    fail "stale //third_party reference found"
}

# --- §10 MODULE.bazel vendored-comment gate (no //third_party label carries it).
check_no_vendored_comment() {
    local out rc
    out="$(git grep -n \
        'is vendored under third_party/wslay\|yyjson is vendored\|libmicrohttpd (third_party/libmicrohttpd' \
        MODULE.bazel)"
    rc=$?
    if [ "${rc}" -eq 1 ]; then
        pass "no stale MODULE.bazel vendored comment"
        return
    fi
    if [ "${rc}" -ne 0 ]; then
        fail "git grep for MODULE.bazel comment failed: rc=${rc}"
        return
    fi
    printf '%s\n' "${out}" >&2
    fail "stale MODULE.bazel vendored comment found"
}

# --- §10 dependency-level gate: whole controller closure must not depend on the
# old //third_party label form. A failed query fails the gate.
check_no_forbidden_dependency() {
    local out
    if ! out="$(bazel query 'deps(//core/controller/...)' --output=label)"; then
        fail "bazel query failed"
        return
    fi
    if grep -Eq '//third_party/(yyjson|libmicrohttpd|wslay):' <<<"${out}"; then
        grep -E '//third_party/(yyjson|libmicrohttpd|wslay):' <<<"${out}" >&2
        fail "forbidden //third_party dependency found"
        return
    fi
    pass "controller closure has no forbidden //third_party dependency"
}

# --- §10 include-collision gate (D10), literal aquery-text scan: informational
# only. `--include_commandline` lists every action's input files as well as its
# command line, so it legitimately contains the library's own
# `src/microhttpd/*.h` input headers (the contract requires globbing those
# internal headers). A match here is therefore expected on a correct tree and
# must never fail the gate; the authoritative test is the include-path flag
# check below (`check_no_microhttpd_include_flag`).
check_no_include_collision() {
    local cfg out
    for cfg in amd64 arm64; do
        if ! out="$(bazel aquery --config="${cfg}" --include_commandline \
            'mnemonic("CppCompile", //core/controller/c:strimserver-controller)')"; then
            fail "aquery failed: ${cfg}"
            continue
        fi
        if grep -Fq 'libmicrohttpd/src/microhttpd' <<<"${out}"; then
            info "literal aquery text contains src/microhttpd (expected: library input headers); see include-flag check: ${cfg}"
        else
            info "literal aquery text has no src/microhttpd (informational): ${cfg}"
        fi
    done
}

# --- D10 precise invariant: no CppCompile action may carry an include-path flag
# (-I/-iquote/-isystem) pointing at the MHD private directory.
check_no_microhttpd_include_flag() {
    local cfg out
    for cfg in amd64 arm64; do
        if ! out="$(bazel aquery --config="${cfg}" --include_commandline \
            'mnemonic("CppCompile", //core/controller/c:strimserver-controller)')"; then
            fail "aquery failed (include-flag check): ${cfg}"
            continue
        fi
        if grep -Eq '(-I|-iquote|-isystem)[^ ,]*src/microhttpd' <<<"${out}"; then
            fail "MHD private dir on an include path: ${cfg}"
            continue
        fi
        pass "no include-path flag points at src/microhttpd: ${cfg}"
    done
}

# --- §10 matrix: heavyweight commands, gated behind RUN_BAZEL_MATRIX=1 --------
run_step() {
    local label="$1"; shift
    printf 'STEP: %s\n  $ %s\n' "${label}" "$*"
    if "$@"; then
        pass "${label}"
    else
        local rc=$?
        fail "${label} (rc=${rc})"
    fi
}

run_matrix() {
    run_step "bazel fetch pinned repos" \
        bazel fetch @yyjson//... @libmicrohttpd//... @wslay//...
    run_step "build libraries amd64" \
        bazel build @yyjson//:yyjson @libmicrohttpd//:libmicrohttpd @wslay//:wslay --config=amd64
    run_step "build libraries arm64" \
        bazel build @yyjson//:yyjson @libmicrohttpd//:libmicrohttpd @wslay//:wslay --config=arm64
    run_step "build controller amd64" \
        bazel build //core/controller/c:strimserver-controller --config=amd64
    run_step "build controller arm64" \
        bazel build //core/controller/c:strimserver-controller --config=arm64
    run_step "build ddns amd64" \
        bazel build //tools/ddns:strim_ddns --config=amd64
    run_step "build ddns arm64" \
        bazel build //tools/ddns:strim_ddns --config=arm64
    run_step "smoke tests amd64" \
        bazel test //third_party/yyjson:yyjson_smoke_test \
                   //third_party/libmicrohttpd:mhd_smoke_test \
                   //third_party/wslay:wslay_smoke_test --config=amd64
    run_step "smoke tests arm64" \
        bazel test //third_party/yyjson:yyjson_smoke_test \
                   //third_party/libmicrohttpd:mhd_smoke_test \
                   //third_party/wslay:wslay_smoke_test --config=arm64
    run_step "phase3a gate" \
        bazel build //third_party:phase3a_gate --platforms=//tools/bazel:linux_arm64
    run_step "phase3a tests" \
        bazel test //third_party:phase3a_tests --platforms=//tools/bazel:linux_arm64
    run_step "check-deps + deps-pins tests" \
        bazel test //tools/check-deps/... //tools/deps-pins/...
    run_step "check-deps strict offline" \
        bazel run //tools/check-deps:check-deps -- --strict --offline --native-tools=false --json
    run_step "make check-deps (ignore path)" make check-deps
    run_step "MODULE.bazel.lock unchanged" git diff --exit-code MODULE.bazel.lock
}

echo "== §10 structural checks =="
check_absent third_party/yyjson/yyjson.c
check_absent third_party/yyjson/yyjson.h
check_absent third_party/libmicrohttpd/src
check_absent third_party/wslay/lib

echo "== §10 stale-reference gates =="
check_no_stale_labels
check_no_vendored_comment

echo "== §10 dependency graph gate =="
check_no_forbidden_dependency

echo "== §10 include-collision gate =="
check_no_include_collision
check_no_microhttpd_include_flag

echo "== §10 matrix =="
if [ "${RUN_BAZEL_MATRIX}" = "1" ]; then
    run_matrix
else
    skip "§10 build/test matrix (set RUN_BAZEL_MATRIX=1 to run)"
fi

echo
if [ "${failures}" -eq 0 ]; then
    echo "RESULT: PASS"
    exit 0
fi
echo "RESULT: FAIL (${failures} check(s) failed)" >&2
exit 1
