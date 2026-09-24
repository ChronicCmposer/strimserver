#!/usr/bin/env bash
# `bazel run //:publish_all` -- the one-shot "publish everything" path:
# uploads the FOUR strimserver deployment tars (Go + C, amd64 + arm64, with
# checksums), the Stream Deck plugin bundle (.zip + .tar.gz), and the iperf3
# bundle to S3 in a single bazel run (one server/analysis pass). The
# individual targets (//:publish_strimserver,
# //tools/bandwidth-test:publish_iperf3,
# //tools/streamdeck-plugin:publish_streamdeck) remain for partial publishes.
# Like publish_strimserver, the tars come from the UNCHECKED targets (no
# twitch-key gate; byte-identical to the gated ones).
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
iperf3="${11}"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //:publish_all}"

aws s3 cp "$go_tar_amd64" "$bucket/strimserver-deployment-go-amd64.tar"
aws s3 cp "$go_tar_arm64" "$bucket/strimserver-deployment-go-arm64.tar"
aws s3 cp "$c_tar_amd64" "$bucket/strimserver-deployment-c-amd64.tar"
aws s3 cp "$c_tar_arm64" "$bucket/strimserver-deployment-c-arm64.tar"
aws s3 cp "$go_sha256_amd64" "$bucket/strimserver-deployment-go-amd64.tar.sha256"
aws s3 cp "$go_sha256_arm64" "$bucket/strimserver-deployment-go-arm64.tar.sha256"
aws s3 cp "$c_sha256_amd64" "$bucket/strimserver-deployment-c-amd64.tar.sha256"
aws s3 cp "$c_sha256_arm64" "$bucket/strimserver-deployment-c-arm64.tar.sha256"
aws s3 cp "$streamdeck" "$bucket/strimserver-streamdeck-plugin.zip"
aws s3 cp "$streamdeck_gz" "$bucket/strimserver-streamdeck-plugin.tar.gz"
aws s3 cp "$iperf3" "$bucket/iperf3-deployment.tar"