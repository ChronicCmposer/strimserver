#!/usr/bin/env bash

set -euo pipefail

: "${TARGET_HOST:=bkd}"
: "${TARGET_PORT:=1234}"
: "${LOCAL_PORT:=1234}"
: "${BUILDKITD_PID_FILE:=/var/run/buildkit/buildkitd.pid}"
: "${BUILDKITD_LOG_FILE:=/var/log/buildkit/buildkitd.log}"
: "${SOCAT_PID_FILE:=/var/run/buildkit/socat-$TARGET_PORT.pid}"

# copy deploy script
scp tools/buildkit-scripts/buildkitd-deploy.sh $TARGET_HOST:./buildkitd-deploy.sh
ssh $TARGET_HOST "chmod +x buildkitd-deploy.sh"
ssh $TARGET_HOST "TARGET_PORT=$TARGET_PORT \
   BUILDKITD_PID_FILE=$BUILDKITD_PID_FILE \
   SOCAT_PID_FILE=$SOCAT_PID_FILE \
   BUILDKITD_LOG_FILE=$BUILDKITD_LOG_FILE \
   ./buildkitd-deploy.sh"

# 4) LOCAL (new terminal): create an SSH tunnel from EC2:1234 to local:1234
ssh -N -L "$TARGET_PORT:127.0.0.1:$LOCAL_PORT" $TARGET_HOST 
# Keep this running while you use buildctl locally.


