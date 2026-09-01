#!/usr/bin/env bash
# `bazel run //:publish_strimserver` -- replaces `make publish-strimserver`.
# Does NOT gate on check-no-twitch-key: this is the private, single-tenant
# S3 build path that intentionally bakes the operator's own key.
set -euo pipefail

tar="$1"
streamdeck="$2"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //:publish_strimserver}"

aws s3 cp "$tar" "$bucket/strimserver-deployment.tar"
aws s3 cp "$streamdeck" "$bucket/strimserver-streamdeck-plugin.zip"
