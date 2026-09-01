#!/usr/bin/env bash
# `bazel run //:publish_all` -- the one-shot "publish everything" path:
# uploads the strimserver deployment tar, the Stream Deck plugin bundle
# (.zip + .tar.gz), and the iperf3 bundle to S3 in a single bazel run (one
# server/analysis pass). The three individual targets (//:publish_strimserver,
# //tools/bandwidth-test:publish_iperf3, //tools/streamdeck-plugin:publish_streamdeck)
# remain for partial publishes.
set -euo pipefail

tar="$1"
streamdeck="$2"
streamdeck_gz="$3"
iperf3="$4"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //:publish_all}"

aws s3 cp "$tar" "$bucket/strimserver-deployment.tar"
aws s3 cp "$streamdeck" "$bucket/strimserver-streamdeck-plugin.zip"
aws s3 cp "$streamdeck_gz" "$bucket/strimserver-streamdeck-plugin.tar.gz"
aws s3 cp "$iperf3" "$bucket/iperf3-deployment.tar"
