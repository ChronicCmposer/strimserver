#!/bin/zsh
set -euo pipefail

: "${LOCAL_ENCODER_ENV:?LOCAL_ENCODER_ENV is not set}"

set -a
. $LOCAL_ENCODER_ENV
set +a

# Required
: "${STRIMSERVER_HOST:?STRIMSERVER_HOST is not set}"
: "${STRIMSERVER_SRT_INGEST_PORT:?STRIMSERVER_SRT_INGEST_PORT is not set}"
: "${SRT_PUBLISH_PATH:?SRT_PUBLISH_PATH is not set}"
: "${SRT_PACKET_SIZE:?SRT_PACKET_SIZE is not set}"
: "${SRT_LATENCY_US:?SRT_LATENCY_US is not set}"
: "${SRT_MAX_BW_BYTES_PER_SEC:?SRT_MAX_BW_BYTES_PER_SEC is not set}"
: "${SRT_INPUT_BW_BYTES_PER_SEC:?SRT_INPUT_BW_BYTES_PER_SEC is not set}"
: "${SRT_OVERHEAD_BW_PERCENT:?SRT_OVERHEAD_BW_PERCENT is not set}"
: "${SRT_PASSPHRASE:?SRT_PASSPHRASE is not set}"
: "${SRT_PB_KEY_LEN:?SRT_PB_KEY_LEN is not set}"
: "${FFMPEG_CMD:?FFMPEG_CMD is not set}"
: "${INPUT_FIFO:?INPUT_FIFO is not set}"
: "${VIDEO_BITRATE:?VIDEO_BITRATE is not set}"
: "${AUDIO_BITRATE:?AUDIO_BITRATE is not set}"

STRIMSERVER_SRT_URL="$(printf 'srt://%s:%d?streamid=publish:%s&pkt_size=%d&latency=%d&maxbw=%d&inputbw=%d&oheadbw=%d&passphrase=%s&pbkeylen=%d' \
	"$STRIMSERVER_HOST" \
	"$STRIMSERVER_SRT_INGEST_PORT" \
	"$SRT_PUBLISH_PATH" \
	"$SRT_PACKET_SIZE" \
	"$SRT_LATENCY_US" \
	"$SRT_MAX_BW_BYTES_PER_SEC" \
	"$SRT_INPUT_BW_BYTES_PER_SEC" \
	"$SRT_OVERHEAD_BW_PERCENT" \
	"$SRT_PASSPHRASE" \
	"$SRT_PB_KEY_LEN")"


# profile 77 = main
# level 42 = 4.2
# coder 2 = CABAC - Context-Adaptive Binary Arithmetic Coding
# It's unclear whether -bufsize:v is useful for h264_videotoolbox
# It's clear that -constant_bit_rate true must be set to force the encoder to
# actually hit the target rate instead of using a lower rate as it sees fit
# It's clear that -maxrate:v does not work as expected for h264_videotoolbox
  # -realtime true \
  # -flags +low_delay \
  # -maxrate "$VIDEO_BITRATE" \
# It's clear that we need to control for bitrate overshoot with h264_videotoolbox
  # -vf "scale=iw/2:ih/2:flags=lanczos" \
  # -loglevel verbose \

exec "$FFMPEG_CMD" \
  -init_hw_device videotoolbox=vt -filter_hw_device vt \
  -color_range pc \
  -colorspace bt709 \
  -color_primaries bt709 \
  -color_trc bt709 \
  -i "$INPUT_FIFO" \
  -vf "format=nv12,hwupload,scale_vt=w=1920:h=-2,hwdownload,format=nv12" \
  -c:v hevc_videotoolbox \
  -b:v "9M" \
  -profile:v 1 \
  -g 120 \
  -keyint_min 120 \
  -bf 0 \
  -constant_bit_rate true \
  -color_range tv \
  -colorspace bt709 \
  -color_primaries bt709 \
  -color_trc bt709 \
  -c:a aac_at \
  -b:a "$AUDIO_BITRATE" \
  -aac_at_mode 0 \
  -ar 48000 \
  -ac 2 \
  -f mpegts \
  "$STRIMSERVER_SRT_URL" 


