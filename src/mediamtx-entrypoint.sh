#!/usr/bin/env bash
set -xeuo

set -a
. /opt/strimserver.env
set +a


# Optional: load from Docker secret file if env var not already set
if [ -z "${SRT_PUBLISH_PASSPHRASE:-}" ] && [ -f /run/secrets/srt-passphrase ]; then
  SRT_PUBLISH_PASSPHRASE="$(cat /run/secrets/srt-passphrase)"
  export SRT_PUBLISH_PASSPHRASE
fi

# Fail fast if missing
: "${NORMALIZED_MPEGTS_SOCKET:?NORMALIZED_MPEGTS_SOCKET is required}"


# Render final config
envsubst < /opt/mediamtx.yaml.template > /opt/mediamtx.yaml


rm -f "$NORMALIZED_MPEGTS_SOCKET"

exec /usr/bin/nice -n -10 /usr/local/bin/mediamtx /opt/mediamtx.yaml

