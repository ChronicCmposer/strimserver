#!/usr/bin/env bash
set -xeuo

set -a
. /opt/strimserver.env
set +a


# Optional: load from Docker secret file if env var not already set
if [ -z "${SRT_READ_PASSPHRASE:-}" ] && [ -f /run/secrets/srt-passphrase ]; then
  SRT_READ_PASSPHRASE="$(cat /run/secrets/srt-passphrase)"
  export SRT_READ_PASSPHRASE
fi

# Fail fast if missing
: "${SRT_READ_PASSPHRASE:?SRT_READ_PASSPHRASE is required}"

# Render final config
envsubst '${SRT_READ_PASSPHRASE}' \
   < /opt/mediamtx.yaml.template \
   > /opt/mediamtx.yaml


exec /usr/local/bin/mediamtx \
   /opt/mediamtx.yaml

