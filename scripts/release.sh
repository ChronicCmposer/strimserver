#!/usr/bin/env bash
# `bazel run //:release` -- replaces `make release GIT_TAG=v1.0.0`.
# Uploads the FOUR deployment bundles (Go + C, amd64 + arm64) with their
# checksums and the Stream Deck plugin bundles to the tagged GitHub release,
# all built by the one invocation. Requires the GitHub CLI (`gh auth login`)
# and a pushed tag.
set -euo pipefail

go_tar_amd64="$1"
go_tar_arm64="$2"
c_tar_amd64="$3"
c_tar_arm64="$4"
go_sha256_amd64="$5"
go_sha256_arm64="$6"
c_sha256_amd64="$7"
c_sha256_arm64="$8"
streamdeck="$9"
streamdeck_gz="${10}"

git_tag="${GIT_TAG:-}"
if [ -z "$git_tag" ] && [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
   git_tag="$(cd "$BUILD_WORKSPACE_DIRECTORY" && git describe --tags --exact-match 2>/dev/null || true)"
fi

if [ -z "$git_tag" ]; then
   echo "Set GIT_TAG (e.g. GIT_TAG=v1.0.0 bazel run //:release)" >&2
   exit 1
fi

echo "Go bundle (amd64): $go_tar_amd64"
echo "Go bundle (arm64): $go_tar_arm64"
echo "C bundle (amd64): $c_tar_amd64"
echo "C bundle (arm64): $c_tar_arm64"
echo "SHA-256 (go amd64): $go_sha256_amd64"
echo "SHA-256 (go arm64): $go_sha256_arm64"
echo "SHA-256 (c amd64): $c_sha256_amd64"
echo "SHA-256 (c arm64): $c_sha256_arm64"
echo "Stream Deck plugin: $streamdeck"
echo "Stream Deck plugin (tar.gz): $streamdeck_gz"

if ! gh release view "$git_tag" >/dev/null 2>&1; then
   echo "Release $git_tag does not exist; creating it" >&2
   gh release create "$git_tag" --title "$git_tag" --generate-notes
fi

gh release upload "$git_tag" \
   "$go_tar_amd64" "$go_tar_arm64" "$c_tar_amd64" "$c_tar_arm64" \
   "$go_sha256_amd64" "$go_sha256_arm64" "$c_sha256_amd64" "$c_sha256_arm64" \
   "$streamdeck" "$streamdeck_gz" --clobber