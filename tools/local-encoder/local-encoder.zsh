#!/bin/zsh
set -euo pipefail
# zsh nices `&` jobs by +5 unless told otherwise; ffmpeg is backgrounded below.
setopt NO_BG_NICE

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
: "${SRT_TIMEOUT_US:?SRT_TIMEOUT_US is not set}"
: "${SRT_MAX_BW_BYTES_PER_SEC:?SRT_MAX_BW_BYTES_PER_SEC is not set}"
: "${SRT_INPUT_BW_BYTES_PER_SEC:?SRT_INPUT_BW_BYTES_PER_SEC is not set}"
: "${SRT_OVERHEAD_BW_PERCENT:?SRT_OVERHEAD_BW_PERCENT is not set}"
: "${SRT_PASSPHRASE:?SRT_PASSPHRASE is not set}"
: "${SRT_PB_KEY_LEN:?SRT_PB_KEY_LEN is not set}"
: "${FFMPEG_CMD:?FFMPEG_CMD is not set}"
: "${FFMPEG_NICE:?FFMPEG_NICE is not set}"
: "${INPUT_SOCKET:?INPUT_SOCKET is not set}"
: "${VIDEO_BITRATE:?VIDEO_BITRATE is not set}"
: "${AUDIO_BITRATE:?AUDIO_BITRATE is not set}"

STRIMSERVER_SRT_URL="$(printf 'srt://%s:%d?mode=caller&streamid=publish:%s&pkt_size=%d&latency=%d&timeout=%d&tlpktdrop=1&maxbw=%d&inputbw=%d&oheadbw=%d&passphrase=%s&pbkeylen=%d' \
	"$STRIMSERVER_HOST" \
	"$STRIMSERVER_SRT_INGEST_PORT" \
	"$SRT_PUBLISH_PATH" \
	"$SRT_PACKET_SIZE" \
	"$SRT_LATENCY_US" \
	"$SRT_TIMEOUT_US" \
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
  # -color_range tv \
  # -colorspace bt709 \
  # -color_primaries bt709 \
  # -color_trc bt709 \
  # -analyzeduration 0 \
  # -max_delay 0 \
  # -flush_packets 1 \
  # -muxdelay 0 \
  # -muxpreload 0 \
  # -max_interleave_delta 0 \
  # -forced-idr 1 \
  # -fflags nobuffer \
  # -avioflags direct \
  # -probesize 32768 \
  # -keyint_min 120 \
  # -force_key_frames "expr:gte(t,n_forced*4)" \

rm -f "$INPUT_SOCKET"

# ffmpeg runs as this user (root must never create $INPUT_SOCKET, or OBS can't
# connect), in the background so FFMPEG_NICE can be applied to it afterwards.
"$FFMPEG_CMD" \
  -fflags +nobuffer \
  -flags low_delay \
  -analyzeduration 0 \
  -probesize 32 \
  -thread_queue_size 16 \
  -listen 1 \
  -i "unix://$INPUT_SOCKET" \
  -c:v copy \
  -c:a copy \
  -max_interleave_delta 0 \
  -flush_packets 1 \
  -avioflags direct \
  -f mpegts \
  "$STRIMSERVER_SRT_URL" &
ffmpeg_pid=$!

# Apply FFMPEG_NICE. Under the LaunchDaemon (Nice=-10 in the plist) ffmpeg already
# inherits it and this is a no-op; when started by hand the renice needs the
# NOPASSWD rule from tools/stream-mode/sudoers.stream-mode. A failure is fatal:
# FFMPEG_NICE is a requirement, not a hint.
current_nice=$(ps -o ni= -p "$ffmpeg_pid" | tr -d ' ')
if [[ -n "$current_nice" && "$current_nice" != "$FFMPEG_NICE" ]]; then
  if ! sudo -n /usr/bin/renice "$FFMPEG_NICE" -p "$ffmpeg_pid" >/dev/null; then
    print -u2 "local-encoder: cannot renice ffmpeg (pid $ffmpeg_pid) from $current_nice to $FFMPEG_NICE; install tools/stream-mode/sudoers.stream-mode"
    kill -TERM "$ffmpeg_pid" 2>/dev/null || true
    wait "$ffmpeg_pid" || true
    exit 1
  fi
fi
print -u2 "local-encoder: ffmpeg pid $ffmpeg_pid nice $(ps -o ni= -p "$ffmpeg_pid" | tr -d ' ')"

# Forward INT/TERM (launchctl kill, Ctrl-C) to ffmpeg, then reap it.
trap 'kill -TERM "$ffmpeg_pid" 2>/dev/null' TERM
trap 'kill -INT "$ffmpeg_pid" 2>/dev/null' INT
rc=0
wait "$ffmpeg_pid" || rc=$?
while kill -0 "$ffmpeg_pid" 2>/dev/null; do wait "$ffmpeg_pid" || rc=$?; done
exit $rc

