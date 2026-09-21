#!/usr/bin/env bash
# `bazel run //:publish_all` -- the one-shot "publish everything" path:
# uploads BOTH strimserver deployment tars (+ checksums), the Stream Deck
# plugin bundle (.zip + .tar.gz), and the iperf3 bundle to S3 in a single
# bazel run (one server/analysis pass). The individual targets
# (//:publish_strimserver, //tools/bandwidth-test:publish_iperf3,
# //tools/streamdeck-plugin:publish_streamdeck) remain for partial publishes.
# Like publish_strimserver, the tars come from the UNCHECKED targets (no
# twitch-key gate; byte-identical to the gated ones).
set -euo pipefail

tar="$1"
tar_arm64="$2"
sha256="$3"
sha256_arm64="$4"
streamdeck="$5"
streamdeck_gz="$6"
iperf3="$7"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //:publish_all}"

aws s3 cp "$tar" "$bucket/strimserver-deployment.tar"
aws s3 cp "$tar_arm64" "$bucket/strimserver-deployment-arm64.tar"
aws s3 cp "$sha256" "$bucket/strimserver-deployment.tar.sha256"
aws s3 cp "$sha256_arm64" "$bucket/strimserver-deployment-arm64.tar.sha256"
aws s3 cp "$streamdeck" "$bucket/strimserver-streamdeck-plugin.zip"
aws s3 cp "$streamdeck_gz" "$bucket/strimserver-streamdeck-plugin.tar.gz"
aws s3 cp "$iperf3" "$bucket/iperf3-deployment.tar"
