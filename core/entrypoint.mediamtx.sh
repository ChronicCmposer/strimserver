#!/bin/sh

set -a
. /strimserver.env
set +a

# Optional: load SRT passphrase from a mounted secret if not already set.
if [ -z "${SRT_PUBLISH_PASSPHRASE:-}" ] && [ -f /run/secrets/srt-passphrase ]; then
   SRT_PUBLISH_PASSPHRASE="$(cat /run/secrets/srt-passphrase)"
   export SRT_PUBLISH_PASSPHRASE
fi

: "${NORMALIZED_MPEGTS_SOCKET:?NORMALIZED_MPEGTS_SOCKET is required}"
: "${MEDIAMTX_CONFIG_TEMPLATE:?MEDIAMTX_CONFIG_TEMPLATE is required}"

CONFIG=/mediamtx.yaml

envsubst < "$MEDIAMTX_CONFIG_TEMPLATE" > "$CONFIG"

rm -f "$NORMALIZED_MPEGTS_SOCKET"

exec /usr/bin/nice -n "$MEDIAMTX_NICE" /mediamtx "$CONFIG"
