#!/usr/bin/env bash
# `bazel run //tools/bandwidth-test:publish_iperf3` -- replaces
# `make publish-iperf3`.
set -euo pipefail

tar="$1"
bucket="${S3_BUCKET:?Set S3_BUCKET, e.g. S3_BUCKET=s3://your-bucket-name bazel run //tools/bandwidth-test:publish_iperf3}"

echo "We built $tar EZ Clap"
aws s3 cp "$tar" "$bucket/iperf3-deployment.tar"
