#!/bin/sh
# =============================================================================
# entrypoint.mediamtx.sh  -- runs in the "mediamtx" (FROM scratch) container.
#
# Minimal responsibilities:
#   1. source config (+ optional SRT passphrase secret)
#   2. render mediamtx.yaml from the BIND-MOUNTED template
#   3. recreate the listen-mode unix socket cleanly
#   4. exec mediamtx as the container's main process
#
# The template is bind-mounted at runtime, not baked into the image. Its
# runOnReady hooks invoke thin HTTP clients that talk to strimserver-controller;
# this entrypoint does NOT read, rewrite, or otherwise touch runOnReady.
#
# Paths are overridable via env:
#   MEDIAMTX_TEMPLATE  (default /opt/strimserver/config/mediamtx.yaml.template)
#   MEDIAMTX_CONFIG    (default /opt/strimserver/mediamtx.yaml, writable layer)
# =============================================================================

set -xeuo

set -a
. /strimserver.env
set +a

# Optional: load SRT passphrase from a mounted secret if not already set.
if [ -z "${SRT_PUBLISH_PASSPHRASE:-}" ] && [ -f /run/secrets/srt-passphrase ]; then
   SRT_PUBLISH_PASSPHRASE="$(cat /run/secrets/srt-passphrase)"
   export SRT_PUBLISH_PASSPHRASE
fi

: "${NORMALIZED_MPEGTS_SOCKET:?NORMALIZED_MPEGTS_SOCKET is required}"

TEMPLATE="${MEDIAMTX_TEMPLATE:-/mediamtx.yaml.template}"
CONFIG="${MEDIAMTX_CONFIG:-/mediamtx.yaml}"

# Render the bind-mounted template (runOnReady left exactly as authored).
envsubst < "$TEMPLATE" > "$CONFIG"

# Recreate the socket cleanly: mediamtx creates it in listen mode here, and the
# ffmpeg container connects to it.
rm -f "$NORMALIZED_MPEGTS_SOCKET"

# Run mediamtx as PID 1 (nice -n -10; the controller grants CAP_SYS_NICE).
exec /usr/bin/nice -n -10 /mediamtx "$CONFIG"
