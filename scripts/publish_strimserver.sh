#!/usr/bin/env bash
# `bazel run //:publish_strimserver` -- replaces `make publish-strimserver`.
# Uploads BOTH architecture bundles (+ checksums) and the Stream Deck plugin
# bundles to S3. Does NOT gate on check-no-twitch-key: this is the private,
# single-tenant S3 build path that intentionally bakes the operator's own key.
# The tars come from the UNCHECKED targets (byte-identical to the gated ones).
set -euo pipefail

tar="$1"
tar_arm64="$2"
sha256="$3"
sha256_arm64="$4"
streamdeck="$5"
streamdeck_gz="$6"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //:publish_strimserver}"

aws s3 cp "$tar" "$bucket/strimserver-deployment.tar"
aws s3 cp "$tar_arm64" "$bucket/strimserver-deployment-arm64.tar"
aws s3 cp "$sha256" "$bucket/strimserver-deployment.tar.sha256"
aws s3 cp "$sha256_arm64" "$bucket/strimserver-deployment-arm64.tar.sha256"
aws s3 cp "$streamdeck" "$bucket/strimserver-streamdeck-plugin.zip"
aws s3 cp "$streamdeck_gz" "$bucket/strimserver-streamdeck-plugin.tar.gz"
