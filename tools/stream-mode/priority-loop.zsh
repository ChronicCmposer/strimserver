#!/bin/zsh
# priority-loop.zsh — enforce the stream-mode priority policy (plans/stream-mode.md).
#
#   priority-loop.zsh run     loop every $PERIOD s (started by stream-mode on)
#   priority-loop.zsh once    one pass, then exit (testing)
#   priority-loop.zsh revert  undo everything this loop changed, then exit
#
# Idempotent: a process is only touched when its current nice/policy differs from
# the target, and every change is recorded (pid, start time, kind, original
# value) in $RUN_DIR/priority-applied.txt so `revert` restores exactly what was
# changed and nothing else (a reused pid with a different start time is skipped).
# Nothing set by launchd (e.g. the local-encoder's Nice=-10) is ever recorded,
# so it is never reverted either.
STREAM_MODE_DIR=${0:A:h}; SM_NAME=priority-loop
source $STREAM_MODE_DIR/lib.zsh
require_session
APPLIED=$RUN_DIR/priority-applied.txt
PRIO_LOG=$SESSION/priorities.log
SUDO_WARNED=0

already() { [[ -r $APPLIED ]] && grep -q -- "^$1	$2	$3	" $APPLIED }   # pid lstart kind
record()  { print -r -- "$1	$2	$3	$4	$5" >> $APPLIED }            # pid lstart kind comm orig

set_nice() {   # set_nice <pid> <target-nice> <label>
  local pid=$1 target=$2 label=$3 cur ls
  cur=$(ni_of $pid); [[ -n $cur ]] || return 0
  (( cur == target )) && return 0
  ls=$(lstart_of $pid)
  # absolute form: on macOS `renice -n N` is an *increment* (BSD semantics)
  if sudo -n /usr/bin/renice $target -p $pid >/dev/null 2>&1; then
    log "renice $label pid=$pid nice $cur -> $target"
    already $pid "$ls" nice || record $pid "$ls" nice "$label" "$cur"
  elif (( ! SUDO_WARNED )); then
    warn "sudo -n renice failed for $label pid=$pid — is /etc/sudoers.d/stream-mode installed?"
    SUDO_WARNED=1
  fi
}

set_background() {   # set_background <pid> <label>   (own processes: no sudo needed)
  local pid=$1 label=$2 ls
  ls=$(lstart_of $pid); [[ -n $ls ]] || return 0
  already $pid "$ls" bg && return 0
  if taskpolicy -b -p $pid 2>/dev/null; then
    log "background $label pid=$pid (pri now $(pri_of $pid))"
    record $pid "$ls" bg "$label" -
  else
    warn "taskpolicy -b failed for $label pid=$pid"
  fi
}

set_dvs() {   # set_dvs <pid> <daemon>   per DVS_METHOD (outcome of the Phase 3.2 test)
  local pid=$1 label=$2 ls
  case $DVS_METHOD in
    renice) set_nice $pid $DVS_NICE $label ;;
    taskpolicy)
      ls=$(lstart_of $pid); [[ -n $ls ]] || return 0
      already $pid "$ls" dvs-tier && return 0
      if sudo -n /usr/sbin/taskpolicy -t 0 -l 0 -p $pid 2>/dev/null; then
        log "taskpolicy -t 0 -l 0 $label pid=$pid"
        record $pid "$ls" dvs-tier "$label" -
      elif (( ! SUDO_WARNED )); then
        warn "sudo -n taskpolicy failed for $label pid=$pid"; SUDO_WARNED=1
      fi ;;
    *) ;;
  esac
}

snapshot() {   # one line per policy process: ts pid ni pri %cpu comm  (+ DVS thread summary)
  local t=$(ts) name
  ps -axo pid=,ni=,pri=,pcpu=,comm= | awk -v t="$t" '
    $5 ~ /\/(OBS|ffmpeg|Spotify|Obsidian|Parallels Toolbox|Google Chrome|prl_vm_app|Loopback|Stream Deck|Dante Controller)$/ ||
    $5 ~ /DanteVirtualSoundcard\/(dvsd|ptp|conmon_server|apec|dvs_ape)$/ ||
    $5 ~ /\/(coreaudiod|arkaudiod)$/ { n=$5; sub(/.*\//, "", n); print t, $1, $2, $3, $4, n }' >> $PRIO_LOG
  for name in $DVS_DAEMONS dvs_ape; do print -r -- "$t threads $(dvs_pri_summary $name)" >> $PRIO_LOG; done
}

tick() {
  local pid name
  for pid in $(main_pids_of OBS);     do set_nice $pid $OBS_NICE OBS; done
  for pid in $(pgrep -f -- "$FFMPEG_MATCH"); do set_nice $pid $FFMPEG_NICE ffmpeg; done
  for pid in $(main_pids_of Spotify); do set_nice $pid $SPOTIFY_NICE Spotify; done
  for name in $DVS_DAEMONS; do for pid in $(pgrep -x $name); do set_dvs $pid $name; done; done
  for name in $BACKGROUND_APPS; do for pid in $(pgrep -x "$name"); do set_background $pid "$name"; done; done
  snapshot
}

revert() {
  [[ -r $APPLIED ]] || { log "nothing to revert"; return 0 }
  local pid ls kind label orig
  while IFS=$'\t' read -r pid ls kind label orig; do
    kill -0 $pid 2>/dev/null || continue
    [[ "$(lstart_of $pid)" == "$ls" ]] || { warn "pid $pid reused, skipping"; continue }
    case $kind in
      nice)     sudo -n /usr/bin/renice $orig -p $pid >/dev/null 2>&1 && log "revert $label pid=$pid nice -> $orig" || warn "revert renice failed for $label pid=$pid" ;;
      bg)       taskpolicy -B -p $pid 2>/dev/null && log "revert background $label pid=$pid" || warn "taskpolicy -B failed for $label pid=$pid" ;;
      dvs-tier) warn "tiers for $label pid=$pid left as-is (taskpolicy has no unset tier; cleared when DVS restarts)" ;;
    esac
  done < $APPLIED
  mv -f $APPLIED $SESSION/priority-applied.reverted.txt
}

case ${1:-run} in
  once)   tick ;;
  revert) revert ;;
  run)
    install_term_trap
    log "policy: OBS=$OBS_NICE ffmpeg=$FFMPEG_NICE Spotify=$SPOTIFY_NICE DVS=$DVS_METHOD($DVS_NICE) background=(${(j:, :)BACKGROUND_APPS}) period=${PERIOD}s"
    while :; do tick; isleep $PERIOD; done ;;
  *) die "usage: ${0:t} run|once|revert" ;;
esac
