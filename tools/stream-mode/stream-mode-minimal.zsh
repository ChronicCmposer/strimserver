#!/bin/zsh
# stream-mode-minimal.zsh — minimal on/off wrapper around priority-loop.zsh.
#
#   stream-mode-minimal.zsh on|start   activate a session and start the priority loop
#   stream-mode-minimal.zsh off|stop   stop the priority loop and revert its changes
#
# Intentionally tiny: no preflight, no instruments, no snapshots, no analysis — that
# is the full stream-mode.zsh's job. Shares lib.zsh, stream-mode.conf, the
# ~/stream-logs session layout, and the ~/stream-logs/.run pidfiles with
# priority-loop.zsh, so the minimal and full scripts can be used interchangeably.
STREAM_MODE_DIR=${0:A:h}; SM_NAME=stream-mode-minimal
source $STREAM_MODE_DIR/lib.zsh

# Session the priority loop logs into (it dies without one): same layout as the full
# script — ~/stream-logs/<date>, or <date>-<HHMM> if today already has a session,
# with ~/stream-logs/current symlinked to it.
new_session() {
  SESSION=$STREAM_LOG_ROOT/$(date +%F)
  [[ -e $SESSION ]] && SESSION=$SESSION-$(date +%H%M)
  mkdir -p $SESSION $RUN_DIR
  ln -sfn $SESSION $STREAM_LOG_ROOT/current
}

cmd_on() {
  [[ $# -eq 0 ]] || die "usage: ${0:t} on|start (no options)"
  if SESSION=$(session_dir) && job_alive priority-loop; then
    die "already on (session $SESSION) — run 'off' first"
  fi
  SESSION=$(session_dir) || new_session
  mkdir -p $RUN_DIR
  start_job priority-loop $STREAM_MODE_DIR/priority-loop.zsh run
  job_alive priority-loop || die "priority loop failed to start — check $SESSION/priority-loop.out"
  log "on: priority loop running (session $SESSION)"
}

cmd_off() {
  [[ $# -eq 0 ]] || die "usage: ${0:t} off|stop (no options)"
  require_session
  stop_job priority-loop
  $STREAM_MODE_DIR/priority-loop.zsh revert
  log "off: priority loop stopped, priorities reverted (session $SESSION)"
}

case ${1:-} in
  on|start) shift; cmd_on "$@" ;;
  off|stop) shift; cmd_off "$@" ;;
  *) die "usage: ${0:t} on|start|off|stop" ;;
esac