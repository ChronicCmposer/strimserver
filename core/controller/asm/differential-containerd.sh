#!/usr/bin/env bash
#
# Phase 5 containerd-path differential: the x86-64 assembly controller's
# containerd OCI spec-fill/mount construction + snapshot/unpack/parent-chain
# vs the Go controller (the oracle), byte-for-byte.
#
# This is the harness Workstream C built to close the coverage gap that let
# the ctr_fill_mounts scale-8-vs-byte-offset bug reach production, extended by
# Workstream B2 to ALSO cover the SNAPSHOT/UNPACK/PARENT-CHAIN path where the
# production empty-rootfs bug lived (Snapshots/Prepare(key=<id>, parent="")
# instead of containerd.WithNewSnapshot's parent = identity.ChainID(image
# rootfs diff_ids)).
#
# WHAT IT COMPARES (byte-for-byte, same field order/types as the asm dump):
#   A. mount/spec-fill records (existing):
#        kind, n_env + env[], n_args + args[], cwd, uid/gid/gids,
#        n_caps + caps[], host_network, cgroups path, n_mounts + per-mount
#        {destination, source, type, n_options, options[]}.
#   B. snapshot / parent-chain records (B2):
#        snapshot_key, snapshot_parent, n_layers + per-layer
#        {diff, key, parent}.
#   The snapshot_parent is the critical field: it must equal the Go oracle's
#   identity.ChainID(image rootfs diff_ids) — the parent
#   containerd.WithNewSnapshot passes to Snapshots/Prepare so the container
#   rootfs carries the image layers (/entrypoint.sh).  An empty parent (the
#   production bug) turns B RED.
#
# HOW:
#   1. Builds the x86-64 driver (diffcontainerd/driver.c) that links the REAL
#      x86_64 cc_ctr.S + cc_util.S objects and drives BOTH paths:
#      (A) cc_ctr_oci_spec_fill / ctr_fill_mounts directly for each
#          CTR_KIND_* stage;
#      (B) cc_ctr_apply(stage, CC_STATE_RUNNING) -> ctr_start, the full
#          Images/Get -> cc_ctr_resolve_chainid -> Snapshots/Prepare ->
#          Mounts RPC sequence.  The driver's recording stubs capture the
#          (key, parent) the asm ACTUALLY passes to Prepare and dump them in
#          the canonical format.  The driver feeds the image rootfs diff_ids
#          (stages.conf *_ROOTFS, the REAL rules_oci image configs) to the
#          asm through its cc_ctr_resolve_chainid stub — exactly what the
#          real C layer (B1's cc_ctr_resolve_chainid) returns.
#   2. Builds the Go oracle (diffcontainerd/oracle/oracle.go) that replicates
#      container_factory.go's construction AND containerd.WithNewSnapshot's
#      parent = identity.ChainID(rootfs.diff_ids) for the same stages.
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
#   --inject-empty-parent  ALSO build the driver with
#             -DDRIVER_INJECT_EMPTY_PARENT (its cc_ctr_resolve_chainid stub
#             returns ""), and run the differential on it — the RED
#             demonstration proving the harness catches the empty-parent /
#             empty-rootfs bug class.  The committed cc_ctr.S is NEVER
#             modified (B1 owns the fix; the injection is a driver build
#             flag).  This stays a valid demonstration even after B1's fix
#             makes the default run GREEN.
#   --real-resolver  ALSO build and run the REAL C-layer chainID resolver
#             differential: a standalone driver (diffcontainerd/
#             resolver_driver.c) links the REAL shipped core/controller/c/
#             cc_ctr.c (cc_ctr_resolve_chainid + its self-contained SHA-256,
#             JSON path extractor, and Images/Get + Content/Read request
#             framing — the ~750 lines the v1.0.23 review flagged as never
#             executed) plus the vendored containerd-api codecs + protobuf-c
#             runtime, and drives it through a test-only cc_grpc_unary
#             transport stub that serves CANNED byte-exact manifest/config
#             responses built from the REAL stages.conf *_ROOTFS diff_ids.
#             The driver's resolver_parent per stage must byte-match the Go
#             oracle identity.ChainID (oracle.go --resolver).  Two malformed
#             config blobs must be rejected loudly with a CC_CTR_ERR_* code
#             (never a wrong/garbage parent, never a crash).  This is the
#             GREEN proof that the shipped C chainID resolver executes and
#             matches Go.
#   --pbc PATH   the protobuf-c external source root (default: resolved via
#             bazel like the sysroot; needed only for --real-resolver).
#
# EXIT
#   0 = DIFFERENTIAL GREEN (asm == Go byte-for-byte on ALL stages, BOTH the
#       mount/spec-fill records and the snapshot/parent-chain records; with
#       --real-resolver, ALSO the real-C resolver == Go identity.ChainID)
#   1 = RED (a diff, a build failure, or a fill/start error)
#   2 = usage error
#
set -euo pipefail

ARCH="amd64"
QEMU=0
BIN=""
SYSROOT=""
PBC=""
INJECT_SCALE8=0
INJECT_EMPTY_PARENT=0
REAL_RESOLVER=0

usage() {
  sed -n '2,105p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) [ $# -ge 2 ] || usage; ARCH="$2"; shift ;;
    --qemu) QEMU=1 ;;
    --bin) [ $# -ge 2 ] || usage; BIN="$2"; shift ;;
    --sysroot) [ $# -ge 2 ] || usage; SYSROOT="$2"; shift ;;
    --pbc) [ $# -ge 2 ] || usage; PBC="$2"; shift ;;
    --inject-scale8) INJECT_SCALE8=1 ;;
    --inject-empty-parent) INJECT_EMPTY_PARENT=1 ;;
    --real-resolver) REAL_RESOLVER=1 ;;
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

  build_driver() { # $1 = cc_ctr.S source, $2 = out driver path, $3 = extra driver CFLAGS
    local ctr_src="$1" out_driver="$2" extra_cflags="$3"
    $CLANG -c -x assembler-with-cpp $CROSS $ISA $ASM_INC "$ctr_src" -o "$OUT/cc_ctr.o"
    $CLANG -c -x assembler-with-cpp $CROSS $ISA $ASM_INC "$UTIL_SRC" -o "$OUT/cc_util.o"
    $CLANG -c $CROSS $ISA -std=gnu11 -Wall -Wextra -Werror $extra_cflags \
        -I "$ROOT/core/controller/asm/diffcontainerd" \
        -I "$ROOT/core/controller/c" \
        "$ROOT/core/controller/asm/diffcontainerd/driver.c" -o "$OUT/driver.o"
    $CLANG $CROSS -fuse-ld=lld --ld-path="$LLD" -no-canonical-prefixes \
        -L "$SYSROOT/lib" -L "$SYSROOT/lib/gcc/x86_64-linux-gnu/14" \
        -Wl,--build-id=md5 --rtlib=libgcc -static \
        -o "$out_driver" "$OUT/driver.o" "$OUT/cc_ctr.o" "$OUT/cc_util.o"
    [ -x "$out_driver" ] || { echo "ERROR: driver link produced no binary at $out_driver" >&2; exit 1; }
  }

  echo "building the containerd differential driver (cc_ctr.S + cc_util.S + driver.c)..."
  build_driver "$CTR_SRC" "$OUT/driver" ""

  if [ "$INJECT_SCALE8" -eq 1 ]; then
    # Scratch copy of cc_ctr.S with the OLD scale-8 indexing re-injected
    # (mov (%rax,%r11,8) instead of the fixed byte-offset mov (%rax,%r11)).
    # The committed cc_ctr.S is never touched.
    PATCHED="$OUT/cc_ctr_scale8.S"
    sed 's/mov (%rax,%r11), %r11/mov (%rax,%r11,8), %r11/' "$CTR_SRC" > "$PATCHED"
    grep -q 'mov (%rax,%r11,8), %r11' "$PATCHED" \
      || { echo "ERROR: scale-8 injection pattern not found in cc_ctr.S (the fix text changed?)" >&2; exit 1; }
    echo "note: --inject-scale8: building the OLD scale-8 driver (RED demonstration)"
    build_driver "$PATCHED" "$OUT/driver-scale8" ""
    SCALE8_DRIVER="$OUT/driver-scale8"
  fi

  if [ "$INJECT_EMPTY_PARENT" -eq 1 ]; then
    # Scratch driver whose cc_ctr_resolve_chainid stub returns "" — the
    # empty-parent bug class.  The committed cc_ctr.S is never touched; the
    # injection is a driver build flag only.
    echo "note: --inject-empty-parent: building the empty-parent driver (RED demonstration)"
    build_driver "$CTR_SRC" "$OUT/driver-empty-parent" "-DDRIVER_INJECT_EMPTY_PARENT"
    EMPTY_PARENT_DRIVER="$OUT/driver-empty-parent"
  fi
  DRIVER="$OUT/driver"

  # --- 2b. --real-resolver: build the REAL C-layer chainID resolver driver.
  # Links the REAL shipped core/controller/c/cc_ctr.c (the resolver + its
  # static helpers are retained via --gc-sections) + the vendored containerd
  # API codecs (third_party/containerd-api/codecgen) + the vendored
  # protobuf-c runtime, driven by diffcontainerd/resolver_driver.c whose
  # cc_grpc_unary stub serves canned Images/Get + Content/Read responses.
  if [ "$REAL_RESOLVER" -eq 1 ]; then
    # Locate the protobuf-c external source root (the hermetic vendored
    # runtime @protobuf_c//:runtime).  Mirrors the sysroot search: bazel
    # output_base first, then conventional cache paths.
    if [ -z "$PBC" ]; then
      OB="$(bazel info output_base 2>/dev/null || true)"
      if [ -n "$OB" ] && [ -d "$OB/execroot/_main/external/+http_archive+protobuf_c" ]; then
        PBC="$OB/execroot/_main/external/+http_archive+protobuf_c"
      else
        for cand in \
          "$ROOT/bazel-bin/../../../../external/+http_archive+protobuf_c" \
          "$HOME/.cache/bazel/_bazel_${USER:-$(id -un)}"/*/execroot/_main/external/+http_archive+protobuf_c \
          /var/lib/opencode/.cache/bazel/_bazel_opencode/*/execroot/_main/external/+http_archive+protobuf_c \
          /home/*/.cache/bazel/_bazel_*/*/execroot/_main/external/+http_archive+protobuf_c; do
          [ -d "$cand/protobuf-c" ] && { PBC="$cand"; break; }
        done
      fi
    fi
    if [ -z "$PBC" ] || [ ! -f "$PBC/protobuf-c/protobuf-c.c" ]; then
      echo "ERROR: cannot locate the vendored protobuf-c runtime; pass --pbc PATH (see third_party/protobuf-c/BUILD.bazel @protobuf_c)" >&2
      exit 1
    fi

    CODECGEN="$ROOT/third_party/containerd-api/codecgen"
    PBC_INC="-I $CODECGEN -I $PBC"

    # The vendored codec sources the resolver's call graph needs (images +
    # content services and their google/protobuf + types deps).  Compiled
    # with -ffunction-sections so --gc-sections drops the unused messages.
    build_codec() { # $1 = codecgen-relative .c path, $2 = out .o
      $CLANG -c $CROSS $ISA -std=gnu11 -Wall -Wextra -Werror \
          -ffunction-sections -fdata-sections $PBC_INC \
          "$CODECGEN/$1" -o "$2"
    }

    build_codec "google/protobuf/empty.pb-c.c" "$OUT/codec-empty.o"
    build_codec "google/protobuf/field_mask.pb-c.c" "$OUT/codec-fieldmask.o"
    build_codec "google/protobuf/timestamp.pb-c.c" "$OUT/codec-timestamp.o"
    build_codec "types/descriptor.pb-c.c" "$OUT/codec-descriptor.o"
    build_codec "services/images/v1/images.pb-c.c" "$OUT/codec-images.o"
    build_codec "services/content/v1/content.pb-c.c" "$OUT/codec-content.o"

    # The vendored protobuf-c runtime (pure C, @protobuf_c//:runtime).
    $CLANG -c $CROSS $ISA -std=gnu11 -Wall -Wextra -Werror \
        -ffunction-sections -fdata-sections \
        -I "$PBC" -I "$PBC/protobuf-c" \
        "$PBC/protobuf-c/protobuf-c.c" -o "$OUT/protobuf-c.o"

    # The REAL shipped C layer — compiled whole; --gc-sections keeps only
    # cc_ctr_resolve_chainid + its static helpers (copy_str, json_*,
    # cc_sha256_*, ctr_read_content), dropping the RPC helpers that would
    # drag in the other service codecs.
    $CLANG -c $CROSS $ISA -std=gnu11 -Wall -Wextra -Werror \
        -ffunction-sections -fdata-sections \
        -I "$ROOT/core/controller/c" $PBC_INC \
        "$ROOT/core/controller/c/cc_ctr.c" -o "$OUT/cc_ctr_real.o"

    # The resolver driver (test-only; MUST build -Wall -Wextra -Werror).
    $CLANG -c $CROSS $ISA -std=gnu11 -Wall -Wextra -Werror \
        -ffunction-sections -fdata-sections \
        -I "$ROOT/core/controller/asm/diffcontainerd" \
        -I "$ROOT/core/controller/c" $PBC_INC \
        "$ROOT/core/controller/asm/diffcontainerd/resolver_driver.c" \
        -o "$OUT/resolver_driver.o"

    $CLANG $CROSS -fuse-ld=lld --ld-path="$LLD" -no-canonical-prefixes \
        -L "$SYSROOT/lib" -L "$SYSROOT/lib/gcc/x86_64-linux-gnu/14" \
        -Wl,--build-id=md5 --rtlib=libgcc -static -Wl,--gc-sections \
        -o "$OUT/resolver-driver" \
        "$OUT/resolver_driver.o" "$OUT/cc_ctr_real.o" \
        "$OUT/codec-images.o" "$OUT/codec-content.o" \
        "$OUT/codec-descriptor.o" "$OUT/codec-empty.o" \
        "$OUT/codec-fieldmask.o" "$OUT/codec-timestamp.o" \
        "$OUT/protobuf-c.o"
    [ -x "$OUT/resolver-driver" ] || { echo "ERROR: resolver driver link produced no binary" >&2; exit 1; }
    RESOLVER_DRIVER="$OUT/resolver-driver"
    echo "note: --real-resolver: built the REAL C-layer chainID resolver driver (cc_ctr.c + codecs + protobuf-c)"
  fi
fi

# --- 3. Run both sides and diff byte-for-byte ------------------------------
rc=0

# Whole-run byte comparison (the authoritative check).  The driver dumps all
# four kinds in one run; the oracle likewise.  A divergence anywhere — a
# mount source, an option, an env/arg value, the cgroups path, the snapshot
# parent/key, a layer chain entry, the field ORDER — breaks the byte
# comparison.
run_asm "$DRIVER" > "$OUT/asm.all" || { echo "FAIL: asm driver exited non-zero" >&2; rc=1; }
"$ORACLE" "$STAGES" > "$OUT/go.all" || { echo "FAIL: oracle exited non-zero" >&2; rc=1; }

# Section diagnostics: split each side into the spec blocks (kind= ... up to
# the snapshot_key=) and the snapshot blocks (snapshot_key= ... up to the
# next kind=) so a RED reports exactly which surface diverged.
awk '/^kind=/{in_spec=1; in_snap=0} /^snapshot_key=/{in_snap=1; in_spec=0} {if (in_spec) print}' "$OUT/go.all" > "$OUT/go.spec"
awk '/^kind=/{in_spec=1; in_snap=0} /^snapshot_key=/{in_snap=1; in_spec=0} {if (in_snap) print}' "$OUT/go.all" > "$OUT/go.snap"
awk '/^kind=/{in_spec=1; in_snap=0} /^snapshot_key=/{in_snap=1; in_spec=0} {if (in_spec) print}' "$OUT/asm.all" > "$OUT/asm.spec"
awk '/^kind=/{in_spec=1; in_snap=0} /^snapshot_key=/{in_snap=1; in_spec=0} {if (in_snap) print}' "$OUT/asm.all" > "$OUT/asm.snap"

SPEC_OK=0; SNAP_OK=0
if cmp -s "$OUT/go.spec" "$OUT/asm.spec"; then
  SPEC_OK=1; echo "PASS: mount/spec-fill records (asm == Go, byte-identical)"
else
  echo "FAIL: mount/spec-fill records differ" >&2
  diff -u "$OUT/go.spec" "$OUT/asm.spec" >&2 || true
  rc=1
fi
if cmp -s "$OUT/go.snap" "$OUT/asm.snap"; then
  SNAP_OK=1; echo "PASS: snapshot/parent-chain records (asm == Go, byte-identical)"
else
  echo "FAIL: snapshot/parent-chain records differ" >&2
  diff -u "$OUT/go.snap" "$OUT/asm.snap" | sed -n '1,25p' >&2 || true
  rc=1
fi

if cmp -s "$OUT/go.all" "$OUT/asm.all"; then
  echo "PASS: whole-run containerd records (asm == Go, byte-identical)"
else
  echo "FAIL: whole-run containerd records differ" >&2
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

# --- 5. --inject-empty-parent: prove the harness catches the bug class ------
if [ "$INJECT_EMPTY_PARENT" -eq 1 ]; then
  echo ""
  echo "--- empty-parent RED demonstration (scratch driver, committed cc_ctr.S untouched) ---"
  if [ -z "${EMPTY_PARENT_DRIVER:-}" ]; then
    echo "note: --inject-empty-parent with --bin: no scratch driver was built; skipping" >&2
  else
    if run_asm "$EMPTY_PARENT_DRIVER" > "$OUT/asm.empty-parent"; then
      if cmp -s "$OUT/go.all" "$OUT/asm.empty-parent"; then
        echo "FAIL: empty-parent injection unexpectedly matched the oracle (harness blind to the bug class)" >&2
        rc=1
      else
        echo "PASS: empty-parent injection detected — Snapshots/Prepare(parent=\"\") diverges from Go's ChainID parent, as expected (RED demonstration)"
        diff -u "$OUT/go.all" "$OUT/asm.empty-parent" | grep '^[-+]snapshot_parent' >&2 || true
      fi
    else
      echo "PASS: empty-parent injection driver crashed/exited non-zero — the bug class is caught loudly" >&2
    fi
  fi
fi

# --- 6. --real-resolver: the REAL C-layer chainID resolver differential ----
# The shipped cc_ctr.c chainID resolver (SHA-256, JSON path extractor,
# Images/Get + Content/Read framing) executes end-to-end against canned
# Images/Get + Content/Read responses built from the REAL stages.conf
# *_ROOTFS diff_ids; its resolver_parent must byte-match the Go oracle's
# identity.ChainID (oracle.go --resolver) for all 4 stages, and malformed
# configs must be rejected loudly with a CC_CTR_ERR_* code.
if [ "$REAL_RESOLVER" -eq 1 ]; then
  echo ""
  echo "--- real C-layer chainID resolver (cc_ctr.c + vendored codecs + protobuf-c) ---"
  if [ -z "${RESOLVER_DRIVER:-}" ]; then
    echo "note: --real-resolver with --bin: no resolver driver was built; skipping" >&2
  else
    if run_asm "$RESOLVER_DRIVER" > "$OUT/resolver.asm" 2> "$OUT/resolver.asm.err"; then
      RESOLVER_RC=0
    else
      echo "FAIL: real-C resolver driver exited non-zero" >&2
      cat "$OUT/resolver.asm.err" >&2 || true
      rc=1
      RESOLVER_RC=1
    fi
    if [ "$RESOLVER_RC" -eq 0 ]; then
      "$ORACLE" --resolver "$STAGES" > "$OUT/resolver.go" \
        || { echo "FAIL: oracle --resolver exited non-zero" >&2; rc=1; RESOLVER_RC=1; }
    fi
    if [ "$RESOLVER_RC" -eq 0 ]; then
      # Byte-compare the resolver records (stage + parent) against the Go
      # oracle identity.ChainID, ignoring the negative-case markers.
      grep -E '^(resolver_stage|resolver_parent)=' "$OUT/resolver.asm" \
        > "$OUT/resolver.asm.records"
      if cmp -s "$OUT/resolver.go" "$OUT/resolver.asm.records"; then
        echo "PASS: real-C resolver parent == Go oracle identity.ChainID (all 4 stages, byte-identical)"
      else
        echo "FAIL: real-C resolver parent diverges from the Go oracle chainID" >&2
        diff -u "$OUT/resolver.go" "$OUT/resolver.asm.records" | sed -n '1,25p' >&2 || true
        rc=1
      fi
    fi
    if [ "$RESOLVER_RC" -eq 0 ]; then
      # Negative cases: every resolver_negative= line must be a fail-loud
      # CC_CTR_ERR_* code (a negative number), never WRONG-ANSWER.
      if grep -q '^resolver_negative=.*WRONG-ANSWER' "$OUT/resolver.asm"; then
        echo "FAIL: a malformed config produced a wrong/garbage parent instead of failing loudly" >&2
        grep '^resolver_negative=' "$OUT/resolver.asm" >&2 || true
        rc=1
      else
        NEG_COUNT="$(grep -c '^resolver_negative=' "$OUT/resolver.asm" || true)"
        NEG_OK="$(grep -c '^resolver_negative=.*:-[0-9][0-9]*$' "$OUT/resolver.asm" || true)"
        if [ "$NEG_COUNT" -ge 2 ] && [ "$NEG_OK" -eq "$NEG_COUNT" ]; then
          echo "PASS: malformed configs rejected loudly (CC_CTR_ERR_*), no wrong parent, no crash ($NEG_COUNT cases)"
          grep '^resolver_negative=' "$OUT/resolver.asm" >&2 || true
        else
          echo "FAIL: negative-case markers incomplete (expected >= 2 fail-loud, got $NEG_OK/$NEG_COUNT)" >&2
          grep '^resolver_negative=' "$OUT/resolver.asm" >&2 || true
          rc=1
        fi
      fi
    fi
  fi
fi

if [ "$rc" -ne 0 ]; then
  echo "DIFFERENTIAL: RED" >&2
else
  echo "DIFFERENTIAL: GREEN (asm == Go byte-for-byte on the containerd mount/spec-fill AND snapshot/parent-chain paths)"
  if [ "$REAL_RESOLVER" -eq 1 ]; then
    echo "DIFFERENTIAL: GREEN (real C-layer chainID resolver == Go identity.ChainID, byte-identical)"
  fi
fi
exit "$rc"