#!/usr/bin/env bash
#
# Phase 5 end-to-end differential: the assembly controller vs the Go
# controller (the oracle), byte-for-byte across the three codegen/check flags.
# Generalized for BOTH asm ports: arm64 (AArch64, native) and amd64 (x86-64,
# native or under qemu-x86_64).
#
# PREREQUISITES
#   * a host `go` toolchain on PATH: the Go oracle is built with the HOST
#     toolchain because the pinned Bazel go_binary (strimserver-controller)
#     is hardcoded goarch=amd64 and cannot run on an aarch64 host (and the
#     host oracle must run natively in every mode);
#   * `bazel` on PATH (used to build the selected asm target for the selected
#     --platforms target) unless --bin PATH is given;
#   * for --arch amd64 on a non-x86_64 host, --qemu requires
#     qemu-x86_64-static (or qemu-x86_64) on PATH.
#
# WHAT IT DOES
#   1. Builds the Go oracle with the host `go`:  go build ./core/controller
#   2. Builds the asm controller:               bazel build <target> --platforms=<platform>
#   3. Diffs the three flag outputs byte-for-byte, under a full valid env:
#        -print-env-example, -print-ts-types, -check-env
#      (the valid env comes from the repo's core/strimserver.env.example when
#      present -- the harness sources it and fills the deliberately-empty
#      secrets -- else it derives one from the Go oracle's own
#      -print-env-example output).
#   Exits non-zero on ANY diff (or on a -check-env exit-code mismatch).
#
# ARCHITECTURE SELECTION
#   --arch arm64|amd64  (default: inferred from uname -m: aarch64 -> arm64,
#                        x86_64 -> amd64)
#       arm64: target //core/controller/alternate/asm:controller_asm,
#              --platforms=//tools/bazel:linux_arm64 (the AArch64 port)
#       amd64: target //core/controller/alternate/asm:controller_asm_x86_64,
#              --platforms=//tools/bazel:linux_amd64 (the x86-64 port; the
#              target may still be provided by another agent -- the script
#              resolves it via cquery and fails with a clear message if the
#              bazel build cannot find it yet)
#   --qemu   run the amd64 asm binary under `qemu-x86_64-static -cpu max`
#            instead of directly; the Go oracle still runs natively.  Only
#            valid with --arch amd64 (qemu-x86_64 executes amd64 binaries).
#   --bin PATH  use a pre-built asm binary at PATH instead of a bazel build.
#   --4way   additionally diff the arm64 vs amd64 asm outputs directly, once
#            both exist.  Each --4way run persists the current arch's asm
#            outputs under $DIFFERENTIAL_OUT/<arch> (default
#            bazel-bin/controller-differential); when the OTHER arch's
#            persisted outputs are present they are compared pairwise
#            (byte-for-byte on stdout, and stdout+stderr+exit code for
#            -check-env).
#
# This is the Phase 5 END-TO-END differential: the per-module differentials
# (Phases 4.1-4.7) already proved each asm function against the Go
# reference; this harness proves the assembled whole. It is deliberately NOT
# wired as a Bazel test -- Bazel tests cannot assume a host `go` toolchain --
# so it is a committed dev harness, run by hand (or by a CI gate).
#
# USAGE
#   core/controller/alternate/asm/differential.sh [--arch arm64|amd64] [--qemu]
#                                       [--bin PATH] [--4way]
# EXIT
#   0 = GREEN (asm == Go byte-for-byte on all three flags)
#   1 = RED   (a diff or a build failure)
#   2 = usage error
#
set -euo pipefail

ARCH=""
QEMU=0
BIN=""
FOURWAY=0

usage() {
  sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# --- argument parsing ---------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) [ $# -ge 2 ] || usage; ARCH="$2"; shift ;;
    --qemu) QEMU=1 ;;
    --bin) [ $# -ge 2 ] || usage; BIN="$2"; shift ;;
    --4way) FOURWAY=1 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) usage ;;
  esac
  shift
done

# --- arch selection ----------------------------------------------------------
if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    aarch64|arm64) ARCH=arm64 ;;
    x86_64|amd64) ARCH=amd64 ;;
    *)
      echo "ERROR: cannot infer arch from uname -m '$(uname -m)'; pass --arch arm64|amd64" >&2
      exit 2
      ;;
  esac
fi
case "$ARCH" in
  arm64)
    TARGET="//core/controller/alternate/asm:controller_asm"
    TARGET_NAME="controller_asm"
    PLATFORM="//tools/bazel:linux_arm64"
    ;;
  amd64)
    TARGET="//core/controller/alternate/asm:controller_asm_x86_64"
    TARGET_NAME="controller_asm_x86_64"
    PLATFORM="//tools/bazel:linux_amd64"
    ;;
  *)
    echo "ERROR: --arch must be arm64 or amd64 (got '$ARCH')" >&2
    exit 2
    ;;
esac
if [ "$QEMU" -eq 1 ] && [ "$ARCH" != amd64 ]; then
  echo "ERROR: --qemu runs the amd64 binary under qemu-x86_64; it cannot be used with --arch $ARCH" >&2
  exit 2
fi

# --- repo root / scratch -----------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/differential.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

# --- 1. Go oracle, built with the HOST go toolchain -------------------------
# The module root is core/controller (that is where go.mod lives); build from
# inside it so the module cache and go.sum resolve exactly as the repo pins.
GO="$OUT/go-controller"
( cd "$ROOT/core/controller" && go build -o "$GO" . )
[ -x "$GO" ] || { echo "ERROR: go build produced no oracle at $GO" >&2; exit 1; }

# --- 2. The asm controller ---------------------------------------------------
if [ -n "$BIN" ]; then
  ASM="$BIN"
  echo "note: --bin: using pre-built asm binary at $ASM (skipping bazel build)"
  [ -x "$ASM" ] || { echo "ERROR: --bin path is not executable: $ASM" >&2; exit 1; }
else
  echo "building $TARGET for $ARCH ($PLATFORM)..."
  if ! bazel build "$TARGET" --platforms="$PLATFORM" >/dev/null; then
    echo "ERROR: bazel build of $TARGET failed (--arch $ARCH, --platforms=$PLATFORM); the target may not be wired yet (another agent may still be providing it) or the C++ toolchain for this platform is unavailable on this host" >&2
    exit 1
  fi
  # Resolve the built file via cquery; fall back to the conventional
  # bazel-bin path (same pattern the aarch64-only script used).
  ASM="$(bazel cquery --output=files "$TARGET" --platforms="$PLATFORM" 2>/dev/null \
        || echo "$ROOT/bazel-bin/core/controller/alternate/asm/$TARGET_NAME")"
  [ -x "$ASM" ] || { echo "ERROR: asm controller not found at $ASM" >&2; exit 1; }
fi

# --- qemu runner (amd64 asm only; the oracle always runs natively) ----------
QEMU_BIN=""
if [ "$QEMU" -eq 1 ]; then
  if command -v qemu-x86_64-static >/dev/null 2>&1; then
    QEMU_BIN="qemu-x86_64-static"
  elif command -v qemu-x86_64 >/dev/null 2>&1; then
    QEMU_BIN="qemu-x86_64"
  else
    echo "ERROR: --qemu requested but neither qemu-x86_64-static nor qemu-x86_64 is on PATH" >&2
    exit 1
  fi
fi

run_asm() { # flag
  if [ -n "$QEMU_BIN" ]; then
    "$QEMU_BIN" -cpu max "$ASM" "$1"
  else
    "$ASM" "$1"
  fi
}

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

flag_name() {
  case "$1" in
    -print-env-example) echo env-example ;;
    -print-ts-types) echo ts-types ;;
    -check-env) echo check-env ;;
  esac
}

for flag in -print-env-example -print-ts-types; do
  name="$(flag_name "$flag")"
  "$GO" "$flag" > "$OUT/go.$name.out"
  run_asm "$flag" > "$OUT/asm.$name.out"
  if ! cmp -s "$OUT/go.$name.out" "$OUT/asm.$name.out"; then
    echo "FAIL: $flag differs" >&2
    diff -u "$OUT/go.$name.out" "$OUT/asm.$name.out" >&2 || true
    rc=1
  else
    echo "PASS: $flag"
  fi
done

# -check-env: compare stdout, stderr, AND the exit code under the valid env.
"$GO" -check-env > "$OUT/go.check-env.out" 2> "$OUT/go.check-env.err"; go_rc=$?
run_asm -check-env > "$OUT/asm.check-env.out" 2> "$OUT/asm.check-env.err"; asm_rc=$?
echo "$asm_rc" > "$OUT/asm.check-env.rc"
if [ "$go_rc" -ne "$asm_rc" ]; then
  echo "FAIL: -check-env exit codes differ (go=$go_rc asm=$asm_rc)" >&2
  rc=1
fi
if ! cmp -s "$OUT/go.check-env.out" "$OUT/asm.check-env.out" \
  || ! cmp -s "$OUT/go.check-env.err" "$OUT/asm.check-env.err"; then
  echo "FAIL: -check-env output differs" >&2
  diff -u "$OUT/go.check-env.out" "$OUT/asm.check-env.out" >&2 || true
  diff -u "$OUT/go.check-env.err" "$OUT/asm.check-env.err" >&2 || true
  rc=1
fi
if [ "$rc" -eq 0 ]; then
  echo "PASS: -check-env (exit $go_rc, byte-identical)"
fi

# --- 5. --4way: persist this arch's asm outputs; diff both arches directly --
if [ "$FOURWAY" -eq 1 ]; then
  OUTDIR="${DIFFERENTIAL_OUT:-$ROOT/bazel-bin/controller-differential}"
  self_dir="$OUTDIR/$ARCH"
  mkdir -p "$self_dir"
  cp "$OUT/asm.env-example.out" "$self_dir/env-example.out"
  cp "$OUT/asm.ts-types.out" "$self_dir/ts-types.out"
  cp "$OUT/asm.check-env.out" "$self_dir/check-env.out"
  cp "$OUT/asm.check-env.err" "$self_dir/check-env.err"
  cp "$OUT/asm.check-env.rc" "$self_dir/check-env.rc"

  if [ "$ARCH" = arm64 ]; then other=amd64; else other=arm64; fi
  other_dir="$OUTDIR/$other"
  if [ ! -d "$other_dir" ]; then
    echo "note: --4way: $other asm outputs not present at $other_dir (run with --arch $other --4way first); skipping the arm64-vs-amd64 direct diff"
  else
    wrc=0
    for f in env-example ts-types; do
      if cmp -s "$other_dir/$f.out" "$self_dir/$f.out"; then
        echo "4WAY PASS: $f (asm $other == asm $ARCH)"
      else
        echo "4WAY FAIL: $f differs ($other vs $ARCH)" >&2
        diff -u "$other_dir/$f.out" "$self_dir/$f.out" >&2 || true
        wrc=1
      fi
    done
    o_rc="$(cat "$other_dir/check-env.rc" 2>/dev/null || echo '?')"
    s_rc="$(cat "$self_dir/check-env.rc")"
    if cmp -s "$other_dir/check-env.out" "$self_dir/check-env.out" \
      && cmp -s "$other_dir/check-env.err" "$self_dir/check-env.err" \
      && [ "$o_rc" = "$s_rc" ]; then
      echo "4WAY PASS: -check-env (exit $s_rc, byte-identical)"
    else
      echo "4WAY FAIL: -check-env differs ($other vs $ARCH)" >&2
      diff -u "$other_dir/check-env.out" "$self_dir/check-env.out" >&2 || true
      diff -u "$other_dir/check-env.err" "$self_dir/check-env.err" >&2 || true
      wrc=1
    fi
    if [ "$wrc" -eq 0 ]; then
      echo "4WAY: GREEN (asm $ARCH == asm $other byte-for-byte)"
    else
      echo "4WAY: RED" >&2
    fi
    [ "$wrc" -eq 0 ] || rc=1
  fi
fi

if [ "$rc" -ne 0 ]; then
  echo "DIFFERENTIAL: RED" >&2
else
  echo "DIFFERENTIAL: GREEN (asm == Go byte-for-byte on all three flags)"
fi
exit "$rc"