#!/usr/bin/env bash
# Replicates core/Dockerfile's mediamtx RUN smoke test (lines 254-259), which
# only ran as a Docker build layer and would otherwise be dropped once the
# image is assembled by Bazel instead of `docker build`.
set -euo pipefail

tar="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xf "$tar" -C "$tmp"

run_dynamic() {
   "$tmp/lib64/ld-linux-x86-64.so.2" --library-path "$tmp/lib/x86_64-linux-gnu" "$@"
}

echo "+ /mediamtx --version"
run_dynamic "$tmp/mediamtx" --version

echo "+ busybox --list"
"$tmp/usr/bin/busybox" --list | grep -qx sh

echo "+ /bin/sh -c 'echo shell-ok'"
[ "$(readlink "$tmp/bin/sh")" = "/usr/bin/busybox" ]

for a in cat rm ln nice mkdir wget; do
   echo "+ command -v $a"
   [ -e "$tmp/usr/bin/$a" ] || { echo "missing: usr/bin/$a" >&2; exit 1; }
done

echo "+ envsubst --version"
run_dynamic "$tmp/usr/bin/envsubst" --version >/dev/null

echo "+ nice --version (real coreutils nice, not a busybox stand-in)"
run_dynamic "$tmp/usr/bin/nice" --version >/dev/null

echo "ok"
