#!/usr/bin/env bash
# `bazel run //tools/streamdeck-plugin:publish_streamdeck` -- replaces
# `make publish-streamdeck`.
# Uploads ONLY the Stream Deck plugin bundle to S3, using the same object key
# as `make publish-strimserver` (which uploads the deployment tar and the
# plugin bundle together).
set -euo pipefail

# --- project-scoped operator profile (decision 11b) ---------------------------
# The aws-profile contract (pin [strimserver], reject other identities) lives in
# ONE shared library so no call site re-implements it. Find the repo root the
# same way the Go tooling does: BUILD_WORKSPACE_DIRECTORY when `bazel run` set
# it, otherwise walk up from this script's directory.
_ss_root="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
while [[ ! -f "$_ss_root/deploy/aws/lib/aws_profile.sh" && "$_ss_root" != "/" ]]; do
  _ss_root="$(dirname "$_ss_root")"
done
. "$_ss_root/deploy/aws/lib/aws_profile.sh"
unset _ss_root
# ------------------------------------------------------------------------------

streamdeck="$1"
streamdeck_gz="$2"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //tools/streamdeck-plugin:publish_streamdeck}"

require_strimserver_identity || exit 1
aws_strim s3 cp "$streamdeck" "$bucket/strimserver-streamdeck-plugin.zip"
aws_strim s3 cp "$streamdeck_gz" "$bucket/strimserver-streamdeck-plugin.tar.gz"
