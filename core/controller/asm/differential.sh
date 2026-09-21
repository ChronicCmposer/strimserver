#!/usr/bin/env bash
#
# Phase 5 end-to-end differential: the aarch64 assembly controller vs the Go
# controller (the oracle), byte-for-byte across the three codegen/check flags.
#
# PREREQUISITES
#   * an aarch64 host: controller_asm is aarch64-only, the checkers here run
#     natively, and the asm binary must execute without emulation;
#   * a host `go` toolchain on PATH: the Go oracle is built with the HOST
#     toolchain because the pinned Bazel go_binary (strimserver-controller)
#     is hardcoded goarch=amd64 and cannot run on an aarch64 host;
#   * `bazel` on PATH (used to build controller_asm for the arm64 target
#     platform).
#
# WHAT IT DOES
#   1. Builds the Go oracle with the host `go`:  go build ./core/controller
#   2. Builds the asm controller:               bazel build //core/controller:controller_asm
#   3. Diffs the three flag outputs byte-for-byte, under a full valid env:
#        -print-env-example, -print-ts-types, -check-env
#      (the valid env comes from the repo's core/strimserver.env.example when
#      present -- the harness sources it and fills the deliberately-empty
#      secrets -- else it derives one from the Go oracle's own
#      -print-env-example output).
#   Exits non-zero on ANY diff (or on a -check-env exit-code mismatch).
#
# This is the Phase 5 END-TO-END differential: the per-module differentials
# (Phases 4.1-4.7) already proved each asm function against the Go
# reference; this harness proves the assembled whole. It is deliberately NOT
# wired as a Bazel test -- Bazel tests cannot assume a host `go` toolchain --
# so it is a committed dev harness, run by hand (or by a CI gate) on an
# aarch64 host.
#
# USAGE
#   core/controller/asm/differential.sh
# EXIT
#   0 = GREEN (asm == Go byte-for-byte on all three flags)
#   1 = RED   (a diff or a build failure)
#
set -euo pipefail

# Repo root, regardless of where the script is invoked from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/phase5-diff.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

# --- 1. Go oracle, built with the HOST go toolchain -------------------------
# The module root is core/controller (that is where go.mod lives); build from
# inside it so the module cache and go.sum resolve exactly as the repo pins.
GO="$OUT/go-controller"
( cd "$ROOT/core/controller" && go build -o "$GO" . )
[ -x "$GO" ] || { echo "ERROR: go build produced no oracle at $GO" >&2; exit 1; }

# --- 2. The asm controller, built by Bazel for the arm64 target ------------
bazel build //core/controller:controller_asm --platforms=//tools/bazel:linux_arm64 >/dev/null
ASM="$(bazel cquery --output=files //core/controller:controller_asm \
      --platforms=//tools/bazel:linux_arm64 2>/dev/null \
      || echo "$ROOT/bazel-bin/core/controller/controller_asm")"
[ -x "$ASM" ] || { echo "ERROR: asm controller not found at $ASM" >&2; exit 1; }

# --- 3. Full valid env for -check-env --------------------------------------
ENVFILE="$ROOT/core/strimserver.env.example"
if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENVFILE"; set +a
else
  # No committed example: derive NAME="value" lines from the Go oracle's own
  # -print-env-example output (never hardcode the required-var list here).
  while IFS='=' read -r key val; do
    [ -n "$key" ] || continue
    val="${val#\"}"; val="${val%\"}"
    export "$key=$val"
  done < <("$GO" -print-env-example)
fi
# The example leaves the secrets empty by design (deploy-time injection);
# -check-env treats an empty Required var as missing, so fill them in.
export TWITCH_STREAM_KEY="${TWITCH_STREAM_KEY:-phase5-differential}"
export SRT_PUBLISH_PASSPHRASE="${SRT_PUBLISH_PASSPHRASE:-phase5-differential}"

# --- 4. Diff the three flag outputs byte-for-byte ---------------------------
rc=0

for flag in -print-env-example -print-ts-types; do
  "$GO" "$flag" > "$OUT/go.out"
  "$ASM" "$flag" > "$OUT/asm.out"
  if ! cmp -s "$OUT/go.out" "$OUT/asm.out"; then
    echo "FAIL: $flag differs" >&2
    diff -u "$OUT/go.out" "$OUT/asm.out" >&2 || true
    rc=1
  else
    echo "PASS: $flag"
  fi
done

# -check-env: compare stdout, stderr, AND the exit code under the valid env.
"$GO" -check-env > "$OUT/go.out" 2> "$OUT/go.err"; go_rc=$?
"$ASM" -check-env > "$OUT/asm.out" 2> "$OUT/asm.err"; asm_rc=$?
if [ "$go_rc" -ne "$asm_rc" ]; then
  echo "FAIL: -check-env exit codes differ (go=$go_rc asm=$asm_rc)" >&2
  rc=1
fi
if ! cmp -s "$OUT/go.out" "$OUT/asm.out" || ! cmp -s "$OUT/go.err" "$OUT/asm.err"; then
  echo "FAIL: -check-env output differs" >&2
  diff -u "$OUT/go.out" "$OUT/asm.out" >&2 || true
  diff -u "$OUT/go.err" "$OUT/asm.err" >&2 || true
  rc=1
fi
if [ "$rc" -eq 0 ]; then
  echo "PASS: -check-env (exit $go_rc, byte-identical)"
fi

if [ "$rc" -ne 0 ]; then
  echo "DIFFERENTIAL: RED" >&2
else
  echo "DIFFERENTIAL: GREEN (asm == Go byte-for-byte on all three flags)"
fi
exit "$rc"