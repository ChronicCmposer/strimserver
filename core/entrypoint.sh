#!/bin/sh

set -xeuo

set -a
. /opt/strimserver/config/strimserver.env
set +a

# Optional: load from Docker secret file if env var not already set
if [ -z "${SRT_PUBLISH_PASSPHRASE:-}" ] && [ -f /run/secrets/srt-passphrase ]; then
  SRT_PUBLISH_PASSPHRASE="$(cat /run/secrets/srt-passphrase)"
  export SRT_PUBLISH_PASSPHRASE
fi

# Fail fast if missing
: "${NVIDIA_DRIVER_VERSION_MAJOR:?NVIDIA_DRIVER_VERSION_MAJOR is required}"
: "${NORMALIZED_MPEGTS_SOCKET:?NORMALIZED_MPEGTS_SOCKET is required}"

cd /usr/lib64 \
   && ln -sf libcuda.so.$NVIDIA_DRIVER_VERSION_MAJOR* libcuda.so.1 \
   && ln -sf libnvcuvid.so.$NVIDIA_DRIVER_VERSION_MAJOR* libnvcuvid.so.1 \
   && ln -sf libnvidia-ptxjitcompiler.so.$NVIDIA_DRIVER_VERSION_MAJOR* libnvidia-ptxjitcompiler.so.1 \
   && ln -sf libnvidia-encode.so.$NVIDIA_DRIVER_VERSION_MAJOR* libnvidia-encode.so.1 \
   && cd

# Render final config
envsubst < /opt/strimserver/config/mediamtx.yaml.template > /opt/strimserver/config/mediamtx.yaml


rm -f "$NORMALIZED_MPEGTS_SOCKET"

exec /usr/bin/nice -n -10 /usr/local/bin/mediamtx /opt/strimserver/config/mediamtx.yaml

