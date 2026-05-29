#!/usr/bin/env bash

set -euo pipefail

: "${TARGET_PORT:=1234}"
: "${BUILDKITD_PID_FILE:=/var/run/buildkit/buildkitd.pid}"
: "${SOCAT_PID_FILE:=/var/run/buildkit/socat-$TARGET_PORT.pid}"

# 6) EC2: later, kill background processes using saved PIDs

# Stop socat first
sudo kill -9 "$(cat $SOCAT_PID_FILE)" 2>/dev/null || true

# Stop buildkitd
sudo kill -9 "$(cat $BUILDKITD_PID_FILE)" 2>/dev/null || true

# (optional) confirm they're gone
ps -p "$(cat $SOCAT_PID_FILE 2>/dev/null)" 2>/dev/null || true
ps -p "$(cat $BUILDKITD_PID_FILE 2>/dev/null)" 2>/dev/null || true

# cleanup
sudo rm -f $SOCAT_PID_FILE
sudo rm -f $BUILDKITD_PID_FILE


