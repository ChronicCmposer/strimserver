#!/bin/zsh
# stall-watch.zsh — instrument 6: follow the DVS daemon logs and the live
# unified-log capture; timestamp every DVS event into dvs-events.log, and on a
# stall signature (DVS "new maximum processing time" / keepalive / timed out,
# a coreaudiod HAL overload, or a re-scan burst: ≥ $RESCAN_BURST_N dvsd
# INTERFACE_CHANGE lines within $RESCAN_BURST_WINDOW s) take a spindump of the
# DVS daemons — only for the triggers in $SPINDUMP_TRIGGERS, rate-limited to one
# per $SPINDUMP_MIN_INTERVAL s and $SPINDUMP_MAX per session. The burst trigger
# exists to catch what fires a re-scan storm that is *not* a VM bridge cycle
# (round 2, H1 alternative). Why the spindump is targeted and background-band,
# and why a HAL overload no longer triggers one: see the conf (observer effect).
#
# With DVS debug logging on (timestampLogs), every daemon start opens a fresh
# <daemon>_<epoch>.log instead of rotating <daemon>.log, so the set of live files
# changes exactly when a daemon (re)starts — the moment we care about most. The
# watcher re-resolves the newest file per daemon every $RESCAN s, and when the set
# changes it replays what the new files already hold and restarts its tail.
STREAM_MODE_DIR=${0:A:h}; SM_NAME=stall-watch
source $STREAM_MODE_DIR/lib.zsh
require_session
EVENTS=$SESSION/dvs-events.log
LAST_SPIN=0; SPIN_COUNT=0; RESCAN=5
DVS_DAEMON_LOGS=(dvs_manager conmon_server apec ptp dvs_ape)
: ${RESCAN_BURST_N:=15} ${RESCAN_BURST_WINDOW:=30}
RESCAN_TS=()   # $EPOCHSECONDS of the recent INTERFACE_CHANGE lines (sliding window)
REPLAY=0       # 1 while re-reading a fresh daemon log from the top: those lines are history, not a burst

maybe_spindump() {   # maybe_spindump <trigger>
  local trig=$1 now=$EPOCHSECONDS f
  (( ${SPINDUMP_TRIGGERS[(Ie)$trig]} )) || return 0   # not a spindump trigger (see the conf: observer effect)
  (( now - LAST_SPIN >= SPINDUMP_MIN_INTERVAL )) || return 0
  (( SPIN_COUNT < SPINDUMP_MAX )) || { (( SPIN_COUNT == SPINDUMP_MAX )) && { warn "spindump cap ($SPINDUMP_MAX) reached"; (( SPIN_COUNT++ )) }; return 0 }
  LAST_SPIN=$now; (( SPIN_COUNT++ ))
  f=$SESSION/spindump-$(date +%Y%m%dT%H%M%S)-$trig.txt
  # sampling takes $SPINDUMP_SECONDS s plus symbolication; don't block the watcher. Targeted
  # (only the DVS daemons) and in the background band, so it cannot become the next overload.
  local -a args
  if (( $#SPINDUMP_TARGETS )); then
    args=($SPINDUMP_TARGETS[1] $SPINDUMP_SECONDS -onlyTarget); local p; for p in ${SPINDUMP_TARGETS[2,-1]}; do args+=(-proc $p); done
  else
    args=(-notarget $SPINDUMP_SECONDS)
  fi
  sudo -n /usr/sbin/taskpolicy -b /usr/sbin/spindump $args -file $f >/dev/null 2>>$SESSION/spindump.err &!
  print -r -- "$(ts)	spindump	$trig	$f" >> $EVENTS
  log "spindump ($trig: ${(j: :)args}) → ${f:t}"
}

note_rescan() {   # note_rescan <src>: one INTERFACE_CHANGE seen now; a burst logs one event and spindumps
  (( REPLAY )) && return 0
  local now=$EPOCHSECONDS
  RESCAN_TS+=($now)
  while (( $#RESCAN_TS && now - RESCAN_TS[1] > RESCAN_BURST_WINDOW )); do RESCAN_TS[1]=(); done
  (( $#RESCAN_TS >= RESCAN_BURST_N )) || return 0
  print -r -- "$(ts)	dvs-rescan-burst	$1	$#RESCAN_TS INTERFACE_CHANGE within ${RESCAN_BURST_WINDOW}s" >> $EVENTS
  log "re-scan burst: $#RESCAN_TS INTERFACE_CHANGE within ${RESCAN_BURST_WINDOW}s"
  RESCAN_TS=()   # the next burst needs $RESCAN_BURST_N fresh re-scans
  maybe_spindump dvs-rescan
}

handle() {   # handle <src-basename> <line>
  local src=$1 line=$2 kind= trig=
  [[ -n $line ]] || return 0
  if [[ $src == unified-log.ndjson ]]; then
    [[ $line == *HALS_OverloadMessage* || $line == *"Audio IO Overload"* ]] || return 0
    kind=hal
    [[ $line == *"client timeout"* || $line == *"Audio IO Overload"* ]] && trig=hal
  else
    case $line in
      *"event INTERFACE_CHANGE"*) note_rescan $src; return 0 ;;
      *"new maximum processing time"*|*keepalive*|*"timed out"*) kind=dvs-stall; trig=dvs ;;
      *terminateProcess*|*spawnProcess:starting*|*" Error "*|*"Error:"*|*"Critical "*) kind=dvs-event ;;
      *) return 0 ;;
    esac
  fi
  print -r -- "$(ts)	$kind	$src	$line" >> $EVENTS
  [[ -n $trig ]] && maybe_spindump $trig
}

# The newest live log per daemon — <name>.log or <name>_<epoch>.log, whichever was
# modified last — plus the unified-log capture.
live_files() {
  local n; local -a f
  for n in $DVS_DAEMON_LOGS; do
    f=( $DVS_LOG_DIR/${n}(|_<->).log(Nom[1]) ); (( $#f )) && print -r -- $f[1]
  done
  print -r -- $SESSION/unified-log.ndjson
}

FILES=(); TAIL_FD=; TAIL_PID=; typeset -A SEEN
open_tail() {   # open_tail <file>...
  FILES=( "$@" ); local f; for f in $FILES; do SEEN[$f]=1; done
  exec {TAIL_FD}< <(tail -F -n0 $FILES 2>/dev/null)
  TAIL_PID=$(pgrep -n -P $$ -x tail)   # zsh does not set $! for <(...)
  log "watching: ${(j: :)${(@)FILES:t}}"
}
close_tail() {
  [[ -n $TAIL_FD ]] && exec {TAIL_FD}<&-
  [[ -n $TAIL_PID ]] && kill $TAIL_PID 2>/dev/null
  TAIL_FD=; TAIL_PID=
}
cleanup() { close_tail }
install_term_trap cleanup

open_tail $(live_files)
src=; line=; next_scan=$(( EPOCHSECONDS + RESCAN ))
while :; do
  if read -t 1 -r -u $TAIL_FD line; then
    if [[ $line == '==> '*' <==' ]]; then src=${${line#==> }% <==}; src=${src:t}
    else handle "$src" "$line"; fi
  elif [[ -z $TAIL_PID ]] || ! kill -0 $TAIL_PID 2>/dev/null; then
    warn "tail exited; reopening"; close_tail; open_tail $(live_files); src=
  fi
  (( EPOCHSECONDS >= next_scan )) || continue
  next_scan=$(( EPOCHSECONDS + RESCAN ))
  new=( $(live_files) )
  [[ "${(j:|:)new}" == "${(j:|:)FILES}" ]] && continue
  added=( ${new:|FILES} )
  log "DVS log set changed, new: ${(j: :)${(@)added:t}}"
  deadline=$(( EPOCHSECONDS + 2 ))   # drain what the old tail still has (it polls about once a second)
  while (( EPOCHSECONDS < deadline )) && read -t 1 -r -u $TAIL_FD line; do
    if [[ $line == '==> '*' <==' ]]; then src=${${line#==> }% <==}; src=${src:t}; else handle "$src" "$line"; fi
  done
  close_tail
  REPLAY=1
  for f in $added; do   # a fresh daemon has already written its banner and first events
    [[ -r $f && -z ${SEEN[$f]} ]] || continue
    while IFS= read -r line; do handle ${f:t} "$line"; done < $f
  done
  REPLAY=0
  open_tail $new; src=
done
