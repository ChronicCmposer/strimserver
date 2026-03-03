#!/usr/bin/env bash
 
set -xeuo pipefail
FFMPEG="/usr/bin/ffmpeg"

set -a
. /opt/strimserver.env
set +a

# Required
: "${INGEST_SERVER:?INGEST_SERVER is not set (e.g. ingest.global-contribute.live-video.net)}"
: "${STREAM_KEY:?STREAM_KEY is not set - you should get this from twitch...}"

# Optional with defaults
BANDWIDTH_TEST="${BANDWIDTH_TEST:-true}"
VIDEO_BITRATE="${VIDEO_BITRATE:-5700k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-160k}"

# Normalize boolean-ish values
case "${BANDWIDTH_TEST,,}" in
  1|true|yes|y|on)   BW_PARAM="?bandwidthtest=true" ;;
  0|false|no|n|off|"") BW_PARAM="" ;;
  *) echo "Invalid BANDWIDTH_TEST: '$BANDWIDTH_TEST' (use true/false)"; exit 2 ;;
esac

RTMP_URL="rtmp://${INGEST_SERVER}/app/${STREAM_KEY}${BW_PARAM}"


INPUT_RTSP_URL="rtsp://localhost:8554/macbook_encoder"
INPUT_RTMP_URL="rtmp://localhost/macbook_encoder"


  # -fflags +discardcorrupt \
  # -err_detect ignore_err \

exec "$FFMPEG" \
  -color_range tv \
  -colorspace bt709 \
  -color_primaries bt709 \
  -color_trc bt709 \
  -rtmp_enhanced_codecs hvc1,mp4a \
  -i "$INPUT_RTMP_URL" \
  -c:v h264_nvenc \
  -b:v "$VIDEO_BITRATE" \
  -preset 15 \
  -profile:v 1 \
  -tune 1 \
  -level 42 \
  -rc 2 \
  -cbr true \
  -coder 2 \
  -g 120 \
  -keyint_min 120 \
  -bf 0 \
  -color_range tv \
  -colorspace bt709 \
  -color_primaries bt709 \
  -color_trc bt709 \
  -c:a libfdk_aac -b:a "$AUDIO_BITRATE" \
  -ar 48000 \
  -ac 2 \
  -f flv \
  "$RTMP_URL" 


