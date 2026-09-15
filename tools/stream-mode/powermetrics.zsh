#!/bin/zsh
# powermetrics.zsh — instrument 1: CPU/GPU power, thermal pressure, per-task
# CPU and per-CPU QoS residency every $PM_INTERVAL_MS ms, plist-formatted
# (one NUL-separated plist per sample) for analyze.py. Runs as root via the
# sudoers.stream-mode rule; stopping it needs the matching `pkill -x` rule.
STREAM_MODE_DIR=${0:A:h}; SM_NAME=powermetrics
source $STREAM_MODE_DIR/lib.zsh
require_session
OUT=$SESSION/powermetrics.plist

cleanup() { sudo -n /usr/bin/pkill -x powermetrics 2>/dev/null }
install_term_trap cleanup
log "powermetrics -i $PM_INTERVAL_MS -s $PM_SAMPLERS → $OUT"
sudo -n /usr/bin/powermetrics -i $PM_INTERVAL_MS -s $PM_SAMPLERS --show-cpu-qos --show-process-qos --format plist >> $OUT 2>>$SESSION/powermetrics.err &
PM_PID=$!
wait $PM_PID
rc=$?
(( rc == 0 )) || warn "powermetrics exited rc=$rc (see powermetrics.err)"
