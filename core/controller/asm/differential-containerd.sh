#!/usr/bin/env bash
#
# Phase 5 containerd-path differential: the x86-64 assembly controller's
# containerd OCI spec-fill/mount construction vs the Go controller (the
# oracle), byte-for-byte.
#
# This is the harness Workstream C built to close the coverage gap that let
# the ctr_fill_mounts scale-8-vs-byte-offset bug reach production.  The
# existing differential.sh only exercises the 3 flag paths (-print-env-example,
# -print-ts-types, -check-env); the ad-hoc run-path harness only exercises the
# HTTP surface.  Neither drives cc_ctr_oci_spec_fill -> ctr_fill_mounts, the
# path that builds a stage's OCI container spec records (bind mounts, args,
# env, cgroups path) from the Layout / per-kind descriptor tables.
#
# WHAT IT COMPARES (byte-for-byte, same field order/types as the asm dump):
#   kind, n_env + env[], n_args + args[], cwd, uid/gid/gids,
#   n_caps + caps[], host_network, cgroups path, n_mounts + per-mount
#   {destination, source, type, n_options, options[]}.
#
# HOW:
#   1. Builds the x86-64 driver (diffcontainerd/driver.c) that links the REAL
#      x86_64 cc_ctr.S + cc_util.S objects and calls cc_ctr_oci_spec_fill /
#      ctr_fill_mounts directly for each CTR_KIND_* stage.
#   2. Builds the Go oracle (diffcontainerd/oracle.go) that replicates
#      container_factory.go's construction for the same stages.
#   3. Runs both over the shared stage config (diffcontainerd/stages.conf)
#      and diffs the canonical record dumps byte-for-byte.
#
# The asm side runs under qemu-x86_64 -cpu max when --qemu is given (or the
# host is aarch64 and the driver is amd64); the Go oracle always runs
# natively.
#
# PREREQUISITES
#   * host `go` on PATH (builds the oracle),
#   * for the driver build: the hermetic clang x86-64 sysroot from
#     //tools/bazel:amd64_sysroot — resolved via `bazel info output_base`
#     (or --sysroot PATH), plus /usr/bin/clang + /usr/bin/ld.lld,
#   * qemu-x86_64 / qemu-x86_64-static on PATH when --qemu is used on a
#     non-x86_64 host.
#
# USAGE
#   core/controller/asm/differential-containerd.sh [--arch amd64] [--qemu]
#                                                 [--bin PATH] [--sysroot PATH]
#   --arch    amd64 only (the containerd driver is the x86-64 port).
#   --qemu    run the amd64 driver under qemu-x86_64 -cpu max (auto-on for
#             amd64 on a non-x86_64 host).
#   --bin PATH   use a pre-built driver binary at PATH instead of building.
#   --sysroot PATH  the amd64 sysroot (default: resolved via bazel).
#   --inject-scale8  ALSO build the driver against a scratch copy of cc_ctr.S
#             with the OLD scale-8 indexing (mov (%rax,%r11,8)) re-injected,
#             and run the differential on it — the RED demonstration proving
#             this harness catches the bug class.  The committed cc_ctr.S is
#             NEVER modified (A1 owns the fix; this copies to a temp dir).
#
# EXIT
#   0 = DIFFERENTIAL GREEN (asm == Go byte-for-byte on all stages)
#   1 = RED (a diff, a build failure, or a fill error)
#   2 = usage error
#
set -euo pipefail

ARCH="amd64"
QEMU=0
BIN=""
SYSROOT=""
INJECT_SCALE8=0

usage() {
  sed -n '2,79p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) [ $# -ge 2 ] || usage; ARCH="$2"; shift ;;
    --qemu) QEMU=1 ;;
    --bin) [ $# -ge 2 ] || usage; BIN="$2"; shift ;;
    --sysroot) [ $# -ge 2 ] || usage; SYSROOT="$2"; shift ;;
    --inject-scale8) INJECT_SCALE8=1 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) usage ;;
  esac
  shift
done

if [ "$ARCH" != amd64 ]; then
  echo "ERROR: --arch must be amd64 (the containerd differential drives the x86-64 port; arm64 has no driver yet)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/diffcontainerd.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

STAGES="$ROOT/core/controller/asm/diffcontainerd/stages.conf"
[ -f "$STAGES" ] || { echo "ERROR: missing stage config $STAGES" >&2; exit 1; }

# --- qemu runner (amd64 driver only; the oracle always runs natively) ------
HOST_ARCH="$(uname -m)"
QEMU_BIN=""
if [ "$QEMU" -eq 1 ] || { [ "$ARCH" = amd64 ] && [ "$HOST_ARCH" != x86_64 ]; }; then
  if command -v qemu-x86_64-static >/dev/null 2>&1; then
    QEMU_BIN="qemu-x86_64-static"
  elif command -v qemu-x86_64 >/dev/null 2>&1; then
    QEMU_BIN="qemu-x86_64"
  else
    echo "ERROR: amd64 driver needs qemu on this $HOST_ARCH host but neither qemu-x86_64-static nor qemu-x86_64 is on PATH" >&2
    exit 1
  fi
fi

run_asm() { # $1 = driver binary
  if [ -n "$QEMU_BIN" ]; then
    "$QEMU_BIN" -cpu max "$1" "$STAGES"
  else
    "$1" "$STAGES"
  fi
}

# --- 1. Go oracle (host toolchain, always native) --------------------------
# The oracle lives in its own oracle/ subdir (the diffcontainerd/ parent also
# holds driver.c; a mixed C+Go package would break `go build ./...`).
ORACLE="$OUT/oracle"
( cd "$ROOT/core/controller/asm/diffcontainerd/oracle" && go build -o "$ORACLE" oracle.go )
[ -x "$ORACLE" ] || { echo "ERROR: go build produced no oracle at $ORACLE" >&2; exit 1; }

# --- 2. Build the x86-64 driver -------------------------------------------
if [ -n "$BIN" ]; then
  DRIVER="$BIN"
  echo "note: --bin: using pre-built driver at $DRIVER (skipping build)"
  [ -x "$DRIVER" ] || { echo "ERROR: --bin path is not executable: $DRIVER" >&2; exit 1; }
else
  # Resolve the amd64 sysroot (the hermetic clang cross sysroot).
  if [ -z "$SYSROOT" ]; then
    OB="$(bazel info output_base 2>/dev/null || true)"
    if [ -n "$OB" ] && [ -d "$OB/execroot/_main/external/+amd64_sysroot+amd64_sysroot/sysroot" ]; then
      SYSROOT="$OB/execroot/_main/external/+amd64_sysroot+amd64_sysroot/sysroot"
    else
      # Fall back to a conventional bazel cache search.
      for cand in \
        "$ROOT/bazel-bin/../../../../external/+amd64_sysroot+amd64_sysroot/sysroot" \
        "$HOME/.cache/bazel/_bazel_${USER:-$(id -un)}"/*/execroot/_main/external/+amd64_sysroot+amd64_sysroot/sysroot \
        /var/lib/opencode/.cache/bazel/_bazel_opencode/*/execroot/_main/external/+amd64_sysroot+amd64_sysroot/sysroot \
        /home/*/.cache/bazel/_bazel_*/*/execroot/_main/external/+amd64_sysroot+amd64_sysroot/sysroot; do
        [ -d "$cand" ] && { SYSROOT="$cand"; break; }
      done
    fi
  fi
  if [ -z "$SYSROOT" ] || [ ! -d "$SYSROOT" ]; then
    echo "ERROR: cannot locate the amd64 sysroot; pass --sysroot PATH (see tools/bazel/toolchains/cc_toolchain_config.bzl)" >&2
    exit 1
  fi

  CLANG="${CLANG:-/usr/bin/clang}"
  LLD="${LLD:-/usr/bin/ld.lld}"
  [ -x "$CLANG" ] || { echo "ERROR: $CLANG not found" >&2; exit 1; }
  [ -x "$LLD" ] || { echo "ERROR: $LLD not found" >&2; exit 1; }

  ASM_INC="-I $ROOT/core/controller/asm -I $ROOT/core/controller/asm/x86_64"
  ISA="-march=x86-64-v4 -mno-avx512f -mno-avx512vl -mno-avx512bw -mno-avx512dq -mno-avx512cd"
  CROSS="--target=x86_64-linux-gnu -B/usr/bin -no-canonical-prefixes \
         -isystem $SYSROOT/include -isystem $SYSROOT/lib/gcc/x86_64-linux-gnu/14/include \
         --sysroot=$SYSROOT"

  # The REAL cc_ctr.S + cc_util.S (fixed tree objects; cc_util provides
  # cc_cat_cstr which ctr_build_cgroups/ctr_build_uri call).
  CTR_SRC="$ROOT/core/controller/asm/x86_64/cc_ctr.S"
  UTIL_SRC="$ROOT/core/controller/asm/x86_64/cc_util.S"

  build_driver() { # $1 = cc_ctr.S source, $2 = out driver path
    local ctr_src="$1" out_driver="$2"
    $CLANG -c -x assembler-with-cpp $CROSS $ISA $ASM_INC "$ctr_src" -o "$OUT/cc_ctr.o"
    $CLANG -c -x assembler-with-cpp $CROSS $ISA $ASM_INC "$UTIL_SRC" -o "$OUT/cc_util.o"
    $CLANG -c $CROSS $ISA -std=gnu11 -I "$ROOT/core/controller/asm/diffcontainerd" \
        -I "$ROOT/core/controller/c" \
        "$ROOT/core/controller/asm/diffcontainerd/driver.c" -o "$OUT/driver.o"
    $CLANG $CROSS -fuse-ld=lld --ld-path="$LLD" -no-canonical-prefixes \
        -L "$SYSROOT/lib" -L "$SYSROOT/lib/gcc/x86_64-linux-gnu/14" \
        -Wl,--build-id=md5 --rtlib=libgcc -static \
        -o "$out_driver" "$OUT/driver.o" "$OUT/cc_ctr.o" "$OUT/cc_util.o"
    [ -x "$out_driver" ] || { echo "ERROR: driver link produced no binary at $out_driver" >&2; exit 1; }
  }

  echo "building the containerd differential driver (cc_ctr.S + cc_util.S + driver.c)..."
  build_driver "$CTR_SRC" "$OUT/driver"

  if [ "$INJECT_SCALE8" -eq 1 ]; then
    # Scratch copy of cc_ctr.S with the OLD scale-8 indexing re-injected
    # (mov (%rax,%r11,8) instead of the fixed byte-offset mov (%rax,%r11)).
    # The committed cc_ctr.S is never touched.
    PATCHED="$OUT/cc_ctr_scale8.S"
    sed 's/mov (%rax,%r11), %r11/mov (%rax,%r11,8), %r11/' "$CTR_SRC" > "$PATCHED"
    grep -q 'mov (%rax,%r11,8), %r11' "$PATCHED" \
      || { echo "ERROR: scale-8 injection pattern not found in cc_ctr.S (the fix text changed?)" >&2; exit 1; }
    echo "note: --inject-scale8: building the OLD scale-8 driver (RED demonstration)"
    build_driver "$PATCHED" "$OUT/driver-scale8"
    SCALE8_DRIVER="$OUT/driver-scale8"
  fi
  DRIVER="$OUT/driver"
fi

# --- 3. Run both sides and diff byte-for-byte ------------------------------
rc=0

# Whole-run byte comparison (the authoritative check).  The driver dumps all
# four kinds in one run; the oracle likewise.  A divergence anywhere — a
# mount source, an option, an env/arg value, the cgroups path, the field
# ORDER — breaks the byte comparison.
run_asm "$DRIVER" > "$OUT/asm.all" || { echo "FAIL: asm driver exited non-zero" >&2; rc=1; }
"$ORACLE" "$STAGES" > "$OUT/go.all" || { echo "FAIL: oracle exited non-zero" >&2; rc=1; }

if cmp -s "$OUT/go.all" "$OUT/asm.all"; then
  echo "PASS: containerd mount/spec-fill records (asm == Go, byte-identical)"
else
  echo "FAIL: containerd mount/spec-fill records differ" >&2
  diff -u "$OUT/go.all" "$OUT/asm.all" >&2 || true
  rc=1
fi

# --- 4. --inject-scale8: prove the harness catches the bug class -----------
if [ "$INJECT_SCALE8" -eq 1 ]; then
  echo ""
  echo "--- scale-8 RED demonstration (scratch driver, committed cc_ctr.S untouched) ---"
  if [ -z "${SCALE8_DRIVER:-}" ]; then
    echo "note: --inject-scale8 with --bin: no scratch driver was built; skipping" >&2
  else
    if run_asm "$SCALE8_DRIVER" > "$OUT/asm.scale8"; then
      if cmp -s "$OUT/go.all" "$OUT/asm.scale8"; then
        echo "FAIL: scale-8 injection unexpectedly matched the oracle (harness blind to the bug class)" >&2
        rc=1
      else
        echo "PASS: scale-8 injection detected — the OLD logic diverges from Go, as expected (RED demonstration)"
        diff -u "$OUT/go.all" "$OUT/asm.scale8" | sed -n '1,25p' >&2 || true
      fi
    else
      echo "PASS: scale-8 injection driver crashed/exited non-zero — the bug class is caught loudly" >&2
    fi
  fi
fi

if [ "$rc" -ne 0 ]; then
  echo "DIFFERENTIAL: RED" >&2
else
  echo "DIFFERENTIAL: GREEN (asm == Go byte-for-byte on the containerd mount/spec-fill path)"
fi
exit "$rc"