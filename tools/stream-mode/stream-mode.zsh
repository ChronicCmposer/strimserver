#!/bin/zsh
# stream-mode.zsh — instrumented "stream mode" for the streaming Mac.
# See README.md (usage) and plans/stream-mode.md (why).
#
#   stream-mode.zsh preflight        checks only (warns about Zoom; 'on' quits it)
#   stream-mode.zsh on [--force] [--no-quit]   preflight, then start the priority loop + instruments
#                                    (--force: ignore [FAIL]s; --no-quit: dry run, keep Zoom)
#   stream-mode.zsh off [--none-heard]   stop instruments, revert priorities, snapshot logs, analyze
#                                    (--none-heard: record that no dropout was audible all session)
#   stream-mode.zsh status           what is running, current priorities, latest readings
#   stream-mode.zsh mark [note]      append a dropout mark (same as the Mark Dropout app)
#   stream-mode.zsh mark none-heard [note]   record "nothing heard" (makes 0 marks a result)
STREAM_MODE_DIR=${0:A:h}; SM_NAME=stream-mode
source $STREAM_MODE_DIR/lib.zsh

FAILS=0; WARNS=0
ok()   { print -r -- "  [ OK ] $*" }
wrn()  { print -r -- "  [WARN] $*"; (( WARNS++ )) }
bad()  { print -r -- "  [FAIL] $*"; (( FAILS++ )) }
info() { print -r -- "  [info] $*" }
hdr()  { print -r -- "== $* ==" }

app_version() { defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || print -r -- "?" }

# --- round 3 (H6/H7/H9, Q1/Q2/Q4/Q7): the network-side state that fires DVS re-scan storms ---
wifi_power()  { networksetup -getairportpower $WIFI_IFACE 2>/dev/null | sed -n 's/.*: //p' }   # On | Off | ""
awdl_status() { ifconfig awdl0 2>/dev/null | sed -n 's/^[[:space:]]*status: //p' }            # active | inactive | ""
# Apple mobile devices (iPad/iPhone/iPod) on the USB tree, comma-joined product names
apple_usb_devices() { ioreg -p IOUSB -l 2>/dev/null | sed -n -E 's/.*"USB Product Name" = "((iPad|iPhone|iPod)[^"]*)".*/\1/p' | paste -sd, - }
# non-link-local IPv6 addresses on the LAN service (the router's autoconf ULA → AAAA answers → RTM_MISS storms)
lan_global_ipv6() { ifconfig $LAN_IFACE inet6 2>/dev/null | awk '$1 == "inet6" && $2 !~ /^fe80:/ { print $2 }' | paste -sd, - }
encoder_sock()   { [[ -S $ENCODER_SOCK ]] && print listening || print absent }
net_state_line() { print -r -- "Wi-Fi ${$(wifi_power):-?}, awdl0 ${$(awdl_status):-?}, Apple USB devices: ${$(apple_usb_devices):-none}, $LAN_IFACE global IPv6: ${$(lan_global_ipv6):-none}, encoder socket $(encoder_sock)" }

# "name=status net0=type:iface; …" for every Parallels VM; empty without prlctl. A VM start or
# stop on a bridged adapter toggles promiscuous mode on the host NIC, which fires ~100 DVS
# re-scans (round 2, H1) — so the state is recorded at on/off and preflight warns about it.
vm_state() {
  command -v prlctl >/dev/null || return 0
  local line uuid state ip name net out=()   # not "status": read-only in zsh
  for line in "${(f)$(prlctl list -a 2>/dev/null | tail -n +2)}"; do
    read -r uuid state ip name <<< "$line"
    [[ -n $uuid ]] || continue
    net=$(prlctl list -i "$uuid" 2>/dev/null | sed -n -E "s/^  net0 .*type=([a-z]+)( .*iface='([^']*)')?.*/\1:\3/p")
    out+=("${name//[\"\\]/}=$state net0=${${net:-?}%:}")   # "bridged:USB 10/100/1G/2.5G LAN" or "shared"
  done
  print -r -- "${(j:; :)out}"
}

quit_apps() {
  local app pid
  for app in $QUIT_APPS; do
    pgrep -x "$app" >/dev/null || continue
    osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1
    for i in {1..50}; do pgrep -x "$app" >/dev/null || break; sleep 0.1; done
    if pgrep -x "$app" >/dev/null; then pkill -TERM -x "$app"; sleep 1; fi
    pgrep -x "$app" >/dev/null && bad "$app still running" || ok "quit $app"
  done
}

preflight() {
  FAILS=0; WARNS=0
  hdr "preflight $(ts)"
  # --- machine ---
  local free=$(df -g / | awk 'NR==2{print $4}')
  (( free >= MIN_FREE_GB )) && ok "disk: ${free} GB free (≥ ${MIN_FREE_GB})" || wrn "disk: ${free} GB free (< ${MIN_FREE_GB} GB target)"
  local pl=$(sysctl -n kern.memorystatus_vm_pressure_level) swap=$(sysctl -n vm.swapusage | awk '{print $6}')
  (( pl <= 1 )) && ok "memory: pressure level $pl, swap used $swap" || wrn "memory: pressure level $pl (≥2 = warn), swap used $swap"
  info "uptime:$(uptime | sed 's/.*up/ up/; s/,  *[0-9]* users.*//')"
  sudo_ok && ok "sudo -n renice works (sudoers.stream-mode installed)" || wrn "sudo -n renice FAILS — Phase 3.1: sudo install -m 0440 $STREAM_MODE_DIR/sudoers.stream-mode /etc/sudoers.d/stream-mode && sudo visudo -c"
  command -v python3 >/dev/null && ok "python3: $(python3 --version 2>&1)" || bad "python3 missing (obs-stats.py, analyze.py)"
  mkdir -p $STREAM_LOG_ROOT $RUN_DIR 2>/dev/null && [[ -w $STREAM_LOG_ROOT ]] && ok "log root: $STREAM_LOG_ROOT" || bad "log root not writable: $STREAM_LOG_ROOT"
  # --- housekeeping (plan Phase 1) ---
  local ai=$(defaults read com.apple.CloudSubscriptionFeatures.optIn device 2>/dev/null)
  [[ $ai == 0 ]] && ok "Apple Intelligence: off" || wrn "Apple Intelligence: ON (optIn device=${ai:-?}) — System Settings → Apple Intelligence & Siri → off"
  softwareupdate --schedule 2>/dev/null | grep -qi 'turned off' && ok "Software Update: automatic checking off" || wrn "Software Update: automatic checking ON — sudo softwareupdate --schedule off"
  if tmutil destinationinfo 2>&1 | grep -q 'No destinations'; then ok "Time Machine: no destinations configured"
  else local ab=$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null); [[ $ab == 0 ]] && ok "Time Machine: automatic backups off" || wrn "Time Machine: automatic backups ON — sudo tmutil disable"; fi
  # --- OBS config ---
  if [[ -r $OBS_WS_CONFIG ]]; then
    python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c.get("server_enabled") else 1)' "$OBS_WS_CONFIG" \
      && ok "obs-websocket: enabled (port $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("server_port"))' "$OBS_WS_CONFIG"))" \
      || wrn "obs-websocket: server_enabled=false in $OBS_WS_CONFIG"
  else wrn "obs-websocket config not found: $OBS_WS_CONFIG"; fi
  if [[ -r $OBS_SCENE_COLLECTION ]]; then
    python3 - "$OBS_SCENE_COLLECTION" <<'PY' | while IFS= read -r l; do case $l in OK*) ok "${l#OK }";; WARN*) wrn "${l#WARN }";; esac; done
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["sources"]:
    if s["id"] == "ffmpeg_source":
        st = s["settings"]
        good = st.get("close_when_inactive") and st.get("restart_on_activate")
        print(("OK" if good else "WARN") + f" Media source {s['name']!r}: close_when_inactive={st.get('close_when_inactive', False)} restart_on_activate={st.get('restart_on_activate', False)}")
    if s["id"] == "browser_source" and s["name"] == "Chat":
        st = s["settings"]; fps = st.get("fps") if st.get("fps_custom") else "default"
        print(("OK" if fps == 30 else "WARN") + f" Chat browser source fps={fps}")
PY
  else wrn "scene collection not found: $OBS_SCENE_COLLECTION"; fi
  pgrep -x OBS >/dev/null && info "OBS is running (scene-collection checks read the on-disk copy)" || info "OBS not running"
  # --- DVS ---
  local d
  for d in $DVS_DAEMONS dvs_ape; do info "DVS $(dvs_pri_summary $d)"; done
  local band=$(dvs_pri_summary dvsd | sed -n 's/.*main=\([0-9]*\).*/\1/p')
  if [[ -z $band ]]; then wrn "DVS: dvsd not running"
  elif (( band >= 31 )); then ok "DVS daemons: PRI $band (ProcessType=Interactive plist in effect)"
  else wrn "DVS daemons: PRI $band (utility band) — the ProcessType=Interactive plist is not in effect (DVS reinstalled?); see README, Phase 3.2 step 3"; fi
  [[ $DVS_METHOD == none ]] && info "DVS_METHOD=none (Phase 3.2 result: only the plist lifts the daemons; nothing for the loop to do)" || info "DVS_METHOD=$DVS_METHOD"
  if route -n get -inet6 $IPV6_PROBE_ADDR 2>/dev/null | grep -q REJECT; then ok "IPv6 probe reject route present ($IPV6_PROBE_ADDR)"
  else wrn "IPv6 probe reject route missing (plan 3.4) — sudo route -n add -inet6 -host $IPV6_PROBE_ADDR ::1 -reject   (not persistent across reboots)"; fi
  [[ -r $DVS_DEBUG_CONFIG ]] && ok "DVS debug logging: enabled ($DVS_DEBUG_CONFIG)" || wrn "DVS debug logging: off — Phase 3.3: sudo \"$DVS_TOOLS_DIR/DVSEnableDebugLogging.command\""
  info "versions: DVS $(app_version '/Applications/Dante Virtual Soundcard.app'), Dante Controller $(app_version '/Applications/Dante Controller.app'), Loopback $(app_version /Applications/Loopback.app), OBS $(app_version /Applications/OBS.app)"
  # --- network (round 3: H6 AWDL cycles, H7 Wi-Fi dual-homing, H9 Apple IPv6 misses) ---
  local wp=$(wifi_power) aw=$(awdl_status) ausb=$(apple_usb_devices) v6=$(lan_global_ipv6)
  case $wp in
    Off) ok "Wi-Fi ($WIFI_IFACE): off" ;;
    On)  bad "Wi-Fi ($WIFI_IFACE) is ON — every Universal Control/Continuity reconnect over AWDL cycles awdl0 and fires a 60–130-event DVS re-scan storm (round 3, H6); Wi-Fi joining the LAN while wired flaps the default route (H7): networksetup -setairportpower $WIFI_IFACE off" ;;
    *)   wrn "Wi-Fi ($WIFI_IFACE): power state unknown (networksetup -getairportpower $WIFI_IFACE)" ;;
  esac
  case $aw in
    inactive) ok "awdl0: inactive" ;;
    active)   bad "awdl0 is ACTIVE (AWDL peer link up: Universal Control / AirDrop / Handoff / Sidecar) — each reconnect is a DVS re-scan storm (round 3, H6); turn Wi-Fi off" ;;
    *)        info "awdl0: no status (interface absent?)" ;;
  esac
  [[ -n $ausb ]] && wrn "Apple mobile device on the USB tree: $ausb — each attach/detach brings a USB-NCM interface up/down = a 50–100-event DVS re-scan burst (round 3, Q2); unplug it for the stream, or never attach/detach it mid-stream" || ok "no Apple mobile device on USB"
  [[ -n $v6 ]] && wrn "$LAN_IFACE has a non-link-local IPv6 address ($v6) — the router-advertised ULA makes the resolver return AAAA records and every Apple connect an RTM_MISS = one DVS re-scan (round 3, H9/Q4): sudo networksetup -setv6off \"USB 10/100/1G/2.5G LAN\"   (reversible: -setv6automatic)" || ok "$LAN_IFACE IPv6: link-local only"
  [[ -S $ENCODER_SOCK ]] && ok "local-encoder socket listening ($ENCODER_SOCK)" || wrn "local-encoder socket absent ($ENCODER_SOCK) — OBS's first Record fails until the LaunchAgent (local.connor.chroniccmposer.local-encoder) is up (round 3, Q7: reported only, started on demand)"
  # --- apps ---
  local a present=()
  for a in $QUIT_APPS; do pgrep -x "$a" >/dev/null && wrn "$a is running (quit by 'on')"; done
  for a in Spotify "Google Chrome" prl_vm_app Loopback "Stream Deck" chatterino Discord NordVPN Obsidian "Parallels Toolbox" "Dante Controller"; do pgrep -x "$a" >/dev/null && present+=("$a"); done
  info "running: ${(j:, :)present}"
  pgrep -x "Dante Controller" >/dev/null && info "Dante Controller: keep for the first hour (Clock Status Monitoring + DVS Latency), then quit"
  local vms=$(vm_state) vm bridged=()
  for vm in ${(s:; :)vms}; do [[ $vm == *"=running net0=bridged"* ]] && bridged+=("$vm"); done
  if (( $#bridged )); then wrn "Parallels VM running on a bridged NIC: ${(j:; :)bridged} — every VM stop/start toggles promiscuous mode on the host NIC and fires ~100 DVS re-scans (round 2, H1); do not cycle it mid-stream, or switch it (Q2): prlctl set <vm> --device-set net0 --type shared"
  elif [[ -n $vms ]]; then info "Parallels VMs: $vms"; fi
  pgrep -x Safari >/dev/null && wrn "Safari is running — its launch mid-stream (2026-09-14 18:58) started the worst cascade (jetsam sweep → DVS stall → HAL timeouts); keep it closed during the stream"
  print -r -- "preflight: $FAILS fail, $WARNS warn"
  return $(( FAILS > 0 ))
}

new_session() {   # ~/stream-logs/<date>, or <date>-<HHMM> if today already has a session
  SESSION=$STREAM_LOG_ROOT/$(date +%F)
  [[ -e $SESSION ]] && SESSION=$SESSION-$(date +%H%M)
  mkdir -p $SESSION $RUN_DIR
  ln -sfn $SESSION $STREAM_LOG_ROOT/current
}

snapshot_system() {   # snapshot_system <tag>   (start|end)
  local tag=$1
  ps -axo pid,ppid,ni,pri,pcpu,pmem,rss,lstart,comm > $SESSION/ps-$tag.txt
  { df -h /; sysctl vm.swapusage kern.memorystatus_vm_pressure_level kern.memorystatus_level; vm_stat; } > $SESSION/system-$tag.txt 2>&1
  mkdir -p $SESSION/dvs-logs-$tag && cp -p $DVS_LOG_DIR/*.log $SESSION/dvs-logs-$tag/ 2>/dev/null
  { local d; for d in $DVS_DAEMONS dvs_ape coreaudiod; do dvs_pri_summary $d; done } > $SESSION/dvs-priorities-$tag.txt
}

cmd_on() {
  local force=0 noquit=0 arg
  for arg in "$@"; do case $arg in --force) force=1 ;; --no-quit) noquit=1 ;; *) die "usage: ${0:t} on [--force] [--no-quit]" ;; esac; done
  if SESSION=$(session_dir) && job_alive priority-loop; then die "already on (session $SESSION) — run 'off' first"; fi
  if (( noquit )); then info "--no-quit: leaving ${(j:, :)QUIT_APPS} alone (dry run)"; else hdr "quitting ${(j:, :)QUIT_APPS}"; quit_apps; fi
  preflight || (( force )) || die "preflight failed; fix the [FAIL] items or use --force"
  new_session
  hdr "on → $SESSION"
  snapshot_system start
  {
    print -r -- "{"
    print -r -- "  \"start\": \"$(ts)\", \"host\": \"$(hostname)\", \"macos\": \"$(sw_vers -productVersion)\","
    print -r -- "  \"obs\": \"$(app_version /Applications/OBS.app)\", \"dvs\": \"$(app_version '/Applications/Dante Virtual Soundcard.app')\", \"loopback\": \"$(app_version /Applications/Loopback.app)\","
    print -r -- "  \"sudo_ok\": $(sudo_ok && print true || print false), \"dvs_method\": \"$DVS_METHOD\", \"vms\": \"$(vm_state)\","
    print -r -- "  \"wifi\": \"$(wifi_power)\", \"awdl0\": \"$(awdl_status)\", \"apple_usb\": \"$(apple_usb_devices)\", \"lan_global_ipv6\": \"$(lan_global_ipv6)\", \"encoder_sock\": \"$(encoder_sock)\","
    print -r -- "  \"policy\": {\"obs_nice\": $OBS_NICE, \"ffmpeg_nice\": $FFMPEG_NICE, \"spotify_nice\": $SPOTIFY_NICE, \"dvs_nice\": $DVS_NICE, \"background\": \"${(j:, :)BACKGROUND_APPS}\"}"
    print -r -- "}"
  } > $SESSION/session.json
  info "network: $(net_state_line)"
  export STREAM_SESSION=$SESSION OBS_WS_URL OBS_WS_CONFIG OBS_STATS_INTERVAL
  start_job unified-log    $STREAM_MODE_DIR/unified-log.zsh
  start_job route-monitor  $STREAM_MODE_DIR/route-monitor.zsh
  start_job stall-watch    $STREAM_MODE_DIR/stall-watch.zsh
  start_job memory-sampler $STREAM_MODE_DIR/memory-sampler.zsh run
  start_job obs-stats      python3 $STREAM_MODE_DIR/obs-stats.py --session $SESSION
  start_job priority-loop  $STREAM_MODE_DIR/priority-loop.zsh run
  if sudo_ok; then start_job powermetrics $STREAM_MODE_DIR/powermetrics.zsh
  else wrn "powermetrics not started (no sudo); spindumps and renice will also fail until sudoers.stream-mode is installed"; fi
  print -r -- "$(ts)	session	on" >> $SESSION/marks.log
  sleep 2
  cmd_status
}

# Every OBS log whose span overlaps the session → obs-log-<launch>.txt (the crashed instance's
# log was left behind on 2026-09-16 when only the newest was copied), and every OBS crash report
# written inside the session or up to 30 min after it (round 3, 1.2). The log file name is the
# launch time ('2026-09-16 13-16-52.txt'); its mtime is the last line written.
copy_obs_logs() {   # copy_obs_logs <session start epoch> <session end epoch>
  local s0=$1 s1=$2 f launch lm n=0
  for f in "$OBS_CONFIG_DIR"/logs/*.txt(N); do
    launch=$(date -j -f '%Y-%m-%d %H-%M-%S' "${${f:t}%.txt}" +%s 2>/dev/null) || continue
    lm=$(stat -f %m "$f")
    (( launch <= s1 && lm >= s0 )) || continue
    cp -p "$f" "$SESSION/obs-log-${${${f:t}%.txt}// /T}.txt" && (( n++ )) && log "copied OBS log ${f:t}"
  done
  (( n )) || warn "no OBS log overlaps the session (OBS not running?)"
  for f in ~/Library/Logs/DiagnosticReports/OBS*.ips(N) ~/Library/Logs/DiagnosticReports/Retired/OBS*.ips(N); do
    lm=$(stat -f %m "$f")
    (( lm >= s0 && lm <= s1 + 1800 )) || continue
    cp -p "$f" $SESSION/ && log "copied OBS crash report ${f:t} (OBS crashed during the session!)"
  done
}

cmd_off() {
  local none_heard=0 arg
  for arg in "$@"; do case $arg in --none-heard) none_heard=1 ;; *) die "usage: ${0:t} off [--none-heard]" ;; esac; done
  require_session
  hdr "off ← $SESSION"
  stop_job priority-loop
  $STREAM_MODE_DIR/priority-loop.zsh revert
  stop_job powermetrics
  stop_job stall-watch
  stop_job obs-stats
  stop_job memory-sampler
  stop_job route-monitor
  stop_job unified-log
  snapshot_system end
  (( none_heard )) && print -r -- "$(ts)	none-heard	off --none-heard" >> $SESSION/marks.log
  print -r -- "$(ts)	session	off" >> $SESSION/marks.log
  print -r -- "{\"end\": \"$(ts)\", \"vms_end\": \"$(vm_state)\", \"wifi_end\": \"$(wifi_power)\", \"awdl0_end\": \"$(awdl_status)\", \"apple_usb_end\": \"$(apple_usb_devices)\", \"encoder_sock_end\": \"$(encoder_sock)\"}" > $SESSION/session-end.json
  local start=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["start"])' $SESSION/session.json 2>/dev/null)
  local s0=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "${start:-$(ts)}" +%s 2>/dev/null || print 0)
  copy_obs_logs $s0 $EPOCHSECONDS
  [[ -r $PARALLELS_LOG ]] && python3 $STREAM_MODE_DIR/parallels-vm-log.py --src $PARALLELS_LOG $SESSION 2>&1 | while IFS= read -r l; do log "$l"; done
  local marks=$(grep -c $'\tmark\t' $SESSION/marks.log 2>/dev/null); [[ -n $marks ]] || marks=0   # grep -c prints 0 *and* exits 1
  local nh=$(grep -c $'\tnone-heard\t' $SESSION/marks.log 2>/dev/null); [[ -n $nh ]] || nh=0
  if python3 $STREAM_MODE_DIR/analyze.py $SESSION > $SESSION/analyze.out 2>&1; then log "analysis → $SESSION/timeline.md"
  else warn "analyze.py failed (see $SESSION/analyze.out); run it by hand later"; fi
  if [[ -s $SESSION/powermetrics.plist ]]; then   # after the analysis (it reads the plist; it also reads .plist.gz for re-runs)
    log "gzip powermetrics.plist ($(du -h $SESSION/powermetrics.plist | cut -f1)) …"
    nice gzip $SESSION/powermetrics.plist && log "→ powermetrics.plist.gz ($(du -h $SESSION/powermetrics.plist.gz | cut -f1))"
  fi
  local marktxt="${marks} dropout marks"
  if (( marks == 0 )); then
    marktxt="0 marks (none heard: $( (( nh )) && print recorded || print 'NOT recorded' ))"
    (( nh )) || warn "0 marks and no none-heard mark: the session says nothing about audibility — next time end with 'off --none-heard' (or 'mark none-heard') when nothing was heard"
  fi
  print -r -- "- ${SESSION:t}: session ${start:-?} → $(ts); ${marktxt}; logs in \`$SESSION\`; see \`timeline.md\` there" >> $STREAM_MODE_DIR/CHANGELOG.md
  rm -f $STREAM_LOG_ROOT/current
  log "off complete; ${marktxt}; logs: $SESSION"
}

cmd_status() {
  local s; s=$(session_dir) || { print "stream-mode: off (no active session)"; [[ -d $RUN_DIR ]] && for f in $RUN_DIR/*.pid; do wrn "stale pidfile ${f:t}"; done; return 0 }
  hdr "status $(ts) — session $s"
  local j
  for j in priority-loop memory-sampler obs-stats unified-log route-monitor stall-watch powermetrics; do
    job_alive $j && ok "$j running (pid $(job_pid $j))" || wrn "$j NOT running"
  done
  info "disk $(df -g / | awk 'NR==2{print $4}') GB free; pressure level $(sysctl -n kern.memorystatus_vm_pressure_level); swap $(sysctl -n vm.swapusage | awk '{print $6}')"
  print -r -- "  policy processes (pid ni pri %cpu):"
  ps -axo pid=,ni=,pri=,pcpu=,args= | awk '($5 ~ /\/(OBS|ffmpeg|Spotify|Obsidian|Parallels Toolbox)$/ && $0 !~ / --type=/) { n=$5; sub(/.*\//, "", n); printf "    %6d %3d %3d %5s  %s\n", $1, $2, $3, $4, n }'
  local d; for d in $DVS_DAEMONS dvs_ape; do print -r -- "    $(dvs_pri_summary $d)"; done
  (( $(wc -l < $s/obs-stats.csv 2>/dev/null || print 0) > 1 )) && info "obs-stats last: $(tail -1 $s/obs-stats.csv | awk -F, '{printf "fps=%s render=%.1fms skipped(enc)=%s/%s skipped(render)=%s/%s rec_active=%s", $2, $3, $6, $7, $4, $5, $11}')"
  [[ -s $s/marks.log ]] && info "marks: $(grep -c $'\tmark' $s/marks.log) (last: $(grep $'\tmark' $s/marks.log | tail -1 | cut -f1))"
  [[ -s $s/dvs-events.log ]] && info "dvs/hal events: $(wc -l < $s/dvs-events.log | tr -d ' '); spindumps: $(ls $s/spindump-*.txt 2>/dev/null | wc -l | tr -d ' ')"
  [[ -s $s/route-monitor.log ]] && info "routing-socket messages: $(grep -c '^got message' $s/route-monitor.log) (last: $(grep '^RTM_' $s/route-monitor.log | tail -1 | cut -c1-60))"
  [[ -s $s/watchdog.log ]] && info "watchdog last: $(tail -1 $s/watchdog.log)"
  return 0
}

cmd_mark() {
  local s; s=$(session_dir) || s=$STREAM_LOG_ROOT/$(date +%F)
  mkdir -p $s
  print -r -- "$(ts)	mark	${*:-}" >> $s/marks.log
  print -r -- "marked $(ts) → $s/marks.log"
}

case ${1:-} in
  preflight) preflight ;;
  on)        shift; cmd_on "$@" ;;
  off)       cmd_off ;;
  status)    cmd_status ;;
  mark)      shift; cmd_mark "$@" ;;
  *)         sed -n '2,10p' $0; exit 2 ;;
esac
