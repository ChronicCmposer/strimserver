#!/usr/bin/env bash
 
set -xeuo pipefail
FFMPEG="/usr/bin/ffmpeg"

set -a
. /opt/strimserver.env
set +a

# Required
: "${INGEST_SERVER:?INGEST_SERVER is not set (e.g. ingest.global-contribute.live-video.net)}"
: "${STREAM_KEY:?STREAM_KEY is not set - you should get this from twitch...}"

: "${STRIMSERVER_SRT_INGEST_PORT:?STRIMSERVER_SRT_INGEST_PORT is not set}"
: "${SRT_PUBLISH_PATH:?SRT_PUBLISH_PATH is not set}"
: "${SRT_PACKET_SIZE:?SRT_PACKET_SIZE is not set}"
: "${SRT_LATENCY_US:?SRT_LATENCY_US is not set}"
: "${SRT_MAX_BW_BYTES_PER_SEC:?SRT_MAX_BW_BYTES_PER_SEC is not set}"
: "${SRT_INPUT_BW_BYTES_PER_SEC:?SRT_INPUT_BW_BYTES_PER_SEC is not set}"
: "${SRT_OVERHEAD_BW_PERCENT:?SRT_OVERHEAD_BW_PERCENT is not set}"

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


# INPUT_RTMP_URL="rtmp://localhost/macbook_encoder"

INPUT_SRT_URL="$(printf 'srt://localhost:%d?streamid=read:%s&pkt_size=%d&latency=%d&tlpktdrop=1&maxbw=%d&inputbw=%d&oheadbw=%d' \
	"$STRIMSERVER_SRT_INGEST_PORT" \
	"$SRT_PUBLISH_PATH" \
	"$SRT_PACKET_SIZE" \
	"$SRT_LATENCY_US" \
	"$SRT_MAX_BW_BYTES_PER_SEC" \
	"$SRT_INPUT_BW_BYTES_PER_SEC" \
	"$SRT_OVERHEAD_BW_PERCENT")"

# INPUT_SRT_URL="$(printf 'srt://localhost:%d?streamid=read:%s&latency=%d' \
# 	"$STRIMSERVER_SRT_INGEST_PORT" \
# 	"$SRT_PUBLISH_PATH" \
# 	"$SRT_LATENCY_US")"


  # -fflags +discardcorrupt \
  # -err_detect ignore_err \
  # -rtmp_enhanced_codecs hvc1,mp4a \
  #
  # -fflags nobuffer \
  # -avioflags direct \
  # -probesize 32768 \
  # -analyzeduration 0 \
  # -max_delay 0 \

exec "$FFMPEG" \
  -fflags +discardcorrupt \
  -err_detect ignore_err \
  -hwaccel cuda \
  -hwaccel_output_format cuda \
  -color_range tv \
  -colorspace bt709 \
  -color_primaries bt709 \
  -color_trc bt709 \
  -f mpegts \
  -i "$INPUT_SRT_URL" \
  -vf "scale_cuda=1920:1080:format=nv12:interp_algo=lanczos" \
  -c:v h264_nvenc \
  -b:v "$VIDEO_BITRATE" \
  -maxrate "$VIDEO_BITRATE" \
  -minrate "$VIDEO_BITRATE" \
  -bufsize "$VIDEO_BITRATE" \
  -preset p1 \
  -tune ll \
  -rc cbr \
  -zerolatency 1 \
  -rc-lookahead 0 \
  -delay 0 \
  -profile:v high \
  -level 4.2 \
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
  -flvflags no_duration_filesize \
  -flush_packets 1 \
  -max_interleave_delta 100000 \
  -muxdelay 0 \
  -muxpreload 0 \
  -f flv \
  "$RTMP_URL"


