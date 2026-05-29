#!/usr/bin/env bash

set -euo pipefail

: "${TARGET_HOST:=bkd}"
: "${TARGET_PORT:=1234}"
: "${BUILDKITD_PID_FILE:=/var/run/buildkit/buildkitd.pid}"
: "${SOCAT_PID_FILE:=/var/run/buildkit/socat-$TARGET_PORT.pid}"


# copy teardown script
scp tools/buildkit-scripts/buildkitd-teardown.sh $TARGET_HOST:./buildkitd-teardown.sh
ssh $TARGET_HOST "chmod +x buildkitd-teardown.sh"
ssh $TARGET_HOST "TARGET_PORT=$TARGET_PORT \
   BUILDKITD_PID_FILE=$BUILDKITD_PID_FILE \
   SOCAT_PID_FILE=$SOCAT_PID_FILE \
   ./buildkitd-teardown.sh"

