# lib.zsh — shared helpers for the stream-mode scripts. Source, don't execute:
#   STREAM_MODE_DIR=${0:A:h}; source $STREAM_MODE_DIR/lib.zsh
#
# Every script that sources this gets: NO_BG_NICE (zsh nices `&` jobs by +5 by
# default, which would sabotage the whole point), the merged config, the log
# root, and the job/pidfile helpers.

setopt NO_BG_NICE EXTENDED_GLOB NULL_GLOB PIPE_FAIL
zmodload zsh/datetime   # $EPOCHSECONDS is empty without it (silently breaks every rate limit)
: ${STREAM_MODE_DIR:=${0:A:h}}
: ${SM_NAME:=${0:t:r}}
: ${STREAM_LOG_ROOT:=$HOME/stream-logs}
RUN_DIR=$STREAM_LOG_ROOT/.run
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH   # never pick up a shadowed log/ps/renice

source $STREAM_MODE_DIR/stream-mode.conf
[[ -r $HOME/.config/stream-mode/stream-mode.conf ]] && source $HOME/.config/stream-mode/stream-mode.conf

ts()   { date '+%Y-%m-%dT%H:%M:%S%z' }
log()  { print -r -- "$(ts) [$SM_NAME] $*" }
warn() { print -r -u2 -- "$(ts) [$SM_NAME] WARN: $*" }
die()  { print -r -u2 -- "$(ts) [$SM_NAME] FATAL: $*"; exit 1 }

# --- session directory (~/stream-logs/<YYYY-MM-DD>, pointed to by ~/stream-logs/current) ---
session_dir() {
  local d=$STREAM_LOG_ROOT/current
  [[ -L $d && -d $d ]] || return 1
  print -r -- ${d:A}
}
require_session() {
  SESSION=$(session_dir) || die "no active session — run 'stream-mode.zsh on' first"
}

# --- background jobs, one pidfile each under $RUN_DIR, output to $SESSION/<name>.out ---
job_pid()   { local f=$RUN_DIR/$1.pid; [[ -r $f ]] && cat $f }
job_alive() { local p; p=$(job_pid $1) && [[ -n $p ]] && kill -0 $p 2>/dev/null }
start_job() {   # start_job <name> <cmd> [args...]
  local name=$1; shift
  if job_alive $name; then log "$name already running (pid $(job_pid $name))"; return 0; fi
  nohup "$@" >>$SESSION/$name.out 2>&1 &!
  local pid=$!
  print -r -- $pid > $RUN_DIR/$name.pid
  log "started $name (pid $pid)"
}
stop_job() {    # stop_job <name>   (TERM, wait ≤5 s, then KILL)
  local name=$1 pid i
  pid=$(job_pid $name) || { return 0 }
  [[ -n $pid ]] || return 0
  if kill -0 $pid 2>/dev/null; then
    kill -TERM $pid 2>/dev/null
    for i in {1..50}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
    kill -0 $pid 2>/dev/null && { kill -KILL $pid 2>/dev/null; warn "$name (pid $pid) needed SIGKILL" }
    log "stopped $name (pid $pid)"
  fi
  rm -f $RUN_DIR/$name.pid
}

# Interruptible sleep for loops: `sleep N & wait` so SIGTERM lands immediately.
SLEEP_PID=
isleep() { sleep $1 & SLEEP_PID=$!; wait $SLEEP_PID 2>/dev/null; SLEEP_PID= }
install_term_trap() {   # install_term_trap [cleanup-function]
  local fn=${1:-}
  trap "log stopping; [[ -n \$SLEEP_PID ]] && kill \$SLEEP_PID 2>/dev/null; ${fn:+$fn;} exit 0" TERM INT HUP
}

# --- sudo probe: actually run a permitted command non-interactively. `sudo -l` is not
# a valid probe (it succeeds for any admin). Renicing our own shell to its current
# value is a no-op that only works under the sudoers.stream-mode NOPASSWD rule.
sudo_ok() { sudo -n /usr/bin/renice "$(ps -o ni= -p $$ | tr -d ' ')" -p $$ >/dev/null 2>&1 }

# --- process helpers ---
# Main process of a Chromium/CEF-style app whose helpers reuse the same binary
# (Spotify): the pgrep -x match without a --type= flag in its arguments.
main_pids_of() { local pid; for pid in $(pgrep -x "$1"); do ps -o args= -p $pid | grep -q -- ' --type=' || print -r -- $pid; done }
ni_of()     { ps -o ni= -p $1 2>/dev/null | tr -d ' ' }
pri_of()    { ps -o pri= -p $1 2>/dev/null | tr -d ' ' }
lstart_of() { ps -o lstart= -p $1 2>/dev/null }
# Highest PRI among a process's threads plus the policy letter (T=timeshare, R=realtime)
dvs_pri_summary() {   # dvs_pri_summary <name> → "name pid=N main=20T max=97R threads=K"
  local name=$1 pid
  pid=$(pgrep -x $name | head -1)
  [[ -n $pid ]] || { print -r -- "$name not running"; return }
  ps -M -p $pid 2>/dev/null | awk -v n=$name -v p=$pid '
    NR>=2 { pri=""; for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+[A-Z]$/) { pri=$i; break }
            if (pri=="") next
            if (NR==2) main=pri
            num=pri; sub(/[A-Z]$/, "", num)
            if (num+0 > maxn) { maxn=num+0; maxp=pri }
            k++ }
    END { printf "%s pid=%s main=%s max=%s threads=%d\n", n, p, main, maxp, k }'
}
