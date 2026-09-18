# stream-mode

Instrumented "stream mode" for the M2 Pro streaming Mac: a priority policy for the
audio/encode path, a set of timestamped instruments, and an analyzer that turns a
stream's logs into a per-mechanism verdict. Why each piece exists is in
[`plans/stream-mode.md`](../../plans/stream-mode.md); what changed and when is in
[`CHANGELOG.md`](CHANGELOG.md).

## Usage

```bash
tools/stream-mode/stream-mode.zsh preflight      # checks only (reports Zoom, doesn't quit it)
tools/stream-mode/stream-mode.zsh on             # T-15 min: quit Zoom, preflight, start everything
tools/stream-mode/stream-mode.zsh status         # jobs, current priorities, latest readings
tools/stream-mode/stream-mode.zsh mark [note]    # dropout mark (the Stream Deck app does the same)
tools/stream-mode/stream-mode.zsh mark none-heard   # nothing was audible (makes 0 marks a result)
tools/stream-mode/stream-mode.zsh off [--none-heard]   # stop, revert priorities, snapshot logs, analyze
```

`on` refuses to start over a running session and aborts on `[FAIL]` preflight items
(`--force` overrides; `--no-quit` keeps Zoom for dry runs). Since round 3 preflight
**fails** on Wi-Fi power on / `awdl0` active (every Universal Control reconnect over
AWDL is a DVS re-scan storm) and warns on an iPad/iPhone on the USB tree, a global
IPv6 address on `en8`, and a missing local-encoder socket. Everything a session
produces lands in `~/stream-logs/<YYYY-MM-DD>/` (`-HHMM` suffixed when a second session
starts the same day); `~/stream-logs/current` points at the active one. End a session
with `off --none-heard` (or `mark none-heard` any time) when no dropout was audible —
`off` warns when a session ends with 0 marks and no none-heard mark, because such a
session says nothing about audibility.

Machine-local overrides of anything in [`stream-mode.conf`](stream-mode.conf) go in
`~/.config/stream-mode/stream-mode.conf` (same zsh syntax).

## One-time setup

1. **sudoers** (Phase 3.1) — the priority policy and the two root-only instruments run
   through `sudo -n`:
   ```bash
   sudo install -m 0440 tools/stream-mode/sudoers.stream-mode /etc/sudoers.d/stream-mode && sudo visudo -c
   ```
   Scope: `renice`, `taskpolicy`, `powermetrics`, `spindump`, and exactly
   `pkill -x powermetrics`. Remove with `sudo rm /etc/sudoers.d/stream-mode`.
2. **Mark Dropout app** — `./build-mark-dropout.zsh` compiles
   `mark-dropout.applescript` into `~/Applications/Mark Dropout.app`; bind it to a
   Stream Deck *System → Open* action. Each press appends a line to the active
   session's `marks.log` and posts a notification.
3. **DVS debug logging** (Phase 3.3, before the stream; disable after):
   ```bash
   sudo "/Library/Application Support/Audinate/DanteVirtualSoundcard/Tools/DVSEnableDebugLogging.command"
   sudo "/Library/Application Support/Audinate/DanteVirtualSoundcard/Tools/DVSDisableDebugLogging.command"
   ```
4. **DVS daemon priority test** (Phase 3.2) — see below; record the outcome as
   `DVS_METHOD=renice|taskpolicy|none` in the conf. Outcome on 2026-09-14: only the
   `ProcessType=Interactive` plist lifts the daemons (20T → 31T); `DVS_METHOD=none`.
5. **IPv6-probe reject route, persistent** (round 2, Q6) — the route from plan 3.4 vanishes
   at reboot; the LaunchDaemon re-adds it at boot (install/verify/remove instructions are in
   the plist's comment):
   ```bash
   sudo install -m 0644 -o root -g wheel tools/stream-mode/com.strimserver.ipv6-probe-reject.plist /Library/LaunchDaemons/ && sudo launchctl bootstrap system /Library/LaunchDaemons/com.strimserver.ipv6-probe-reject.plist
   ```
6. **Apple IPv6 misses** (round 3, H9/Q4) — `en8` carries the router's autoconf ULA, so the
   resolver returns AAAA records and every connect to `2620:149::/32` is an `RTM_MISS` (=
   one DVS re-scan; 454–595 per stream). Option A turns IPv6 off on the LAN service
   (reversible with `-setv6automatic`); option B, only if misses remain, is a reject
   default route daemon (`com.strimserver.ipv6-reject-default.plist`, instructions inside):
   ```bash
   sudo networksetup -setv6off "USB 10/100/1G/2.5G LAN" && ifconfig en8 inet6
   ```
7. **Before each stream** (round 3, Q1/Q2/Q8): reboot, Wi-Fi off (`networksetup
   -setairportpower en0 off` — this also disables AWDL: Universal Control, AirDrop, Handoff,
   Sidecar), no iPad/iPhone on USB; `preflight` verifies all of it.

## What runs during a session

| Job | Instrument | Writes |
|-----|-----------|--------|
| `priority-loop.zsh` | policy table below, every 30 s, idempotent | `priorities.log` (ni/pri of the policy processes + DVS thread PRIs), `priority-loop.out` |
| `memory-sampler.zsh` | #2 memory every 5 s; top 25 processes by RSS and top 15 by compressed memory every 60 s; #7 watchdog, incl. the footprint escalation (swap or compressed logical footprint +2 GB within 10 min → `footprint -p` of the 3 biggest compressed holders, ≤ 1 per 10 min; `memory-sampler.zsh footprint` does it by hand) | `memory.csv`, `top-rss.log`, `top-cmprs.log`, `watchdog.log`, `footprint-<ts>.txt` + macOS notification on pressure ≥ warn, swap +1 GB, or footprint growth (naming the processes) |
| `obs-stats.py` | #3 obs-websocket `GetStats`/`GetRecordStatus`/`GetStreamStatus` at 1 Hz (stdlib WebSocket client; reconnects forever) | `obs-stats.csv`, `obs-events.log` (record/stream state changes) |
| `unified-log.zsh` | #4 `log stream` (ndjson): coreaudiod overloads/timeouts, kernel memorystatus/jetsam/thermal/en7/en8/USB/bridge (incl. iPad/iPhone attach/detach), thermalmonitord, arkaudiod, and the AWDL actors — rapportd `WiFi P2P transaction` / `_needsAWDL` / `Bonjour AWDL advertiser` / `Read EOF`, UniversalControl `CLinkClient`, sharingd `Wi-Fi power` — minus known noise families | `unified-log.ndjson` |
| `route-monitor.zsh` | #8 `route -n monitor`: every routing-socket message (type, address; kernel-generated misses carry pid 0) — what the DVS control plane re-scans on | `route-monitor.log` |
| `stall-watch.zsh` | #6 tails the DVS daemon logs + the unified-log capture; timestamps DVS stalls, HAL overloads and re-scan bursts (≥ 15 `INTERFACE_CHANGE` within 30 s); on the `dvs` trigger (a new `dvs_manager_step` maximum / keepalive / timed out) takes a *targeted* spindump of the DVS daemons (`spindump dvsd 3 -onlyTarget -proc conmon_server -proc dvs_ape`, background band; ≤ 1 per 120 s, ≤ 20 per session) — HAL overloads (observer effect, see Caveats) and, since round 3, re-scan bursts (33 identical dumps; the cause is in `route-monitor.log`) no longer trigger one | `dvs-events.log`, `spindump-<ts>-<trigger>.txt` |
| `powermetrics.zsh` | #1 `powermetrics -i 10000 -s cpu_power,gpu_power,thermal,tasks --show-cpu-qos --show-process-qos --format plist` (root) | `powermetrics.plist` (NUL-separated plists; ~170 MB/h at 10 s; gzipped by `off` after the analysis) |

`on` also snapshots `ps`, `vm_stat`/swap, the DVS thread priorities, the Parallels VM
state (`prlctl list`), the Wi-Fi/awdl0/Apple-USB/IPv6/encoder-socket state (all into
`session.json`) and **copies the DVS logs** (`dvs-logs-start/`); `off` repeats that
(`dvs-logs-end/`, `session-end.json`), slices the Parallels dispatcher log's VM state
changes into `parallels-vm.log` (`parallels-vm-log.py`), copies **every OBS log whose span
overlaps the session** (`obs-log-<launch>.txt` — a crashed instance's log is not the newest
one) and any `OBS*.ips` crash report written during the session or up to 30 min after it,
reverts every priority the loop changed, runs `analyze.py`, gzips `powermetrics.plist`, and
appends a line to `CHANGELOG.md`. The DVS daemons truncate their logs when DVS restarts, so
the snapshots and the live tail are the only durable copies.

### Priority policy (`stream-mode.conf`)

| Process | Action | How |
|---------|--------|-----|
| OBS main process (not the CEF helpers) | nice −10 | `sudo -n renice` |
| local-encoder ffmpeg | nice −10 | launchd `Nice=-10` + `local-encoder.zsh` + loop (no-op when already −10) |
| Spotify main process | nice −5 | `sudo -n renice` |
| `dvsd`, `ptp`, `conmon_server`, `apec` | per `DVS_METHOD` | `renice -20` / `taskpolicy -t 0 -l 0` / plist (persistent) |
| Obsidian, Parallels Toolbox | background band | `taskpolicy -b` (own processes, no sudo); `-B` on revert |
| zoom.us | quit by `on` | `osascript`, then `pkill` (Discord was on this list until 2026-09-15) |
| Chrome, Parallels VM, Loopback, Stream Deck, Dante Controller, Discord | untouched | — |

The loop records `pid, start time, kind, original value` for every change it makes in
`~/stream-logs/.run/priority-applied.txt`; `off` (or `priority-loop.zsh revert`)
restores exactly those, skipping reused pids. Nothing set by launchd is ever touched.

### DVS daemon priority test (Phase 3.2)

The daemons run at timeshare PRI 20 (utility band). Before the mixer session, after each
step run `ps -M -p $(pgrep -x ptp)` and keep the first step that moves PRI above 20:

```bash
pids=$(pgrep -x 'dvsd|ptp|conmon_server|apec' | tr '\n' ' ')
sudo renice -20 -p $pids                          # (1)
sudo taskpolicy -t 0 -l 0 -p $pids                # (2)
# (3) persistent: ProcessType=Interactive in the LaunchDaemon plist
sudo cp tools/stream-mode/com.audinate.dante.DanteVirtualSoundcard.plist /Library/LaunchDaemons/
sudo launchctl bootout system/com.audinate.dante.DanteVirtualSoundcard
sudo launchctl bootstrap system /Library/LaunchDaemons/com.audinate.dante.DanteVirtualSoundcard.plist
# then Start DVS again in the Dante Virtual Soundcard app
```

`status`/`preflight` print `main=`/`max=` PRI per daemon. Put the winner in
`DVS_METHOD` (steps 1–2 are re-applied by the loop after any DVS restart; step 3 needs
nothing). If nothing moves the number, leave `none` and note "unliftable" in the
CHANGELOG. Result (2026-09-14): steps 1–2 change nothing (the band is a spawn-time
launchd attribute — `launchctl print` shows `spawn type = daemon (3)`); step 3 moves every
thread to 31T and the spawn type to `interactive (4)`.

## Analysis (`analyze.py`)

`python3 tools/stream-mode/analyze.py ~/stream-logs/<date>` (run automatically by
`off`) writes `timeline.md`:

- **Success criteria** (round 3) measured: marks explained (or a none-heard mark), HAL
  episodes excluding OBS crashes, awdl0 cycles / re-scan burst minutes / Apple IPv6 misses
  per hour, DVS keepalive timeouts *and* creation failures / new `dvs_manager_step` maximum
  above the pre-session value (with the "blind below X s" note when the daemons are younger
  than the session) / `dvs_ape` updates per minute, OBS crash + encode skips, pressure /
  swap / compressed-footprint growth with the top compressed holder.
- **Per mark**: every mechanism that fired in `[mark − 30 s, mark + 5 s]`, earliest
  first, plus episodes already in progress (a pressure episode, a re-scan burst) and the
  busiest tasks from the nearest powermetrics sample.
- **Per HAL client-timeout episode** (ClientTimeout reports ≤ 10 s apart): the same
  table over `[−60 s, +5 s]` — a *pseudo-mark*, so every episode is attributed even when
  nobody pressed Mark. The attribution is the first non-HAL mechanism at or before the
  episode (same-second ties broken causally: VM state / AWDL cycle / Wi-Fi flap → routing
  churn → re-scan → stall), labelled OBS crash/restart (a crash within ±30 s) / VM bridge
  cycle / AWDL cycle / Wi-Fi flap / DVS re-scan burst or stall / memory pressure (+ page
  faults) / none.
- **Verdict per mechanism**: confirmed / suspect / eliminated, from how often it was
  present and first in mark windows versus how often it fired elsewhere (real marks only).
- **Merged timeline** of everything (jetsam sweeps, arkaudiod chatter and USB-NIC error
  bursts collapsed; at most 300 rows per mechanism, med/high kept first, so the table
  always reaches the session end).

`audiodevs.swift` (`swiftc -O -o audiodevs audiodevs.swift && ./audiodevs`) lists every
CoreAudio device with UID, channels, buffer size and range, and the default-device flags —
how `Loopback:D` in the HAL reports was mapped to *Stream Split* and the 64-frame request to
the atkAudio plugin's audio server (round 2, Q3).

Mechanisms: `hal-timeout` (coreaudiod report with `cause=ClientTimeout`, one event per
report with the client, device, buffer size, IO duration and page-fault fields parsed),
`hal-overload` (other causes), `hal-pagefault` (a report with page faults inside the IO
cycle — nanoseconds in the report, shown in µs), `dvs-stall` (incl. `Failed to create
keepalive`, counted apart from timeouts), `dvs-rescan` (≥ 10 `INTERFACE_CHANGE` in a minute;
each burst lists the awdl0 cycle it sits on and the routing-socket message types × interfaces
that preceded it; plus `dvs_ape` "Updating interfaces" minutes ≥ 20 that no manager burst
covers), `dvs-error`, `vm-bridge` (VM state changes from `parallels-vm.log` and `enN:
promiscuous mode` toggles), `awdl` (one event per `awdl0` `RTM_NEWADDR` = one AWDL cycle,
plus the rapportd/UniversalControl actor lines), `wifi` (`en0` address add/delete,
default-route add/delete with the gateway, sharingd Wi-Fi power), `route` (the other
routing-socket messages, with the interface name), `obs-crash` (crash report, the OBS-log
`Failed to lock QIOSurfaceGraphicsBuffer` line, an obs-websocket re-connect), `obs-encode`,
`obs-render`, `obs-audio`, `memory` (one event per pressure episode, with the top-RSS and
top-compressed processes at its minimum free; footprint escalations), `jetsam`, `thermal`
(powermetrics `thermal_pressure ≠ Nominal` or `thermalmonitord` only), `dante-flow` (new UDP
socket to a Dante audio port on en7 = flow re-created), `nic-usb` (incl. iPad/iPhone
attach/detach), `ark`.

OBS skip counters restart with every output start; the analyzer sums them per output run
and lists the runs in the header.

A replay of an un-instrumented stream can be built by hand — `dvs-logs-end/`, `obs-log.txt`,
`session.json` with `start`/`end`, `unified-log.ndjson` from `log show --start … --end …
--style ndjson --predicate "$PREDICATE"` (the predicate is in `unified-log.zsh`), and
`parallels-vm.log` from `parallels-vm-log.py <session>` (the dispatcher log keeps weeks).

## Caveats

- **Observer effect (2026-09-14):** every one of the night's 6 HAL client-timeout episodes
  fell inside a stall-watch `spindump -notarget` run — 3 s of all-process sampling followed
  by 15–23 s symbolicating a 14–27 MB dump at ~700 ms/s CPU, under memory-pressure level 2 —
  7–15 s after a milder trigger (a DVS stall, or a µs-scale "Unknown"/budget overload
  report). A HAL overload → spindump → worse HAL overload is self-fulfilling, so `hal` is no
  longer a spindump trigger (`SPINDUMP_TRIGGERS`), the dump is targeted at the DVS daemons
  (`SPINDUMP_TARGETS`; 1.5 MB, ~4 s of symbolication) and runs under `taskpolicy -b`.
  `analyze.py` flags any HAL episode that still falls inside a spindump run.
- `powermetrics` with the `tasks` sampler is verbose: `-i 5000` produced 2.5 GB (and a
  "Second underflow occured." per sample) over 7.5 h, hence `-i 10000` and the gzip at
  `off` (`analyze.py` reads `.plist.gz`). Delete old session directories when done with them.
- `dvs_manager_step` is only logged when it sets a *new maximum*, so a stall shorter than
  the session's running max is invisible in the DVS log — and after a reboot the boot-time
  value (3.413 s on 2026-09-16 20:56) blinds the criterion for the whole session. The
  analyzer prints the pre-session maximum and the "blind below" note; the re-scan bursts and
  `dvs_ape`'s "Updating interfaces" rate are the proxy for the stalls that follow.
- `top-rss.log` cannot see a swapped-out process: the 2026-09-16 leak (~46 GB in the OBS
  tree, ~1 GB/min) never appeared in it. `top-cmprs.log` (`top -o cmprs`) and the footprint
  escalation exist for that; `top -l 1` costs ~0.5 s of CPU per sample, hence the 60 s
  cadence in the background band.
- `/usr/bin/python3` is 3.9 on this Mac (`lib.zsh` puts `/usr/bin` first): no f-string
  backslashes, no `match`.
- The HAL report durations (`HAL_client_IO_duration`, `io_cycle_budget`,
  `multi_cycle_io_page_faults_duration`) are nanoseconds: the 512-frame client's budget is
  reported as 11,354,166 = 11.35 ms, so the page-fault figures are microseconds, not ms.
- zsh nices background jobs by +5 by default (`BG_NICE`); every script here sets
  `NO_BG_NICE`, and `local-encoder.zsh` does too.
- `log` is a zsh builtin — the scripts call `/usr/bin/log`.
- macOS `renice -n N` is an *increment*, not an absolute value (BSD semantics; `renice -n 0`
  is a no-op). Every renice here uses the absolute form `renice N -p pid`.
- `$EPOCHSECONDS` is empty unless `zsh/datetime` is loaded (`lib.zsh` does) — an empty value
  makes every `(( now - last >= interval ))` rate limit silently false.
- With DVS debug logging on (`timestampLogs`), each daemon start writes a new
  `<daemon>_<epoch>.log` instead of rotating `<daemon>.log`; `stall-watch` re-resolves the
  newest file per daemon every 5 s and `off` bundles `*.log` regardless.
- `sudo -l` is not a NOPASSWD probe (it succeeds for any admin); `sudo_ok` actually
  renices the probing shell to its own current value.
