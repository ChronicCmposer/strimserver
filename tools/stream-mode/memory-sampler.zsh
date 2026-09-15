#!/bin/zsh
# memory-sampler.zsh — instrument 2 (memory CSV every $MEM_INTERVAL s), the
# top-RSS log (every $TOP_RSS_INTERVAL s: the $TOP_RSS_N biggest processes by
# resident size, so a pressure episode can be attributed to who held the memory)
# and instrument 7 (watchdog: macOS notification + watchdog.log when the kernel
# pressure level reaches $WATCHDOG_PRESSURE_LEVEL or swap grows by
# $WATCHDOG_SWAP_GROWTH_MB since the session started).
STREAM_MODE_DIR=${0:A:h}; SM_NAME=memory-sampler
source $STREAM_MODE_DIR/lib.zsh
require_session
CSV=$SESSION/memory.csv
WD=$SESSION/watchdog.log
TOP_RSS=$SESSION/top-rss.log
PAGE=$(sysctl -n hw.pagesize)
: ${TOP_RSS_INTERVAL:=60} ${TOP_RSS_N:=25}
LAST_TOP=0

[[ -s $CSV ]] || print -r -- "ts,free_mb,active_mb,inactive_mb,speculative_mb,wired_mb,compressor_mb,compressed_mb,filebacked_mb,anon_mb,swapins,swapouts,compressions,decompressions,swap_used_mb,swap_total_mb,pressure_level,memorystatus_level" > $CSV

notify() {   # notify <key> <message>  (rate-limited per key)
  local key=$1 msg=$2 now=$EPOCHSECONDS
  local last=${LAST_NOTIFY[$key]:-0}
  print -r -- "$(ts)	$key	$msg" >> $WD
  (( now - last >= WATCHDOG_NOTIFY_INTERVAL )) || return 0
  LAST_NOTIFY[$key]=$now
  osascript -e "display notification \"$msg\" with title \"stream-mode watchdog\" sound name \"Funk\"" >/dev/null 2>&1 &!
}
typeset -A LAST_NOTIFY
SWAP_BASE=
SWAP_NEXT=

top_rss() {   # ts \t pid \t rss_kb \t comm, the $TOP_RSS_N biggest processes (analyze.py sums helpers into their app)
  (( EPOCHSECONDS - LAST_TOP >= TOP_RSS_INTERVAL )) || return 0
  LAST_TOP=$EPOCHSECONDS
  ps -axo rss=,pid=,comm= | sort -rn | head -$TOP_RSS_N | awk -v t="$(ts)" '{ rss=$1; pid=$2; $1=""; $2=""; sub(/^ +/, ""); printf "%s\t%s\t%s\t%s\n", t, pid, rss, $0 }' >> $TOP_RSS
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
  local used=${${(s:,:)row}[15]}
  [[ -n $SWAP_BASE ]] || { SWAP_BASE=$used; SWAP_NEXT=$(( SWAP_BASE + WATCHDOG_SWAP_GROWTH_MB )); log "baseline swap used ${SWAP_BASE} MB; pressure level $pl" }
  if (( pl >= WATCHDOG_PRESSURE_LEVEL )); then
    notify pressure "memory pressure level $pl (memorystatus_level $ml%, swap ${used} MB)"
  fi
  if (( used >= SWAP_NEXT )); then
    notify swap "swap grew to ${used} MB (+$(( used - SWAP_BASE )) MB since start)"
    SWAP_NEXT=$(( SWAP_NEXT + WATCHDOG_SWAP_GROWTH_MB ))
  fi
}

case ${1:-run} in
  once) sample; top_rss; tail -1 $CSV ;;
  run)  install_term_trap; log "sampling every ${MEM_INTERVAL}s → $CSV; top ${TOP_RSS_N} RSS every ${TOP_RSS_INTERVAL}s → $TOP_RSS"
        while :; do sample; top_rss; isleep $MEM_INTERVAL; done ;;
  *) die "usage: ${0:t} run|once" ;;
esac
