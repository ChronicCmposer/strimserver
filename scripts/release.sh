#!/usr/bin/env bash
# `bazel run //:release` -- replaces `make release GIT_TAG=v1.0.0`.
# Requires the GitHub CLI (`gh auth login`) and a pushed tag.
set -euo pipefail

tar="$1"
streamdeck="$2"
streamdeck_gz="$3"

git_tag="${GIT_TAG:-}"
if [ -z "$git_tag" ] && [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
   git_tag="$(cd "$BUILD_WORKSPACE_DIRECTORY" && git describe --tags --exact-match 2>/dev/null || true)"
fi

if [ -z "$git_tag" ]; then
   echo "Set GIT_TAG (e.g. GIT_TAG=v1.0.0 bazel run //:release)" >&2
   exit 1
fi

echo "Packaged: $tar"
echo "Stream Deck plugin: $streamdeck"
echo "Stream Deck plugin (tar.gz): $streamdeck_gz"

if ! gh release view "$git_tag" >/dev/null 2>&1; then
   echo "Release $git_tag does not exist; creating it" >&2
   gh release create "$git_tag" --title "$git_tag" --generate-notes
fi

gh release upload "$git_tag" "$tar" "$streamdeck" "$streamdeck_gz" --clobber
