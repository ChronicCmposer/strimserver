#!/usr/bin/env bash
# The controller's runtime image never had a RUN smoke test (only the
# mediamtx/ffmpeg targets in the old Dockerfile did), but since the
# binary is genuinely runnable without a live containerd socket via its
# codegen flags, this exercises the assembled image's exact file layout the
# same way.
set -euo pipefail

tar="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xf "$tar" -C "$tmp"

echo "+ /bin/sh is the real dash binary"
[ -x "$tmp/bin/sh" ]

echo "+ /strimserver-controller -print-env-example"
# The binary is pure (CGO_ENABLED=0), so it needs no interpreter/libc at all
# -- ld-linux/libc.so.6 are bundled only for any future non-pure dependency.
"$tmp/strimserver-controller" -print-env-example | grep -q CONTAINERD_SOCKET

echo "ok"
