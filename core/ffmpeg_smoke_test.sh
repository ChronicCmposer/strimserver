#!/usr/bin/env bash
# Replicates the ffmpeg RUN smoke test the old Dockerfile ran as a build
# layer, which would otherwise be dropped now that the image is assembled by
# Bazel instead of `docker build`. Also asserts every DT_NEEDED soname of
# /ffmpeg is packaged -- the hand-picked .so set is easy to get subtly
# wrong, and the old Dockerfile had no such check.
set -euo pipefail

tar="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xf "$tar" -C "$tmp"

# libfdk-aac.so.2 lives in /usr/lib/x86_64-linux-gnu, unlike the glibc set
# in /lib/x86_64-linux-gnu, so both dirs are on the dynamic linker's path.
run_dynamic() {
   "$tmp/lib64/ld-linux-x86-64.so.2" --library-path "$tmp/lib/x86_64-linux-gnu:$tmp/usr/lib/x86_64-linux-gnu" "$@"
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

# readelf is arch-agnostic for reading an amd64 ELF (it works on this arm64
# host). The interpreter (ld-linux-x86-64.so.2) is exempt: it is not a
# DT_NEEDED soname but a DT_INTERP entry, and lives at /lib64 in the image.
echo "+ every DT_NEEDED soname is packaged"
for lib in $(readelf -d "$tmp/ffmpeg" | awk '/NEEDED/ {gsub(/\[|\]/, "", $5); print $5}'); do
   [ "$lib" = "ld-linux-x86-64.so.2" ] && continue
   find "$tmp" -name "$lib" | grep -q . || {
      echo "FAIL: $lib is NEEDED by ffmpeg but not packaged in the image" >&2
      exit 1
   }
done

echo "ffmpeg smoke test ok"