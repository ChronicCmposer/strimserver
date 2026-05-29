#!/usr/bin/env bash

set -euo pipefail

: "${TARGET_HOST:=bkd}"
: "${BUILDKITD_LOG_FILE:=/var/log/buildkit/buildkitd.log}"


# 2) EC2: connect to the background buildkitd stdout (follow logs)
ssh $TARGET_HOST -c "sudo tail -n 200 -f $BUILDKITD_LOG_FILE"
# (Ctrl+C to stop following; buildkitd keeps running)

