#!/usr/bin/env bash
# =============================================================================
# tools/ffmpeg-dist/build-qemu.sh -- build the buildkit-direct-execve patched
# qemu-x86_64 from source and install it into the local cache.
#
# Upstream qemu-user cannot intercept a guest's execve() (it ENOEXECs the first
# guest child), so the amd64 guest build on a non-x86_64 host needs a qemu
# carrying the tonistiigi/binfmt "buildkit-direct-execve" patch series
# (tools/ffmpeg-dist/qemu-patches/, pinned to qemu $QEMU_VERSION). This script
# downloads, verifies, patches, and compiles that qemu -- no docker, no
# buildctl, no prebuilt binary (none exists anywhere), no system installs.
#
# Idempotent: if $QEMU_CACHE already holds a verified patched qemu, the script
# short-circuits and exits 0. Otherwise it builds from source and installs to
# $QEMU_CACHE.
#
# Host build deps (checked, never installed): meson, ninja, python3,
# pkg-config, gcc, and pkg-config glib-2.0. qemu 8.1's configure bootstraps a
# private Python venv (mkvenv) that additionally needs the 'distlib' module;
# the script probes for it and provisions a pinned distlib wheel when missing.
#
# Pins (env-overridable):
#   QEMU_VERSION       8.2.2
#   QEMU_SOURCE_SHA256 (see below)
#   QEMU_SOURCE_URL    (see below)
#   QEMU_PATCH_DIR     tools/ffmpeg-dist/qemu-patches (relative to this script)
#   QEMU_CACHE         ${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist/qemu-x86_64-patched
#   QEMU_PYTHON        $(command -v python3), with a venv-capable fallback
#   NPROC              4
# =============================================================================
set -euo pipefail

# --- pins (env-overridable where noted) --------------------------------------
QEMU_VERSION="${QEMU_VERSION:-8.2.2}"
QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-847346c1b82c1a54b2c38f6edbd85549edeb17430b7d4d3da12620e2962bc4f3}"
QEMU_SOURCE_URL="${QEMU_SOURCE_URL:-https://download.qemu.org/qemu-8.2.2.tar.xz}"
if ! QEMU_PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/qemu-patches" && pwd)"; then
  QEMU_PATCH_DIR="$(dirname "$0")/qemu-patches"
fi
QEMU_CACHE="${QEMU_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist/qemu-x86_64-patched}"
QEMU_PYTHON="${QEMU_PYTHON:-$(command -v python3 || true)}"
NPROC="${NPROC:-4}"
# qemu 8.1's configure-time venv (mkvenv) needs the distlib module; when the
# chosen python lacks it, provision this pinned wheel (content-addressed URL).
QEMU_DISTLIB_URL="${QEMU_DISTLIB_URL:-https://files.pythonhosted.org/packages/02/08/9c41fb51ab5b43eb21674aff13df270e8ba6c4b29c8624e328dc7a9482af/distlib-0.4.3-py2.py3-none-any.whl}"
QEMU_DISTLIB_SHA256="${QEMU_DISTLIB_SHA256:-4b0ce306c966eb73bc3a7b6abad017c556dadd92c44701562cd528ac7fde4d5b}"

# --- qemu_is_patched <path> -- true iff <path> is a usable patched qemu ------
# Requires: non-empty and executable, statically linked ELF ('file' matches
# static-pie / statically linked), carries the buildkit-direct-execve marker
# (strings 'safe_execve'), and actually runs (--version exits 0).
qemu_is_patched() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ -x "$path" ]] || return 1
  # NB: no grep -q in these pipelines -- under `set -o pipefail` grep -q exits
  # early on a match, strings/file die with SIGPIPE (141), and the pipeline
  # reports failure despite the match. grep reads all input instead.
  file "$path" | grep -iE 'static' >/dev/null || return 1
  strings "$path" | grep safe_execve >/dev/null || return 1
  "$path" --version >/dev/null 2>&1 || return 1
  return 0
}

# --- qemu_reported_version <path> -- prints the numeric version string -------
# reported by <path>'s --version (e.g. "8.2.2"), or empty when the binary
# cannot report one. Reads all of --version's output (no grep -q, which under
# `set -o pipefail` SIGPIPEs the producer on an early exit and makes the
# pipeline fail).
qemu_reported_version() {
  local path="$1"
  "$path" --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p'
}

# --- idempotency guard: a verified cached qemu matching the pinned version
# means there is nothing to do. The version check protects the byte-identity
# contract: a cache built against a different qemu pin (e.g. 8.1.5 when the pin
# moved to 8.2.2) still passes qemu_is_patched, but a different qemu exposes
# different guest CPUID leaves, which changes the guest toolchain's codegen and
# therefore the final artifact -- so a version-mismatched cache is rebuilt.
if qemu_is_patched "$QEMU_CACHE" && [[ "$(qemu_reported_version "$QEMU_CACHE")" == "$QEMU_VERSION" ]]; then
  echo "==> qemu: $QEMU_CACHE"
  exit 0
fi

# --- host dependency check (fail fast, fail loud; never install anything) ----
missing=()
for dep in meson ninja python3 pkg-config gcc; do
  command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
pkg-config --exists glib-2.0 || missing+=("libglib2.0-dev")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: missing host build dependencies for building the patched qemu:" >&2
  echo "       ${missing[*]}" >&2
  echo "       Install them with:" >&2
  echo "         apt-get install -y meson ninja-build python3 pkg-config gcc libglib2.0-dev" >&2
  exit 1
fi

echo "==> building patched qemu-x86_64 from source (qemu-${QEMU_VERSION}) ..."

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# --- qemu_python_probe <py> -- true iff <py> can create a working venv -------
# qemu 8.1's configure bootstraps a private venv; some pythons (e.g. alpha
# builds) segfault on venv creation, so probe the real capability and fall
# back to a stable system python.
qemu_python_probe() {
  local py="$1" probe_dir="$workdir/pyprobe"
  rm -rf "$probe_dir"
  mkdir -p "$probe_dir"
  "$py" -m venv "$probe_dir/venv" >/dev/null 2>&1
}

if ! qemu_python_probe "$QEMU_PYTHON"; then
  for candidate in /usr/bin/python3 /usr/bin/python3.13 /usr/bin/python3.12 \
                   /usr/bin/python3.11 /usr/bin/python3.10; do
    if [[ -x "$candidate" ]] && qemu_python_probe "$candidate"; then
      QEMU_PYTHON="$candidate"
      break
    fi
  done
fi
if ! qemu_python_probe "$QEMU_PYTHON"; then
  echo "error: no Python with working venv support found (qemu's configure needs one)." >&2
  echo "       Set QEMU_PYTHON=/path/to/a/stables/python3 or install python3-venv." >&2
  exit 1
fi
echo "==> using python: $QEMU_PYTHON"

# --- qemu_python_has_distlib <py> -- true iff mkvenv's distlib is importable -
qemu_python_has_distlib() {
  local py="$1"
  "$py" -c 'import distlib.scripts, distlib.version' >/dev/null 2>&1 && return 0
  "$py" -c 'from pip._vendor import distlib; import pip._vendor.distlib.scripts, pip._vendor.distlib.version' >/dev/null 2>&1 && return 0
  return 1
}

# --- provision distlib (qemu's configure-time venv requires it) ---------------
download_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist"
mkdir -p "$download_dir"
if ! qemu_python_has_distlib "$QEMU_PYTHON"; then
  echo "==> provisioning distlib for qemu's configure-time venv (mkvenv requires it)"
  distlib_wheel="$download_dir/distlib-0.4.3-py2.py3-none-any.whl"
  if [[ ! -f "$distlib_wheel" ]]; then
    curl -fSL --retry 3 -o "$distlib_wheel" "$QEMU_DISTLIB_URL"
  fi
  if ! printf '%s  %s\n' "$QEMU_DISTLIB_SHA256" "$distlib_wheel" | sha256sum -c - >/dev/null; then
    echo "error: sha256 verification failed for $distlib_wheel (expected $QEMU_DISTLIB_SHA256)." >&2
    exit 1
  fi
  distlib_dir="$workdir/distlib"
  mkdir -p "$distlib_dir"
  "$QEMU_PYTHON" -m zipfile -e "$distlib_wheel" "$distlib_dir"
  export PYTHONPATH="$distlib_dir${PYTHONPATH:+:$PYTHONPATH}"
fi

# --- download + verify the qemu source tarball (cache dir, reuse on rerun) ---
tarball="$download_dir/qemu-${QEMU_VERSION}.tar.xz"
if [[ ! -f "$tarball" ]]; then
  echo "==> downloading $QEMU_SOURCE_URL"
  curl -fSL --retry 3 -o "$tarball" "$QEMU_SOURCE_URL"
fi
echo "==> verifying sha256 of $tarball"
if ! printf '%s  %s\n' "$QEMU_SOURCE_SHA256" "$tarball" | sha256sum -c -; then
  echo "error: sha256 verification failed for $tarball (expected $QEMU_SOURCE_SHA256)." >&2
  exit 1
fi

# --- extract, apply the 7 patches in sorted order -----------------------------
echo "==> extracting qemu-${QEMU_VERSION}"
tar -xJf "$tarball" -C "$workdir"
source_dir="$workdir/qemu-${QEMU_VERSION}"
if [[ ! -d "$source_dir" ]]; then
  echo "error: extracted source not found at $source_dir." >&2
  exit 1
fi
cd "$source_dir"
for patch_file in "$QEMU_PATCH_DIR"/*.patch; do
  echo "==> applying $(basename "$patch_file")"
  if ! patch -p1 < "$patch_file"; then
    echo "error: failed to apply $(basename "$patch_file") to qemu-${QEMU_VERSION}." >&2
    echo "       See plans/ffmpeg-dist-qemu-selfheal.md NOTES and /tmp/first_build_dump.txt" >&2
    echo "       for the documented 8.2.2 hand-port recipe if the v8.1 series" >&2
    echo "       needs manual adaptation." >&2
    exit 1
  fi
done

# --- host-compat fix: glibc >= 2.41 already defines struct sched_attr ---------
# qemu 8.2.2 defines its own copy unconditionally; under -D_GNU_SOURCE glibc
# >= 2.41 also defines it (bits/sched.h), so the copy must be guarded. Same fix
# the first-build recipe applied to the known-good 8.2.2 binary.
echo "==> guarding struct sched_attr for glibc >= 2.41"
"$QEMU_PYTHON" - "$source_dir/linux-user/syscall.c" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
anchor = "/* sched_attr is not defined in glibc */\nstruct sched_attr {"
if anchor not in src:
    print("error: sched_attr anchor not found in " + path, file=sys.stderr)
    sys.exit(1)
guard = ("/* sched_attr is not defined in glibc */\n"
         "#if !defined(__GLIBC_PREREQ) || !__GLIBC_PREREQ(2, 41)\n"
         "struct sched_attr {")
src = src.replace(anchor, guard, 1)
start = src.index("struct sched_attr {")
close = src.index("};", start)
src = src[: close + 2] + "\n#endif" + src[close + 2:]
open(path, "w", encoding="utf-8").write(src)
print("ok: guarded struct sched_attr")
PYEOF

# --- out-of-tree configure + ninja -------------------------------------------
build_dir="$source_dir/build"
mkdir -p "$build_dir"
cd "$build_dir"
configure_flags=(
  --python="$QEMU_PYTHON"
  --target-list=x86_64-linux-user
  --static
  --disable-system
  --disable-docs
  --disable-tools
  --disable-guest-agent
  --disable-werror
)
echo "==> configuring (../configure ${configure_flags[*]})"
if ! ../configure "${configure_flags[@]}" > configure.log 2>&1; then
  if grep -qiE 'install-blobs|install_blobs|bzip2' configure.log; then
    echo "==> configure failed on install-blobs; retrying with --disable-install-blobs"
    if ! ../configure "${configure_flags[@]}" --disable-install-blobs > configure.log 2>&1; then
      echo "error: qemu configure failed (see $build_dir/configure.log):" >&2
      tail -20 configure.log >&2
      exit 1
    fi
  else
    echo "error: qemu configure failed (see $build_dir/configure.log):" >&2
    tail -20 configure.log >&2
    exit 1
  fi
fi
echo "==> ninja -j$NPROC"
build_start="$(date +%s)"
ninja -j"$NPROC"
build_end="$(date +%s)"
echo "==> qemu build finished in $((build_end - build_start))s"

# --- verify the built binary, install to the cache ----------------------------
built_bin="$build_dir/qemu-x86_64"
if ! qemu_is_patched "$built_bin"; then
  echo "error: built qemu-x86_64 failed verification (static / safe_execve / executable checks)." >&2
  exit 1
fi
version_line="$("$built_bin" --version 2>&1 | head -1)"
if [[ "$version_line" != *"$QEMU_VERSION"* ]]; then
  echo "error: built qemu reports '$version_line' (expected qemu-${QEMU_VERSION})." >&2
  exit 1
fi
mkdir -p "$(dirname "$QEMU_CACHE")"
cp -f "$built_bin" "$QEMU_CACHE"
chmod +x "$QEMU_CACHE"
echo "==> qemu: $QEMU_CACHE"