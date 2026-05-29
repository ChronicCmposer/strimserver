#!/usr/bin/env bash

set -xeuo pipefail

: "${TARGET_PORT:=1234}"
: "${BUILDKITD_PID_FILE:=/var/run/buildkit/buildkitd.pid}"
: "${BUILDKITD_LOG_FILE:=/mnt/nvme/buildkit/buildkitd.log}"
: "${BUILDKITD_ROOT_DIR:=/mnt/nvme/buildkit}"
: "${SOCAT_PID_FILE:=/var/run/buildkit/socat-$TARGET_PORT.pid}"
: "${SOCAT_LOG_FILE:=/mnt/nvme/buildkit/socat-$TARGET_PORT.log}"

# 1) EC2 (in the SSH session): download + install buildkit, then start buildkitd in background (default unix socket)

BUILDKIT_TEMP_DIR="$(mktemp -d)"
BUILDKIT_DIST_FILE="${BUILDKIT_TEMP_DIR%/}/buildkit-bin.tar.gz"

cleanup() { rm -rf $BUILDKIT_TEMP_DIR; }
trap cleanup EXIT INT TERM

wget -O $BUILDKIT_DIST_FILE "https://github.com/moby/buildkit/releases/download/v0.26.3/buildkit-v0.26.3.linux-amd64.tar.gz"
sudo tar -xzvf $BUILDKIT_DIST_FILE -C /usr/local 

# Start buildkitd (unix socket: /run/buildkit/buildkitd.sock)
BUILDKITD_UNIX_SOCKET=/run/buildkit/buildkitd.sock
sudo mkdir -p /run/buildkit /mnt/nvme/buildkit
sudo env \
   BUILDKITD_UNIX_SOCKET="$BUILDKITD_UNIX_SOCKET" \
   BUILDKITD_LOG_FILE="$BUILDKITD_LOG_FILE" \
   BUILDKITD_PID_FILE="$BUILDKITD_PID_FILE" \
   BUILDKITD_ROOT_DIR="$BUILDKITD_ROOT_DIR" \
   sh -c "nohup /usr/local/bin/buildkitd --debug \
   --root $BUILDKITD_ROOT_DIR \
   --addr unix://$BUILDKITD_UNIX_SOCKET \
   > $BUILDKITD_LOG_FILE 2>&1 \
   & echo \$! > $BUILDKITD_PID_FILE"


# 3) EC2: bind the unix socket to TCP port 1234

# Install socat 
sudo yum -y update
sudo yum -y install socat 

# Forward TCP :$TARGET_PORT -> unix socket
sudo env \
   TARGET_PORT="$TARGET_PORT" \
   BUILDKITD_UNIX_SOCKET="$BUILDKITD_UNIX_SOCKET" \
   SOCAT_PID_FILE="$SOCAT_PID_FILE" \
   SOCAT_LOG_FILE="$SOCAT_LOG_FILE" \
   sh -c "nohup socat TCP-LISTEN:$TARGET_PORT,reuseaddr,fork \
   UNIX-CONNECT:$BUILDKITD_UNIX_SOCKET \
   > $SOCAT_LOG_FILE 2>&1 \
   & echo \$! > $SOCAT_PID_FILE"

# (optional) quick sanity check that something is listening
ss -ltnp | grep ":$TARGET_PORT"

# print PIDs
printf "buildkitd pid = %s\nsocat pid = %s\n\n" \
   "$(cat $BUILDKITD_PID_FILE)" \
   "$(cat $SOCAT_PID_FILE)"

