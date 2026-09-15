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
tools/stream-mode/stream-mode.zsh off            # stop, revert priorities, snapshot logs, analyze
```

`on` refuses to start over a running session and aborts on `[FAIL]` preflight items
(`--force` overrides; `--no-quit` keeps Zoom for dry runs). Everything a
session produces lands in `~/stream-logs/<YYYY-MM-DD>/` (`-HHMM` suffixed when a
second session starts the same day); `~/stream-logs/current` points at the active one.

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

## What runs during a session

| Job | Instrument | Writes |
|-----|-----------|--------|
| `priority-loop.zsh` | policy table below, every 30 s, idempotent | `priorities.log` (ni/pri of the policy processes + DVS thread PRIs), `priority-loop.out` |
| `memory-sampler.zsh` | #2 memory every 5 s; top 25 processes by RSS every 60 s; #7 watchdog | `memory.csv`, `top-rss.log`, `watchdog.log` + macOS notification on pressure ≥ warn or swap +1 GB |
| `obs-stats.py` | #3 obs-websocket `GetStats`/`GetRecordStatus`/`GetStreamStatus` at 1 Hz (stdlib WebSocket client; reconnects forever) | `obs-stats.csv`, `obs-events.log` (record/stream state changes) |
| `unified-log.zsh` | #4 `log stream` (ndjson): coreaudiod overloads/timeouts, kernel memorystatus/jetsam/thermal/en7/en8/USB/bridge, thermalmonitord, arkaudiod — minus known noise families | `unified-log.ndjson` |
| `route-monitor.zsh` | #8 `route -n monitor`: every routing-socket message (type, address; kernel-generated misses carry pid 0) — what the DVS control plane re-scans on | `route-monitor.log` |
| `stall-watch.zsh` | #6 tails the DVS daemon logs + the unified-log capture; timestamps DVS stalls, HAL overloads and re-scan bursts (≥ 15 `INTERFACE_CHANGE` within 30 s); on the `dvs`/`dvs-rescan` triggers takes a *targeted* spindump of the DVS daemons (`spindump dvsd 3 -onlyTarget -proc conmon_server -proc dvs_ape`, background band; ≤ 1 per 120 s, ≤ 20 per session) — HAL overloads no longer trigger one (observer effect, see Caveats) | `dvs-events.log`, `spindump-<ts>-<trigger>.txt` |
| `powermetrics.zsh` | #1 `powermetrics -i 10000 -s cpu_power,gpu_power,thermal,tasks --show-cpu-qos --show-process-qos --format plist` (root) | `powermetrics.plist` (NUL-separated plists; ~170 MB/h at 10 s; gzipped by `off` after the analysis) |

`on` also snapshots `ps`, `vm_stat`/swap, the DVS thread priorities, the Parallels VM
state (`prlctl list`, into `session.json`) and **copies the DVS logs** (`dvs-logs-start/`);
`off` repeats that (`dvs-logs-end/`, `session-end.json`), slices the Parallels dispatcher
log's VM state changes into `parallels-vm.log` (`parallels-vm-log.py`), copies the newest
OBS log (`obs-log.txt`), reverts every priority the loop changed, runs `analyze.py`, gzips
`powermetrics.plist`, and appends a line to `CHANGELOG.md`. The DVS daemons truncate their
logs when DVS restarts, so the snapshots and the live tail are the only durable copies.

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

- **Success criteria** (round 2) measured.
- **Per mark**: every mechanism that fired in `[mark − 30 s, mark + 5 s]`, earliest
  first, plus episodes already in progress (a pressure episode, a re-scan burst) and the
  busiest tasks from the nearest powermetrics sample.
- **Per HAL client-timeout episode** (ClientTimeout reports ≤ 10 s apart): the same
  table over `[−60 s, +5 s]` — a *pseudo-mark*, so every episode is attributed even when
  nobody pressed Mark. The attribution is the first non-HAL mechanism at or before the
  episode (same-second ties broken causally: VM state → bridge → re-scan → stall), labelled
  VM bridge cycle / DVS re-scan burst or stall / memory pressure (+ page faults) / none.
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
cycle — nanoseconds in the report, shown in µs), `dvs-stall`, `dvs-rescan` (≥ 10
`INTERFACE_CHANGE` in a minute; each burst lists the routing-socket messages that preceded
it), `dvs-error`, `vm-bridge` (VM state changes from `parallels-vm.log` and `enN: promiscuous
mode` toggles), `route` (routing-socket messages), `obs-encode`, `obs-render`,
`obs-audio`, `memory` (one event per pressure episode, with the top-RSS processes at its
minimum free), `jetsam`, `thermal` (powermetrics `thermal_pressure ≠ Nominal` or
`thermalmonitord` only), `dante-flow` (new UDP socket to a Dante audio port on en7 = flow
re-created), `nic-usb`, `ark`.

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
  the session's running max is invisible in the DVS log; the re-scan bursts and the
  `dvs-rescan` spindumps are the proxy for the stalls that follow.
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
