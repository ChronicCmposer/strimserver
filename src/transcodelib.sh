#!/usr/bin/env bash

set -xeuo pipefail
FFMPEG="/usr/bin/ffmpeg"

set -a
. /opt/strimserver.env
set +a

# loglevel is a string or a number containing one of the following values:
#
# ‘quiet, -8’
# Show nothing at all; be silent.
#
# ‘panic, 0’
# Only show fatal errors which could lead the process to crash, such as an assertion failure. This is not currently used for anything.
#
# ‘fatal, 8’
# Only show fatal errors. These are errors after which the process absolutely cannot continue.
#
# ‘error, 16’
# Show all errors, including ones which can be recovered from.
#
# ‘warning, 24’
# Show all warnings and errors. Any message related to possibly incorrect or unexpected events will be shown.
#
# ‘info, 32’
# Show informative messages during processing. This is in addition to warnings and errors. This is the default value.
#
# ‘verbose, 40’
# Same as info, except more verbose.
#
# ‘debug, 48’
# Show everything, including debugging information.
#
# ‘trace, 56’
: "${FFMPEG_LOG_LEVEL:?FFMPEG_LOG_LEVEL is not set}"

: "${STRIMSERVER_SRT_PORT:?STRIMSERVER_SRT_PORT is not set}"
: "${SRT_PACKET_SIZE:?SRT_PACKET_SIZE is not set}"

# Optional: load from Docker secret file if env var not already set
if [ -z "${SRT_PUBLISH_PASSPHRASE:-}" ] && [ -f /run/secrets/srt-passphrase ]; then
  SRT_PUBLISH_PASSPHRASE="$(cat /run/secrets/srt-passphrase)"
  export SRT_PUBLISH_PASSPHRASE
fi

# Fail fast if missing
: "${SRT_PUBLISH_PASSPHRASE:?SRT_PUBLISH_PASSPHRASE is required}"

INGRESS0_PATH="ingress0"
NORMALIZED_PATH="normalized"
SCALED_PATH="scaled"

READ_URL_TEMPLATE="srt://localhost:$STRIMSERVER_SRT_PORT?streamid=read:%s"
PUBLISH_URL_TEMPLATE="srt://localhost:$STRIMSERVER_SRT_PORT?streamid=publish:%s&pkt_size=$SRT_PACKET_SIZE&passphrase=$SRT_PUBLISH_PASSPHRASE"

INGRESS0_READ_URL="$(printf "$READ_URL_TEMPLATE" "$INGRESS0_PATH")"

NORMALIZED_PUBLISH_URL="$(printf "$PUBLISH_URL_TEMPLATE" "$NORMALIZED_PATH")"
NORMALIZED_READ_URL="$(printf "$READ_URL_TEMPLATE" "$NORMALIZED_PATH")"

SCALED_PUBLISH_URL="$(printf "$PUBLISH_URL_TEMPLATE" "$SCALED_PATH")"
SCALED_READ_URL="$(printf "$READ_URL_TEMPLATE" "$SCALED_PATH")"

normalize() {

   : "${SRT_LATENCY_US:?SRT_LATENCY_US is not set}"
   : "${SRT_MAX_BW_BYTES_PER_SEC:?SRT_MAX_BW_BYTES_PER_SEC is not set}"
   : "${SRT_INPUT_BW_BYTES_PER_SEC:?SRT_INPUT_BW_BYTES_PER_SEC is not set}"
   : "${SRT_OVERHEAD_BW_PERCENT:?SRT_OVERHEAD_BW_PERCENT is not set}"

   INPUT_SRT_URL="$(printf "$INGRESS0_READ_URL&latency=%d&tlpktdrop=1&maxbw=%d&inputbw=%d&oheadbw=%d" \
      "$SRT_LATENCY_US" \
      "$SRT_MAX_BW_BYTES_PER_SEC" \
      "$SRT_INPUT_BW_BYTES_PER_SEC" \
      "$SRT_OVERHEAD_BW_PERCENT")"

   OUTPUT_SRT_URL="$NORMALIZED_PUBLISH_URL"

   : "${NORMALIZED_VIDEO_BITRATE:?NORMALIZED_VIDEO_BITRATE is not set}"
   : "${NORMALIZED_AUDIO_BITRATE:?NORMALIZED_AUDIO_BITRATE is not set}"

   exec "$FFMPEG" \
     -loglevel "$FFMPEG_LOG_LEVEL" \
     -fflags +discardcorrupt+genpts \
     -err_detect ignore_err \
     -drop_changed:v 1 \
     -f mpegts \
     -i "$INPUT_SRT_URL" \
     -c:v hevc_nvenc \
     -b:v "$NORMALIZED_VIDEO_BITRATE" \
     -maxrate "$NORMALIZED_VIDEO_BITRATE" \
     -minrate "$NORMALIZED_VIDEO_BITRATE" \
     -bufsize "$NORMALIZED_VIDEO_BITRATE" \
     -preset p1 \
     -tune ll \
     -rc cbr \
     -zerolatency 1 \
     -rc-lookahead 0 \
     -delay 0 \
     -profile:v main \
     -level 5.1 \
     -g 120 \
     -keyint_min 120 \
     -bf 0 \
     -c:a libfdk_aac -b:a "$NORMALIZED_AUDIO_BITRATE" \
     -ar 48000 \
     -ac 2 \
     -flush_packets 1 \
     -max_interleave_delta 100000 \
     -muxdelay 0 \
     -muxpreload 0 \
     -f mpegts \
     "$OUTPUT_SRT_URL"

}


scale() {

   INPUT_SRT_URL="$NORMALIZED_READ_URL"
   OUTPUT_SRT_URL="$SCALED_PUBLISH_URL"

   : "${SCALED_VIDEO_BITRATE:?SCALED_VIDEO_BITRATE is not set}"

   exec "$FFMPEG" \
     -loglevel "$FFMPEG_LOG_LEVEL" \
     -hwaccel cuda \
     -hwaccel_output_format cuda \
     -f mpegts \
     -i "$INPUT_SRT_URL" \
     -vf "scale_cuda=1920:1080:interp_algo=lanczos" \
     -c:v hevc_nvenc \
     -b:v "$SCALED_VIDEO_BITRATE" \
     -maxrate "$SCALED_VIDEO_BITRATE" \
     -minrate "$SCALED_VIDEO_BITRATE" \
     -bufsize "$SCALED_VIDEO_BITRATE" \
     -preset p1 \
     -tune ll \
     -rc cbr \
     -zerolatency 1 \
     -rc-lookahead 0 \
     -delay 0 \
     -profile:v main \
     -level 4.1 \
     -g 120 \
     -keyint_min 120 \
     -bf 0 \
     -c:a copy \
     -flush_packets 1 \
     -max_interleave_delta 100000 \
     -muxdelay 0 \
     -muxpreload 0 \
     -f mpegts \
     "$OUTPUT_SRT_URL"

}


egress() {

   : "${TWITCH_INGEST_SERVER:?TWITCH_INGEST_SERVER is not set (e.g. ingest.global-contribute.live-video.net)}"
   : "${TWITCH_STREAM_KEY:?TWITCH_STREAM_KEY is not set - you should get this from twitch...}"
   : "${EGRESS_VIDEO_BITRATE:?EGRESS_VIDEO_BITRATE is not set}"
   : "${EGRESS_AUDIO_BITRATE:?EGRESS_AUDIO_BITRATE is not set}"
   : "${BANDWIDTH_TEST:?BANDWIDTH_TEST is not set}"
   
   case "${BANDWIDTH_TEST,,}" in
     1|true|yes|y|on)   BW_PARAM="?bandwidthtest=true" ;;
     0|false|no|n|off|"") BW_PARAM="" ;;
     *) echo "Invalid BANDWIDTH_TEST: '$BANDWIDTH_TEST' (use true/false)"; exit 2 ;;
   esac

   INPUT_SRT_URL="$SCALED_READ_URL"
   TWITCH_RTMP_URL="rtmp://${TWITCH_INGEST_SERVER}/app/${TWITCH_STREAM_KEY}${BW_PARAM}"

   exec "$FFMPEG" \
     -loglevel "$FFMPEG_LOG_LEVEL" \
     -hwaccel cuda \
     -hwaccel_output_format cuda \
     -f mpegts \
     -i "$INPUT_SRT_URL" \
     -c:v h264_nvenc \
     -b:v "$EGRESS_VIDEO_BITRATE" \
     -maxrate "$EGRESS_VIDEO_BITRATE" \
     -minrate "$EGRESS_VIDEO_BITRATE" \
     -bufsize "$EGRESS_VIDEO_BITRATE" \
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
     -c:a libfdk_aac -b:a "$EGRESS_AUDIO_BITRATE" \
     -ar 48000 \
     -ac 2 \
     -flvflags no_duration_filesize \
     -flush_packets 1 \
     -f flv \
     "$TWITCH_RTMP_URL"

}


scale_and_egress() {

   : "${TWITCH_INGEST_SERVER:?TWITCH_INGEST_SERVER is not set (e.g. ingest.global-contribute.live-video.net)}"
   : "${TWITCH_STREAM_KEY:?TWITCH_STREAM_KEY is not set - you should get this from twitch...}"
   : "${EGRESS_VIDEO_BITRATE:?EGRESS_VIDEO_BITRATE is not set}"
   : "${EGRESS_AUDIO_BITRATE:?EGRESS_AUDIO_BITRATE is not set}"
   : "${BANDWIDTH_TEST:?BANDWIDTH_TEST is not set}"
   
   case "${BANDWIDTH_TEST,,}" in
     1|true|yes|y|on)   BW_PARAM="?bandwidthtest=true" ;;
     0|false|no|n|off|"") BW_PARAM="" ;;
     *) echo "Invalid BANDWIDTH_TEST: '$BANDWIDTH_TEST' (use true/false)"; exit 2 ;;
   esac

   INPUT_SRT_URL="$NORMALIZED_READ_URL"
   TWITCH_RTMP_URL="rtmp://${TWITCH_INGEST_SERVER}/app/${TWITCH_STREAM_KEY}${BW_PARAM}"

   exec "$FFMPEG" \
     -loglevel "$FFMPEG_LOG_LEVEL" \
     -hwaccel cuda \
     -hwaccel_output_format cuda \
     -f mpegts \
     -i "$INPUT_SRT_URL" \
     -vf "scale_cuda=1920:1080:interp_algo=lanczos" \
     -c:v h264_nvenc \
     -b:v "$EGRESS_VIDEO_BITRATE" \
     -maxrate "$EGRESS_VIDEO_BITRATE" \
     -minrate "$EGRESS_VIDEO_BITRATE" \
     -bufsize "$EGRESS_VIDEO_BITRATE" \
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
     -c:a libfdk_aac -b:a "$EGRESS_AUDIO_BITRATE" \
     -ar 48000 \
     -ac 2 \
     -flvflags no_duration_filesize \
     -flush_packets 1 \
     -f flv \
     "$TWITCH_RTMP_URL"

}



log_prefix() {
  local tag="$1"
  tee -a "/opt/logs/ffmpeg-$tag.log"
  # awk -v tag="$tag" '{ print "[" tag "] " $0; fflush() }'
}
