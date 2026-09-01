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
# Write to a temp file instead of piping into `grep -q`: grep exits as soon as
# it matches and closes the pipe, and the Go runtime then kills the still-
# writing controller with SIGPIPE (a race that is reliably hit under qemu-user
# emulation on non-x86_64 hosts).
"$tmp/strimserver-controller" -print-env-example >"$tmp/env-example.out"
grep -q CONTAINERD_SOCKET "$tmp/env-example.out"

echo "ok"
