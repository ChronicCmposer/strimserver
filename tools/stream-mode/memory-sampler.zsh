#!/bin/zsh
# memory-sampler.zsh — instrument 2 (memory CSV every $MEM_INTERVAL s), the
# top-RSS log (every $TOP_RSS_INTERVAL s: the $TOP_RSS_N biggest processes by
# resident size, so a pressure episode can be attributed to who held the memory),
# the top-compressed log (same cadence: the $TOP_CMPRS_N biggest holders of
# compressed + swapped memory — a leaker that has been swapped out is invisible
# by RSS; round 3, 1.1) and instrument 7 (watchdog: macOS notification +
# watchdog.log when the kernel pressure level reaches $WATCHDOG_PRESSURE_LEVEL,
# swap grows by $WATCHDOG_SWAP_GROWTH_MB since the session started, or — the
# footprint escalation — swap or the compressed logical footprint grows by
# $WATCHDOG_FOOTPRINT_GROWTH_MB within $WATCHDOG_FOOTPRINT_WINDOW s: then
# `footprint -p` of the $FOOTPRINT_TOP_N biggest compressed holders goes to
# footprint-<ts>.txt, at most once per $WATCHDOG_FOOTPRINT_INTERVAL s, and the
# notification names them).
STREAM_MODE_DIR=${0:A:h}; SM_NAME=memory-sampler
source $STREAM_MODE_DIR/lib.zsh
require_session
CSV=$SESSION/memory.csv
WD=$SESSION/watchdog.log
TOP_RSS=$SESSION/top-rss.log
TOP_CMPRS=$SESSION/top-cmprs.log
PAGE=$(sysctl -n hw.pagesize)
: ${TOP_RSS_INTERVAL:=60} ${TOP_RSS_N:=25} ${TOP_CMPRS_N:=15}
: ${WATCHDOG_FOOTPRINT_GROWTH_MB:=2048} ${WATCHDOG_FOOTPRINT_WINDOW:=600} ${WATCHDOG_FOOTPRINT_INTERVAL:=600} ${FOOTPRINT_TOP_N:=3}
LAST_TOP=0
LAST_FOOTPRINT=0

[[ -s $CSV ]] || print -r -- "ts,free_mb,active_mb,inactive_mb,speculative_mb,wired_mb,compressor_mb,compressed_mb,filebacked_mb,anon_mb,swapins,swapouts,compressions,decompressions,swap_used_mb,swap_total_mb,pressure_level,memorystatus_level" > $CSV

notify() {   # notify <key> <message>  (rate-limited per key)
  local key=$1 msg=$2 now=$EPOCHSECONDS
  local last=${LAST_NOTIFY[$key]:-0}
  print -r -- "$(ts)	$key	$msg" >> $WD
  (( now - last >= WATCHDOG_NOTIFY_INTERVAL )) || return 0
  LAST_NOTIFY[$key]=$now
  osascript -e "display notification \"${msg//\"/\'}\" with title \"stream-mode watchdog\" sound name \"Funk\"" >/dev/null 2>&1 &!
}
typeset -A LAST_NOTIFY
SWAP_BASE=
SWAP_NEXT=
# sliding window of (epoch swap_mb compressed_mb) samples for the footprint escalation
HIST_T=(); HIST_SWAP=(); HIST_COMP=()

top_rss() {   # ts \t pid \t rss_kb \t comm, the $TOP_RSS_N biggest processes (analyze.py sums helpers into their app)
  ps -axo rss=,pid=,comm= | sort -rn | head -$TOP_RSS_N | awk -v t="$(ts)" '{ rss=$1; pid=$2; $1=""; $2=""; sub(/^ +/, ""); printf "%s\t%s\t%s\t%s\n", t, pid, rss, $0 }' >> $TOP_RSS
}

# ts \t pid \t mem_mb \t cmprs_mb \t comm — the $TOP_CMPRS_N processes holding the most compressed
# (+ swapped-out) memory. `top -l 1` (one sample, ~0.5 s CPU) in the background band; its
# COMMAND column is 16 characters wide, so the full name comes from ps by pid. MEM is the
# physical footprint (resident + compressed), CMPRS the compressed part; both K/M/G → MB.
top_cmprs() {
  local t=$(ts)
  {
    taskpolicy -b /usr/bin/top -l 1 -stats pid,mem,cmprs,command -o cmprs -n $TOP_CMPRS_N 2>/dev/null
    print -r -- "==PS=="
    ps -axo pid=,comm=
  } | awk -v t="$t" '
    function mb(v,  n, u) { u = substr(v, length(v)); n = v + 0
      if (u == "K") return sprintf("%.0f", n / 1024); if (u == "G") return sprintf("%.0f", n * 1024)
      if (u == "M") return sprintf("%.0f", n); if (u == "B") return "0"; return sprintf("%.0f", n) }
    /^==PS==$/ { ps = 1; next }
    ps == 1 { pid = $1; $1 = ""; sub(/^ +/, ""); comm[pid] = $0; next }
    /^PID / { hdr = 1; next }
    hdr == 1 && $1 ~ /^[0-9]+$/ { rows[++n] = $1 "\t" mb($2) "\t" mb($3) }
    END { for (i = 1; i <= n; i++) { split(rows[i], f, "\t"); c = comm[f[1]]; if (c == "") c = "?"; printf "%s\t%s\t%s\t%s\t%s\n", t, f[1], f[2], f[3], c } }' >> $TOP_CMPRS
}

top_samples() {
  (( EPOCHSECONDS - LAST_TOP >= TOP_RSS_INTERVAL )) || return 0
  LAST_TOP=$EPOCHSECONDS
  top_rss; top_cmprs
}

# footprint escalation: name the holders while the growth is happening (the leak of 2026-09-16
# freed ~46 GB when OBS died; no instrument had named the process)
footprint_escalate() {   # footprint_escalate <growth description>
  local now=$EPOCHSECONDS f=$SESSION/footprint-$(date +%Y%m%dT%H%M%S).txt
  local -a top; local pid names=() line
  # the last top-cmprs sample's biggest holders (pid, cmprs_mb, comm), newest sample only
  top=( ${(f)"$(tail -$TOP_CMPRS_N $TOP_CMPRS 2>/dev/null | sort -t$'\t' -k4,4rn | head -$FOOTPRINT_TOP_N)"} )
  for line in $top; do names+=("${${line##*$'\t'}:t} $(printf '%.1f' $(( ${${(ps:\t:)line}[4]} / 1024.0 ))) GB compressed"); done
  local msg="$1; top compressed: ${(j:, :)names}"
  if (( now - LAST_FOOTPRINT >= WATCHDOG_FOOTPRINT_INTERVAL )); then
    LAST_FOOTPRINT=$now
    {
      print -r -- "# $(ts) footprint escalation: $msg"
      for line in $top; do
        pid=${${(ps:\t:)line}[2]}
        print -r -- "# --- footprint -p $pid (${${line##*$'\t'}:t}) ---"
        taskpolicy -b /usr/bin/footprint -p $pid --swapped 2>&1
      done
    } > $f &!
    msg="$msg → ${f:t}"
    log "footprint escalation → ${f:t} ($msg)"
  fi
  notify footprint "$msg"
}

sample() {
  local t=$(ts) vs swap pl ml
  vs=$(vm_stat)
  swap=$(sysctl -n vm.swapusage)
  pl=$(sysctl -n kern.memorystatus_vm_pressure_level)
  ml=$(sysctl -n kern.memorystatus_level)
  local row
  row=$(print -r -- "$vs" | awk -v page=$PAGE -v swap="$swap" -v pl=$pl -v ml=$ml -v t="$t" '
    function mb(v) { return sprintf("%.0f", v * page / 1048576) }
    /^Pages free/                       { free=$3 }
    /^Pages active/                     { act=$3 }
    /^Pages inactive/                   { inact=$3 }
    /^Pages speculative/                { spec=$3 }
    /^Pages wired down/                 { wired=$4 }
    /^Pages occupied by compressor/     { comp=$5 }
    /^Pages stored in compressor/       { stored=$5 }
    /^File-backed pages/                { fb=$3 }
    /^Anonymous pages/                  { anon=$3 }
    /^Swapins/                          { si=$2 }
    /^Swapouts/                         { so=$2 }
    /^Compressions/                     { c=$2 }
    /^Decompressions/                   { d=$2 }
    END {
      gsub(/\./, "", free); gsub(/\./, "", act); gsub(/\./, "", inact); gsub(/\./, "", spec); gsub(/\./, "", wired)
      gsub(/\./, "", comp); gsub(/\./, "", stored); gsub(/\./, "", fb); gsub(/\./, "", anon)
      gsub(/\./, "", si); gsub(/\./, "", so); gsub(/\./, "", c); gsub(/\./, "", d)
      n = split(swap, s, " "); used=0; total=0
      for (i=1;i<=n;i++) { if (s[i]=="used") { used=s[i+2]; sub(/M$/, "", used) } if (s[i]=="total") { total=s[i+2]; sub(/M$/, "", total) } }
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.0f,%.0f,%s,%s\n", t, mb(free), mb(act), mb(inact), mb(spec), mb(wired), mb(comp), mb(stored), mb(fb), mb(anon), si, so, c, d, used, total, pl, ml
    }')
  print -r -- "$row" >> $CSV
  # --- watchdog ---
  local used=${${(s:,:)row}[15]} stored=${${(s:,:)row}[8]} now=$EPOCHSECONDS
  [[ -n $SWAP_BASE ]] || { SWAP_BASE=$used; SWAP_NEXT=$(( SWAP_BASE + WATCHDOG_SWAP_GROWTH_MB )); log "baseline swap used ${SWAP_BASE} MB, compressed logical ${stored} MB; pressure level $pl" }
  if (( pl >= WATCHDOG_PRESSURE_LEVEL )); then
    notify pressure "memory pressure level $pl (memorystatus_level $ml%, swap ${used} MB)"
  fi
  if (( used >= SWAP_NEXT )); then
    notify swap "swap grew to ${used} MB (+$(( used - SWAP_BASE )) MB since start)"
    SWAP_NEXT=$(( SWAP_NEXT + WATCHDOG_SWAP_GROWTH_MB ))
  fi
  # footprint escalation: growth over the sliding window (oldest sample still inside it)
  HIST_T+=($now); HIST_SWAP+=($used); HIST_COMP+=($stored)
  while (( $#HIST_T > 1 && now - HIST_T[1] > WATCHDOG_FOOTPRINT_WINDOW )); do HIST_T[1]=(); HIST_SWAP[1]=(); HIST_COMP[1]=(); done
  local dswap=$(( used - HIST_SWAP[1] )) dcomp=$(( stored - HIST_COMP[1] )) span=$(( now - HIST_T[1] ))
  if (( span > 0 && (dswap >= WATCHDOG_FOOTPRINT_GROWTH_MB || dcomp >= WATCHDOG_FOOTPRINT_GROWTH_MB) )); then
    footprint_escalate "footprint growth in $(( span / 60 )) min: swap +${dswap} MB (now ${used} MB), compressed logical +${dcomp} MB (now ${stored} MB)"
    HIST_T=($now); HIST_SWAP=($used); HIST_COMP=($stored)   # re-arm: the next escalation needs another +growth from here
  fi
}

case ${1:-run} in
  once) sample; top_rss; top_cmprs; tail -1 $CSV ;;
  footprint) top_cmprs; WATCHDOG_FOOTPRINT_INTERVAL=0; footprint_escalate "manual footprint request"; wait ;;   # name the holders now
  run)  install_term_trap; log "sampling every ${MEM_INTERVAL}s → $CSV; top ${TOP_RSS_N} RSS every ${TOP_RSS_INTERVAL}s → $TOP_RSS; top ${TOP_CMPRS_N} compressed → $TOP_CMPRS; footprint escalation at +${WATCHDOG_FOOTPRINT_GROWTH_MB} MB / ${WATCHDOG_FOOTPRINT_WINDOW}s"
        while :; do sample; top_samples; isleep $MEM_INTERVAL; done ;;
  *) die "usage: ${0:t} run|once|footprint" ;;
esac
