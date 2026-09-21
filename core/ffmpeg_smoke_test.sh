#!/usr/bin/env bash
# Replicates the ffmpeg RUN smoke test the old Dockerfile ran as a build
# layer, which would otherwise be dropped now that the image is assembled by
# Bazel instead of `docker build`. Also asserts every DT_NEEDED soname of
# /ffmpeg is packaged -- the hand-picked .so set is easy to get subtly
# wrong, and the old Dockerfile had no such check.
#
# The loader basename and multiarch lib dirs are chosen by $2 (the target
# arch, passed by BUILD.bazel's select()): amd64 uses ld-linux-x86-64.so.2 +
# /lib/x86_64-linux-gnu, arm64 uses ld-linux-aarch64.so.1 +
# /lib/aarch64-linux-gnu. The default is amd64, so a bare run behaves exactly
# like the pre-parameterization script.
set -euo pipefail

tar="$1"
arch="${2:-amd64}"

case "$arch" in
  amd64)
    loader_path="lib64/ld-linux-x86-64.so.2"
    libdir="lib/x86_64-linux-gnu"
    libdir2="usr/lib/x86_64-linux-gnu"
    ;;
  arm64)
    loader_path="lib/ld-linux-aarch64.so.1"
    libdir="lib/aarch64-linux-gnu"
    libdir2="usr/lib/aarch64-linux-gnu"
    ;;
  *)
    echo "error: unknown arch '$arch' (expected 'amd64' or 'arm64')" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xf "$tar" -C "$tmp"

# libfdk-aac.so.2 lives in the multiarch lib dir, unlike the glibc set, so
# both dirs are on the dynamic linker's path (absolute, inside $tmp).
run_dynamic() {
   "$tmp/$loader_path" --library-path "$tmp/$libdir:$tmp/$libdir2" "$@"
}

echo "+ /ffmpeg -version"
run_dynamic "$tmp/ffmpeg" -version >/dev/null

echo "+ /ffmpeg -h encoder=h264_nvenc"
run_dynamic "$tmp/ffmpeg" -h encoder=h264_nvenc >/dev/null

echo "+ /ffmpeg -h encoder=hevc_nvenc"
run_dynamic "$tmp/ffmpeg" -h encoder=hevc_nvenc >/dev/null

echo "+ /bin/sh -> /usr/bin/busybox"
[ "$(readlink "$tmp/bin/sh")" = "/usr/bin/busybox" ]

for a in cat rm ln nice mkdir wget; do
   echo "+ usr/bin/$a present"
   [ -e "$tmp/usr/bin/$a" ] || { echo "missing: usr/bin/$a" >&2; exit 1; }
done

echo "+ busybox sh -c 'echo shell-ok'"
run_dynamic "$tmp/usr/bin/busybox" sh -c 'echo shell-ok' >/dev/null

# readelf is arch-agnostic for reading an ELF of either arch. The interpreter
# (e.g. ld-linux-x86-64.so.2 / ld-linux-aarch64.so.1) is exempt: it is not a
# DT_NEEDED soname but a DT_INTERP entry, and lives at the loader_path above.
echo "+ every DT_NEEDED soname is packaged"
for lib in $(readelf -d "$tmp/ffmpeg" | awk '/NEEDED/ {gsub(/\[|\]/, "", $5); print $5}'); do
   [ "$lib" = "${loader_path##*/}" ] && continue
   find "$tmp" -name "$lib" | grep -q . || {
      echo "FAIL: $lib is NEEDED by ffmpeg but not packaged in the image" >&2
      exit 1
   }
done

echo "ffmpeg smoke test ok"