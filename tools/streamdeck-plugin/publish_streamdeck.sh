#!/usr/bin/env bash
# `bazel run //tools/streamdeck-plugin:publish_streamdeck` -- replaces
# `make publish-streamdeck`.
# Uploads ONLY the Stream Deck plugin bundle to S3, using the same object key
# as `make publish-strimserver` (which uploads the deployment tar and the
# plugin bundle together).
set -euo pipefail

streamdeck="$1"
streamdeck_gz="$2"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //tools/streamdeck-plugin:publish_streamdeck}"

aws s3 cp "$streamdeck" "$bucket/strimserver-streamdeck-plugin.zip"
aws s3 cp "$streamdeck_gz" "$bucket/strimserver-streamdeck-plugin.tar.gz"