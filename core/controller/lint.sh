#!/usr/bin/env bash
# Wrapper so golangci-lint (which shells out to `go`) finds a working Go
# toolchain: rules_go's toolchain isn't on PATH by default in a sandboxed
# Bazel test. $2 is the raw SDK `go` binary (see //tools/bazel:go_bin.bzl),
# not @rules_go//go:go -- that one resets cwd based on BUILD_WORKING_DIRECTORY,
# which is never set under `bazel test`.
set -euo pipefail

golangci_lint="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
go_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
pkg_dir="$(dirname "$3")"

export PATH
PATH="$(dirname "$go_bin"):$PATH"
export GOFLAGS="-mod=mod"
export GOCACHE
GOCACHE="$(mktemp -d)/go-cache"
export GOPATH
GOPATH="$(mktemp -d)/go-path"

cd "$pkg_dir"
exec "$golangci_lint" run --config=.golangci.yml ./...
