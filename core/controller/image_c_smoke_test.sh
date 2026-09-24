#!/usr/bin/env bash
# Wave-4 smoke test for the C controller image: the musl-static C binary is
# the ONLY file in the image and it IS the entrypoint -- no /bin/sh, no
# /entrypoint.sh, no dash/libc6/ld-linux donors. Run explicitly under the
# matching zig musl config (the targets are manual):
#   bazel test //core/controller:image_c_smoke_test --config=amd64
#   bazel test //core/controller:image_c_smoke_test --config=arm64
set -euo pipefail

tar="$1"
expected_arch="$2"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xf "$tar" -C "$tmp"

echo "+ no shell / entrypoint / donor packages in the C image"
[ ! -e "$tmp/bin/sh" ]
[ ! -e "$tmp/bin/dash" ]
[ ! -e "$tmp/entrypoint.sh" ]
[ ! -e "$tmp/lib64/ld-linux-x86-64.so.2" ]
[ ! -e "$tmp/lib/ld-linux-aarch64.so.1" ]
[ ! -e "$tmp/lib/x86_64-linux-gnu/libc.so.6" ]
[ ! -e "$tmp/lib/aarch64-linux-gnu/libc.so.6" ]

echo "+ /strimserver-controller is the only payload and is executable"
[ -x "$tmp/strimserver-controller" ]
[ "$(find "$tmp" -type f | wc -l)" -eq 1 ]

echo "+ ELF arch matches the target ($expected_arch)"
arch="$(file -b "$tmp/strimserver-controller")"
case "$expected_arch" in
  amd64)
    case "$arch" in
      *x86-64*) ;;
      *) echo "expected x86-64, got: $arch" >&2; exit 1 ;;
    esac
    ;;
  arm64)
    case "$arch" in
      *aarch64*) ;;
      *) echo "expected aarch64, got: $arch" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "unknown expected arch: $expected_arch" >&2
    exit 1
    ;;
esac

echo "+ /strimserver-controller -print-env-example"
# Write to a temp file instead of piping into `grep -q`: grep exits as soon as
# it matches and closes the pipe, and the controller then kills the still-
# writing process with SIGPIPE (a race that is reliably hit under qemu-user
# emulation on non-x86_64 hosts).
"$tmp/strimserver-controller" -print-env-example >"$tmp/env-example.out"
grep -q CONTAINERD_SOCKET "$tmp/env-example.out"

echo "ok"