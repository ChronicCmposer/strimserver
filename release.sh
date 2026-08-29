#!/usr/bin/env bash
# `bazel run //:release` -- replaces `make release GIT_TAG=v1.0.0`.
# Requires the GitHub CLI (`gh auth login`) and a pushed tag.
set -euo pipefail

tar="$1"
sha256="$2"

git_tag="${GIT_TAG:-}"
if [ -z "$git_tag" ] && [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
   git_tag="$(cd "$BUILD_WORKSPACE_DIRECTORY" && git describe --tags --exact-match 2>/dev/null || true)"
fi

if [ -z "$git_tag" ]; then
   echo "Set GIT_TAG (e.g. GIT_TAG=v1.0.0 bazel run //:release)" >&2
   exit 1
fi

echo "Packaged: $tar"
cat "$sha256"

gh release upload "$git_tag" "$tar" "$sha256" --clobber
