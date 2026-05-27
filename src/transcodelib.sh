#!/usr/bin/env bash

set -xeuo pipefail
FFMPEG="/usr/local/bin/ffmpeg"

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

: "${STRIMSERVER_RTSP_PORT:?STRIMSERVER_RTSP_PORT is not set}"

# Fail fast if missing
: "${NORMALIZED_MPEGTS_SOCKET:?NORMALIZED_MPEGTS_SOCKET is required}"


INGRESS0_PATH="ingress0"
NORMALIZED_PATH="normalized"
# SCALED_PATH="scaled"

RTSP_READ_URL_TEMPLATE="rtsp://localhost:$STRIMSERVER_RTSP_PORT/%s"

INGRESS0_READ_URL="$(printf "$RTSP_READ_URL_TEMPLATE" "$INGRESS0_PATH")"

NORMALIZED_PUBLISH_URL="unix:$NORMALIZED_MPEGTS_SOCKET"
NORMALIZED_READ_URL="$(printf "$RTSP_READ_URL_TEMPLATE" "$NORMALIZED_PATH")"

# SCALED_PUBLISH_URL="unix:$SCALED_MPEGTS_SOCKET"
# SCALED_READ_URL="$(printf "$RTSP_READ_URL_TEMPLATE" "$SCALED_PATH")"

normalize() {

   INPUT_RTSP_URL="$INGRESS0_READ_URL"

   OUTPUT_SOCKET_URL="$NORMALIZED_PUBLISH_URL"

   : "${NORMALIZED_VIDEO_BITRATE:?NORMALIZED_VIDEO_BITRATE is not set}"
   : "${NORMALIZED_VIDEO_MAXRATE:?NORMALIZED_VIDEO_MAXRATE is not set}"
   : "${NORMALIZED_VIDEO_MINRATE:?NORMALIZED_VIDEO_MINRATE is not set}"
   : "${NORMALIZED_VIDEO_BUFSIZE:?NORMALIZED_VIDEO_BUFSIZE is not set}"
   : "${NORMALIZED_AUDIO_BITRATE:?NORMALIZED_AUDIO_BITRATE is not set}"


   exec "$FFMPEG" \
     -loglevel "$FFMPEG_LOG_LEVEL" \
     -err_detect ignore_err \
     -fflags +nobuffer+discardcorrupt+genpts \
     -flags low_delay+output_corrupt \
     -analyzeduration 0 \
     -probesize 32 \
     -thread_queue_size 16 \
     -flags2 +showall \
     -rtsp_transport tcp \
     -i "$INPUT_RTSP_URL" \
     -vf "fps=60,setpts=N/(60*TB),format=p010le" \
     -r 60 \
     -fps_mode:v cfr \
     -c:v hevc_nvenc \
     -pix_fmt p010le \
     -b:v "$NORMALIZED_VIDEO_BITRATE" \
     -maxrate "$NORMALIZED_VIDEO_MAXRATE" \
     -minrate "$NORMALIZED_VIDEO_MINRATE" \
     -bufsize "$NORMALIZED_VIDEO_BUFSIZE" \
     -preset p4 \
     -tune ull \
     -rc cbr \
     -zerolatency 1 \
     -delay 0 \
     -rc-lookahead 0 \
     -profile:v main10 \
     -g 120 \
     -bf 0 \
     -multipass qres \
     -spatial-aq 1 -aq-strength 8 \
     -temporal-aq 1 \
     -c:a libfdk_aac -b:a "$NORMALIZED_AUDIO_BITRATE" \
     -ar 48000 \
     -ac 2 \
     -flush_packets 1 \
     -avioflags direct \
     -f mpegts \
     "$OUTPUT_SOCKET_URL"

}


# scale() {
#
#    INPUT_SRT_URL="$NORMALIZED_READ_URL"
#    OUTPUT_SRT_URL="$SCALED_PUBLISH_URL"
#
#    : "${SCALED_VIDEO_BITRATE:?SCALED_VIDEO_BITRATE is not set}"
#    : "${SCALED_VIDEO_MAXRATE:?SCALED_VIDEO_MAXRATE is not set}"
#    : "${SCALED_VIDEO_MINRATE:?SCALED_VIDEO_MINRATE is not set}"
#    : "${SCALED_VIDEO_BUFSIZE:?SCALED_VIDEO_BUFSIZE is not set}"
#
#    exec "$FFMPEG" \
#      -loglevel "$FFMPEG_LOG_LEVEL" \
#      -hwaccel cuda \
#      -hwaccel_output_format cuda \
#      -f mpegts \
#      -i "$INPUT_SRT_URL" \
#      -vf "scale_cuda=1920:1080:interp_algo=lanczos" \
#      -c:v hevc_nvenc \
#      -b:v "$SCALED_VIDEO_BITRATE" \
#      -maxrate "$SCALED_VIDEO_MAXRATE" \
#      -minrate "$SCALED_VIDEO_MINRATE" \
#      -bufsize "$SCALED_VIDEO_BUFSIZE" \
#      -preset p3 \
#      -tune ll \
#      -rc cbr \
#      -zerolatency 1 \
#      -rc-lookahead 0 \
#      -delay 0 \
#      -profile:v main \
#      -level 4.1 \
#      -g 120 \
#      -bf 0 \
#      -c:a copy \
#      -f mpegts \
#      "$OUTPUT_SRT_URL"
#
#      # -flush_packets 1 \
#      # -max_interleave_delta 100000 \
#      # -muxdelay 0 \
#      # -muxpreload 0 \
#
# }


# egress() {
#
#    : "${TWITCH_INGEST_SERVER:?TWITCH_INGEST_SERVER is not set (e.g. ingest.global-contribute.live-video.net)}"
#    : "${TWITCH_STREAM_KEY:?TWITCH_STREAM_KEY is not set - you should get this from twitch...}"
#    : "${BANDWIDTH_TEST:?BANDWIDTH_TEST is not set}"
#
#    case "${BANDWIDTH_TEST,,}" in
#      1|true|yes|y|on)   BW_PARAM="?bandwidthtest=true" ;;
#      0|false|no|n|off|"") BW_PARAM="" ;;
#      *) echo "Invalid BANDWIDTH_TEST: '$BANDWIDTH_TEST' (use true/false)"; exit 2 ;;
#    esac
#
#    INPUT_SRT_URL="$SCALED_READ_URL"
#    TWITCH_RTMP_URL="rtmp://${TWITCH_INGEST_SERVER}/app/${TWITCH_STREAM_KEY}${BW_PARAM}"
#
#    : "${EGRESS_VIDEO_BITRATE:?EGRESS_VIDEO_BITRATE is not set}"
#    : "${EGRESS_VIDEO_MAXRATE:?EGRESS_VIDEO_MAXRATE is not set}"
#    : "${EGRESS_VIDEO_MINRATE:?EGRESS_VIDEO_MINRATE is not set}"
#    : "${EGRESS_VIDEO_BUFSIZE:?EGRESS_VIDEO_BUFSIZE is not set}"
#    : "${EGRESS_AUDIO_BITRATE:?EGRESS_AUDIO_BITRATE is not set}"
#
#    exec "$FFMPEG" \
#      -loglevel "$FFMPEG_LOG_LEVEL" \
#      -err_detect ignore_err \
#      -flags +output_corrupt \
#      -hwaccel cuda \
#      -hwaccel_output_format cuda \
#      -f mpegts \
#      -i "$INPUT_SRT_URL" \
#      -c:v h264_nvenc \
#      -b:v "$EGRESS_VIDEO_BITRATE" \
#      -maxrate "$EGRESS_VIDEO_MAXRATE" \
#      -minrate "$EGRESS_VIDEO_MINRATE" \
#      -bufsize "$EGRESS_VIDEO_BUFSIZE" \
#      -preset p3 \
#      -tune ll \
#      -rc cbr \
#      -zerolatency 1 \
#      -rc-lookahead 0 \
#      -delay 0 \
#      -profile:v high \
#      -level 4.2 \
#      -g 120 \
#      -bf 0 \
#      -c:a libfdk_aac -b:a "$EGRESS_AUDIO_BITRATE" \
#      -ar 48000 \
#      -ac 2 \
#      -flvflags no_duration_filesize \
#      -f flv \
#      "$TWITCH_RTMP_URL"
#
#      # -flush_packets 1 \
#
# }


scale_and_egress() {

   : "${TWITCH_INGEST_SERVER:?TWITCH_INGEST_SERVER is not set (e.g. ingest.global-contribute.live-video.net)}"
   : "${TWITCH_STREAM_KEY:?TWITCH_STREAM_KEY is not set - you should get this from twitch...}"
   : "${BANDWIDTH_TEST:?BANDWIDTH_TEST is not set}"
   
   case "${BANDWIDTH_TEST,,}" in
     1|true|yes|y|on)   BW_PARAM="?bandwidthtest=true" ;;
     0|false|no|n|off|"") BW_PARAM="" ;;
     *) echo "Invalid BANDWIDTH_TEST: '$BANDWIDTH_TEST' (use true/false)"; exit 2 ;;
   esac

   INPUT_RTSP_URL="$NORMALIZED_READ_URL"
   TWITCH_RTMP_URL="rtmp://${TWITCH_INGEST_SERVER}/app/${TWITCH_STREAM_KEY}${BW_PARAM}"

   : "${SCALED_VIDEO_HEIGHT_PIXELS:?SCALED_VIDEO_HEIGHT_PIXELS is not set}"

   : "${EGRESS_VIDEO_BITRATE:?EGRESS_VIDEO_BITRATE is not set}"
   : "${EGRESS_VIDEO_MAXRATE:?EGRESS_VIDEO_MAXRATE is not set}"
   : "${EGRESS_VIDEO_MINRATE:?EGRESS_VIDEO_MINRATE is not set}"
   : "${EGRESS_VIDEO_BUFSIZE:?EGRESS_VIDEO_BUFSIZE is not set}"
   : "${EGRESS_AUDIO_BITRATE:?EGRESS_AUDIO_BITRATE is not set}"

   VIDEO_FILTER="\
   scale_cuda=-2:${SCALED_VIDEO_HEIGHT_PIXELS}:format=nv12:interp_algo=bicubic,\
   fps=60,setpts=N/(60*TB),\
   "
   exec "$FFMPEG" \
     -loglevel "$FFMPEG_LOG_LEVEL" \
     -err_detect ignore_err \
     -fflags +nobuffer \
     -flags low_delay \
     -analyzeduration 0 \
     -probesize 32 \
     -thread_queue_size 16 \
     -flags2 +showall \
     -hwaccel cuda \
     -hwaccel_output_format cuda \
     -rtsp_transport tcp \
     -i "$INPUT_RTSP_URL" \
     -vf "$VIDEO_FILTER" \
     -r 60 \
     -fps_mode:v cfr \
     -c:v h264_nvenc \
     -b:v "$EGRESS_VIDEO_BITRATE" \
     -maxrate "$EGRESS_VIDEO_MAXRATE" \
     -minrate "$EGRESS_VIDEO_MINRATE" \
     -bufsize "$EGRESS_VIDEO_BUFSIZE" \
     -preset p5 \
     -tune ull \
     -rc cbr \
     -zerolatency 1 \
     -delay 0 \
     -rc-lookahead 0 \
     -profile:v high \
     -g 120 \
     -bf 0 \
     -multipass qres \
     -spatial-aq 1 -aq-strength 8 \
     -temporal-aq 1 \
     -c:a libfdk_aac -b:a "$EGRESS_AUDIO_BITRATE" \
     -ar 48000 \
     -ac 2 \
     -flvflags no_duration_filesize \
     -flush_packets 1 \
     -avioflags direct \
     -f flv \
     "$TWITCH_RTMP_URL"

}


# normalize_scale_and_egress() {
#
#    : "${SRT_LATENCY_US:?SRT_LATENCY_US is not set}"
#    : "${SRT_MAX_BW_BYTES_PER_SEC:?SRT_MAX_BW_BYTES_PER_SEC is not set}"
#    : "${SRT_INPUT_BW_BYTES_PER_SEC:?SRT_INPUT_BW_BYTES_PER_SEC is not set}"
#    : "${SRT_OVERHEAD_BW_PERCENT:?SRT_OVERHEAD_BW_PERCENT is not set}"
#
#    : "${TWITCH_INGEST_SERVER:?TWITCH_INGEST_SERVER is not set (e.g. ingest.global-contribute.live-video.net)}"
#    : "${TWITCH_STREAM_KEY:?TWITCH_STREAM_KEY is not set - you should get this from twitch...}"
#    : "${BANDWIDTH_TEST:?BANDWIDTH_TEST is not set}"
#
#    case "${BANDWIDTH_TEST,,}" in
#      1|true|yes|y|on)   BW_PARAM="?bandwidthtest=true" ;;
#      0|false|no|n|off|"") BW_PARAM="" ;;
#      *) echo "Invalid BANDWIDTH_TEST: '$BANDWIDTH_TEST' (use true/false)"; exit 2 ;;
#    esac
#
#
#    INPUT_SRT_URL="$(printf "$INGRESS0_READ_URL&latency=%d&tlpktdrop=1&maxbw=%d&inputbw=%d&oheadbw=%d" \
#       "$SRT_LATENCY_US" \
#       "$SRT_MAX_BW_BYTES_PER_SEC" \
#       "$SRT_INPUT_BW_BYTES_PER_SEC" \
#       "$SRT_OVERHEAD_BW_PERCENT")"
#
#    TWITCH_RTMP_URL="rtmp://${TWITCH_INGEST_SERVER}/app/${TWITCH_STREAM_KEY}${BW_PARAM}"
#
#    : "${EGRESS_VIDEO_BITRATE:?EGRESS_VIDEO_BITRATE is not set}"
#    : "${EGRESS_VIDEO_MAXRATE:?EGRESS_VIDEO_MAXRATE is not set}"
#    : "${EGRESS_VIDEO_MINRATE:?EGRESS_VIDEO_MINRATE is not set}"
#    : "${EGRESS_VIDEO_BUFSIZE:?EGRESS_VIDEO_BUFSIZE is not set}"
#    : "${EGRESS_AUDIO_BITRATE:?EGRESS_AUDIO_BITRATE is not set}"
#
#    exec "$FFMPEG" \
#      -loglevel "$FFMPEG_LOG_LEVEL" \
#      -fflags +discardcorrupt+genpts \
#      -err_detect ignore_err \
#      -drop_changed:v 1 \
#      -f mpegts \
#      -i "$INPUT_SRT_URL" \
#      -vf "scale_cuda=1920:1080:interp_algo=lanczos" \
#      -c:v h264_nvenc \
#      -b:v "$EGRESS_VIDEO_BITRATE" \
#      -maxrate "$EGRESS_VIDEO_MAXRATE" \
#      -minrate "$EGRESS_VIDEO_MINRATE" \
#      -bufsize "$EGRESS_VIDEO_BUFSIZE" \
#      -preset p4 \
#      -tune ll \
#      -rc cbr \
#      -zerolatency 1 \
#      -rc-lookahead 0 \
#      -delay 0 \
#      -profile:v high \
#      -level 4.2 \
#      -g 120 \
#      -bf 0 \
#      -c:a libfdk_aac -b:a "$EGRESS_AUDIO_BITRATE" \
#      -ar 48000 \
#      -ac 2 \
#      -flvflags no_duration_filesize \
#      -f flv \
#      "$TWITCH_RTMP_URL"
#
# }



log_prefix() {
  local tag="$1"
  tee -a "/opt/logs/ffmpeg-$tag.log"
}
