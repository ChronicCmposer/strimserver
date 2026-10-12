#!/bin/zsh
# route-monitor.zsh — instrument 8 (round 2, Q8): every routing-socket message
# (`route -n monitor`) with its timestamp, type and address → route-monitor.log.
#
# The DVS control plane re-scans the whole network stack on every routing
# message (RTM_MISS for an unroutable lookup, RTM_IFINFO/RTM_NEWADDR for an
# interface change …). Round 1 found the Chromium IPv6 probe this way; the
# remaining re-scan bursts (10–22/min at no VM event, 6/min hourly at :35) need
# the same evidence. Kernel-generated misses carry pid 0, so the log names the
# probe *address*, not the process. No root needed; ~100 bytes per message.
# analyze.py joins the messages to the dvs-rescan bursts.
STREAM_MODE_DIR=${0:A:h}; SM_NAME=route-monitor
source $STREAM_MODE_DIR/lib.zsh
require_session
OUT=$SESSION/route-monitor.log

log "route -n monitor → $OUT"
exec /sbin/route -n monitor >> $OUT 2>&1
