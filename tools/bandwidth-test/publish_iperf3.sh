#!/usr/bin/env bash
# `bazel run //tools/bandwidth-test:publish_iperf3` -- replaces
# `make publish-iperf3`.
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

tar="$1"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //tools/bandwidth-test:publish_iperf3}"

require_strimserver_identity || exit 1
aws_strim s3 cp "$tar" "$bucket/iperf3-deployment.tar"
