#!/bin/zsh
# unified-log.zsh — instrument 4: live unified-log capture (ndjson) of the
# mechanisms under test: coreaudiod HAL overloads / client timeouts, kernel
# memorystatus + jetsam, the Dante NIC (en7) and USB, thermalmonitord, arkaudiod.
# Two kernel lines are pure noise and excluded: "priorityCalculationInputs … en7"
# (every ~2 s) and "ApplePPMPolicyCPMS::setDetailedThermalPowerBudget" (654 per
# night; a power-budget notice, not thermal pressure). The bridge lines
# ("enN: promiscuous mode enable/disable", "bridge_set_lro") mark Parallels VM
# start/stop on a bridged NIC. /usr/bin/log is spelled out because `log` is a
# zsh builtin.
STREAM_MODE_DIR=${0:A:h}; SM_NAME=unified-log
source $STREAM_MODE_DIR/lib.zsh
require_session
OUT=$SESSION/unified-log.ndjson

PREDICATE='
  (process == "coreaudiod" AND (eventMessage CONTAINS[c] "overload" OR eventMessage CONTAINS[c] "timeout" OR eventMessage CONTAINS[c] "timed out"))
  OR (process == "kernel"
      AND NOT eventMessage CONTAINS "dirty-tracking"
      AND NOT eventMessage CONTAINS "jetsam_snapshot_entry_locked"
      AND NOT eventMessage CONTAINS "flow_entry_alloc"
      AND NOT eventMessage CONTAINS "AppleUSBHostUserClient"
      AND NOT eventMessage CONTAINS "priorityCalculationInputs"
      AND NOT eventMessage CONTAINS "_connection_summary"
      AND NOT eventMessage BEGINSWITH "tcp "
      AND NOT eventMessage CONTAINS "ISP_deInit"
      AND NOT eventMessage CONTAINS "HIDDevice"
      AND NOT eventMessage CONTAINS "TrustedAccessoryAnalytics"
      AND NOT eventMessage CONTAINS "ANE_"
      AND NOT eventMessage CONTAINS "setDetailedThermalPowerBudget"
      AND (eventMessage CONTAINS[c] "memorystatus" OR eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "thermal"
           OR eventMessage CONTAINS "promiscuous" OR eventMessage CONTAINS "bridge_set_lro"
           OR eventMessage CONTAINS "en7" OR eventMessage CONTAINS "en8" OR eventMessage CONTAINS[c] "AppleUSB" OR eventMessage CONTAINS[c] "usb"))
  OR (process == "thermalmonitord" AND NOT eventMessage BEGINSWITH "Failed to")
  OR process == "arkaudiod"
'
log "log stream → $OUT"
exec /usr/bin/log stream --style ndjson --predicate "$PREDICATE" >> $OUT
