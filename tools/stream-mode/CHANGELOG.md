# stream-mode changelog

What changed on the streaming Mac, why, and where the evidence is. Plan and evidence
table: [`plans/stream-mode.md`](../../plans/stream-mode.md). Baseline (un-instrumented)
replay of the Sep 13 stream: `~/stream-logs/2026-09-13-replay/timeline.md`.

## 2026-09-14 — round 1 (instrument + evidence-backed hardening)

### Phase 1 — housekeeping & config (OBS closed)
- **Disk 22 → 70 GB free**: removed DaVinci Resolve 21.0.4 installer zip (3.9 GB), Xcode
  `iOS DeviceSupport` + `DerivedData` (8.2 GB), Chrome/Claude-ShipIt/Sonarworks-installer
  caches + `brew cleanup` (3.3 GB), `~/Downloads/loras` + `annotators` SD weights (9.7 GB),
  Spotify streaming cache (22.5 GB; offline downloads kept). Not removed: `ducks` clips,
  Zoom recordings, Windows 11 VM. *Why:* plan 1.1, ≥ 60 GB target; the jetsam/compressor
  pressure and 95 % full disk from the Sep 13 evidence.
- **obs-websocket enabled** (`server_enabled: true`, auth + port 4455 unchanged) —
  `plugin_config/obs-websocket/config.json`, backup `config.json.pre-stream-mode-2026-09-14`.
  *Why:* instrument 3 (1 Hz encode/render skip counters).
- **Scene collection `ChronicCmposer`**: `Media` (Twitch HLS ffmpeg_source, hidden in every
  scene) → `close_when_inactive: true`, `restart_on_activate: true`; `Chat` browser source
  60 → 30 fps. Backup `ChronicCmposer.json.pre-stream-mode-2026-09-14`. *Why:* the source
  decoded HLS in software all night and drove the "Max audio buffering reached" resync
  (OBS log 2026-09-12 17-20-10.txt, 00:01:05).
- **DVS 4.5.2.3** installed 17:01 (`~/Downloads/DVS-4.5.2.3_macos.dmg`, sha256
  `8d23b26a…571a1c`, notarized Audinate pkg; replaces 4.5.1.1, a Jan 2025 build). Release
  notes: maintenance, first version listing macOS 26; DS-524 "processes susceptible to
  large clock time changes". Observed difference in `dvs_manager.log`: 4.5.2.3 spawns
  `dvs_ape` without the `--cores=0` and `--sharedMemoryMode=Direct` arguments 4.5.1.1 used.
- **Loopback 2.5.0** (ARK 13.5 engine) installed.
  Accepted as a deliberate confound: it changes the engine behind OBS's desktop-audio
  device. Decision: user, 2026-09-14.
- Manual: Apple Intelligence off; `sudo softwareupdate --schedule off`; Spotify Canvas
  off. Chrome already had Memory Saver + HW acceleration on; Time Machine has no
  destination (nothing to pause).

### Phase 2 — tooling
- Added `tools/stream-mode/` (this directory): `stream-mode.zsh on|off|status|preflight|mark`,
  the priority loop, instruments 1–4/6/7, `obs-stats.py` (stdlib obs-websocket 5 client),
  `analyze.py`, the Mark Dropout applet, `sudoers.stream-mode`, and the
  `ProcessType=Interactive` DVS plist variant. See README.md.
- `tools/local-encoder/local-encoder.zsh`: `setopt NO_BG_NICE`; ffmpeg is backgrounded and
  `FFMPEG_NICE` applied with `sudo -n renice` only when its current nice differs (under the
  LaunchDaemon's `Nice=-10` this is a no-op); failure is fatal; INT/TERM forwarded and the
  child reaped. *Why:* `FFMPEG_NICE` was required but never applied (plan evidence row);
  the LaunchDaemon plist already carries `Nice=-10`, to be verified live in Phase 3.
- Dry run (`on --no-quit` → `mark` → `off`) with OBS closed and no sudoers: all non-root
  instruments write, revert is a no-op, `timeline.md` is produced. Root instruments
  (powermetrics, spindump, renice) are exercised in Phase 3.
- Replay of the Sep 13 stream through `analyze.py` (`~/stream-logs/2026-09-13-replay/`):
  9 HAL overload episodes (6 "client timeout", 1 "client exceeding io cycle budget"),
  idle-exit jetsam sweeps of ~100 kills at :19/:49 past each hour, DVS `dvs_manager_step`
  max 4.447 at 22:54:09 followed by a `conmon_server` respawn at 22:54:21 and an `apec`
  APCP timeout at 23:22:17, 28 Dante audio-flow socket re-creations on en7 — several within
  seconds of HAL/DVS events. 3 of the 6 client-timeout episodes fall inside or right after
  a sweep.

### Phase 3 — root-level steps
- **sudoers** installed 17:12 (`/etc/sudoers.d/stream-mode`, 0440); `sudo -n renice` and
  `sudo -n taskpolicy` verified from a fresh, non-interactive shell.
- **DVS debug logging** enabled 17:13 (`DVSEnableDebugLogging.command` → config json,
  `logLevel: Notice`). The daemons running since 17:01 still carry `-ll=Warning`, so it
  takes effect at the next DVS restart at the earliest (verify after 3.2 step 3).
- **DVS daemon-priority test (3.2), steps 1–2, 17:26–17:28** on `dvsd`/`ptp`/
  `conmon_server`/`apec` (pids 51679/51694/51693/51695, all 13 threads at 20T before):
  (1) `renice -20` → NI −20 applied, PRI unchanged (13 × 20T); reverted to NI 0.
  (2) `taskpolicy -t 0 -l 0` per pid → PRI unchanged (13 × 20T). No unset tier exists
  (`taskpolicy` rejects −1), so the tiers stay until the daemons restart in step 3.
  Neither loop-driven method lifts the utility band → `DVS_METHOD=none` stays.
  (3) 17:34 `ProcessType=Interactive` installed into the LaunchDaemon plist (backup:
  `com.audinate.dante.DanteVirtualSoundcard.plist.orig`), `launchctl bootout` +
  `bootstrap` → **all 13 threads 20T → 31T**, spawn type `daemon (3)` → `interactive (4)`,
  `dvs_ape` keeps its 2 × 97R plus 2 × 31T, engine auto-started, device back in CoreAudio.
  Kept (persistent until a DVS reinstall rewrites the plist). The restart also activated the
  Notice-level debug logging (children now run `-ll=Notice`).
- **Finding — DVS re-scans the network stack on every failed IPv6 route lookup.** With
  Notice logging on, `dvsd` logs `dvs_manager_on_interface_change: event INTERFACE_CHANGE`
  20–30×/min on an idle machine; `dvs_ape` (`ape_interface_tracker_update`) and
  `conmon_server` (`conmon_core_do_update_networks`, with SCDynamicStore gateway/DNS lookups
  that fail with NOTSUP/NOT FOUND) react to each one. `route -n monitor` shows the trigger:
  an `RTM_MISS` for `2001:4860:4860::8888` at exactly those seconds (1:1 over a 20 s window,
  17:47:38–17:47:54). That address is Chromium's IPv6-reachability probe (Chrome, Spotify,
  Stream Deck, Discord, OBS's CEF helpers), and this Mac has no IPv6 default route, so every
  probe is a routing-table miss the DVS control plane treats as an interface change.
  `dvs_manager_step` reached 1.24 s at 17:36:58 with nothing running.
- **Reject route for the probe address (plan 3.4), 17:56**: `sudo route -n add -inet6 -host
  2001:4860:4860::8888 ::1 -reject`. A matched route is never reported as a miss, and
  Chromium still concludes "IPv6 unreachable" exactly as before. Result: routing socket
  silent (0 messages in 2 × 20 s, was ~7), `INTERFACE_CHANGE` 20–30/min → 0–1/min, and the
  `dvs_ape`/`conmon_server` re-scans stopped with it. Not persistent across reboots —
  `preflight` now warns when it is missing (and when the DVS daemons are back in the
  utility band). Decision: user, 2026-09-14. Persistence (LaunchDaemon) after tonight's data.
- **stall-watch rewritten for the timestamped log names**: with `timestampLogs` every daemon
  start opens `<daemon>_<epoch>.log`, so a `tail -F` on the fixed names would have watched
  dead files all night and missed every respawn. The watcher now resolves the newest file per
  daemon every 5 s, replays a new file's existing lines through the same classifier and
  restarts its tail (drains the old one first). Verified with a scratch log dir: stall line →
  event + spindump, simulated `dvsd` and `conmon_server` restarts detected and replayed, HAL
  line from the unified log, spindump cap, clean shutdown with no orphaned `tail`.
- **Bug: `$EPOCHSECONDS` was empty** (zsh needs `zmodload zsh/datetime`), so the spindump
  rate limit in stall-watch and the notification rate limit in memory-sampler always
  evaluated `0 - 0 >= interval` → **no spindump and no watchdog notification would ever have
  fired**. Loaded in `lib.zsh`; spindumps via the sudoers rule verified (≈9 MB each).
- **Bug found while reverting step 1 — macOS `renice -n N` is an increment, not an
  absolute value** (BSD semantics). The loop only worked by accident from nice 0, and
  `revert` (`renice -n 0`) was a silent no-op that would have left OBS/Spotify/ffmpeg
  promoted after `stream-mode off`. Fixed: absolute form `renice N -p pid` in
  `priority-loop.zsh`, `lib.zsh` (`sudo_ok`), `local-encoder.zsh`; the `dvs-tier` revert
  (invalid `-t -1 -l -1`) now just reports that tiers persist until the DVS restart.
  Verified: `priority-loop.zsh once` → Spotify main 0 → −5, second pass no-op,
  `revert` → 0 (scratch `STREAM_LOG_ROOT`, sudoers in place).
### Phase 4/5 — stream + correlation
- Stream 2026-09-14 18:10 → 01:47 (`~/stream-logs/2026-09-14-1810/`). Verdicts as re-derived
  by the round-2 analyzer (the round-1 `timeline.md` truncated at 21:15, called the OBS row
  "no stats" and counted 654 kernel power-budget lines as thermal; kept as `timeline.round1.md`):
  DVS keepalive 0, `dvs_manager_step` max 1.740 s (22:04:20) / 1.697 s (18:58:30) — ❌ (< 1.5);
  OBS encoding-lag skips **58/1,423,322 = 0.0041 %** over two output runs (19/106,088 before the
  18:59 restart, 39/1,317,234 after), max burst 19, no "Max audio buffering" — ✅; thermal
  Nominal in 5,425/5,425 samples, 0 thermalmonitord lines — quiet; pressure level 2 in **6
  episodes totalling 193.8 min = 42.6 %** (longest 74.5 min, min free 14 MB) — ❌; swap flat
  (996 → 713 MB) — ✅; 0 marks. HAL: 16 ClientTimeout reports in 6 episodes, all
  `com.obsproject.obs-studio` on `com.rogueamoeba.Loopback:D`, 64-frame IO buffer.

## 2026-09-15 — round 2, decisions (Q1–Q8)
Q1 dropouts **were heard** on Sep 14 (not marked) → H4 falls, the Mark key is the measurement;
Q2 VM `net0` → **shared** (Phase 2.2); Q3 identify first (done, below), change nothing yet;
Q4 VM stays at 6144 MB, measure; Q5 keep DVS Notice logging; Q6 reject route → LaunchDaemon
(`com.strimserver.ipv6-probe-reject.plist`, Phase 2.1); Q7 keep the targeted spindump policy;
Q8 add `route-monitor.zsh` (`route -n monitor` → `route-monitor.log`; kernel-generated misses
carry pid 0, so it names the probe address, not the process — `analyze.py` joins the messages
to each `dvs-rescan` burst).

## 2026-09-15 — round 2, Phase 2 (root-level steps)
- **2.1 reject route persistent**: `com.strimserver.ipv6-probe-reject.plist` installed to
  `/Library/LaunchDaemons/` and bootstrapped 16:08 (user, sudo); ran at load (route already
  present → "File exists"), `REJECT` flag confirmed.
- **2.2 VM `net0` bridged → shared** (VM stopped by the user; already `shared` when checked,
  `prlctl set` confirmed it). Start at 16:12:08: `vmenet2: promiscuous mode enable` +
  `bridge_set_lro: vmenet2` — Parallels' own shared bridge, **en8 untouched**;
  `dvs_manager` `INTERFACE_CHANGE` +1 in 45 s (a bridged start fired 86–101); `route -n
  monitor` saw nothing. The DVS re-scan storm on VM start/stop is gone (H1's trigger removed).
- **2.3 Loopback buffer — the plugin update already moved it.** `~/Downloads/atkAudio-
  PluginForObs (3).zip` (Sep 14 18:20) → `plugins/` changed 18:20:51, 30 s after OBS launched
  for the stream: the Sep 14 night ran on the in-memory 0.34.3 (saved 64), today's 16:09 test
  launch loaded 0.34.5, which has no `global.audio_server.device_setups` key in its binary and
  negotiated Stream Split at **512** (JUCE default). Effective buffer next stream: 512. The
  `audioDeviceBufferSize` 64 → 256 edit in `atkAudio Plugin for OBS.settings` (backup
  `.pre-round2-2026-09-15`) is inert on 0.34.5. History from the OBS logs: 512 until Sep 13
  23:00:52, then **32 (23:01:08) and 64 (23:01:14)** — lowered mid-stream on the baseline
  night; Sep 13's client-timeout episodes at 21:49, 21:56 and 22:00 happened at 512, the ones at
  23:01:38, 23:27 and 23:51 at 64. Verification line for any launch:
  `[atkAudio][AudioDeviceHandler::reportNegotiatedSetup] "Stream Split" (open) negotiated … / N samples`.
  Note the confound for Sep 14 vs round 2: plugin version and buffer both change.

## 2026-09-15 — config: Discord no longer quit by `on`
- `QUIT_APPS=("zoom.us")` — Discord removed (user decision; it stays up during streams). Preflight
  still lists it under "running:"; the priority loop never touched it.

## 2026-09-15 — round 2, Phase 1 (analyzer + instrument fixes)

Plan: [`plans/stream-mode-round-2.md`](../../plans/stream-mode-round-2.md).

- **`analyze.py`** — pressure episodes (one `memory` event per level ≥ 2 run, with duration,
  min free and the top-RSS processes at that moment; watchdog lines collapsed per run) and a
  per-mechanism row cap so the timeline always reaches the session end; OBS counters summed
  per output run (the counters restart with every output start) and rows without stats
  skipped; thermal = powermetrics/thermalmonitord only; one `hal-*` event per coreaudiod
  overload *report* with `cause`, client, device, buffer, IO duration, budget, page faults
  and wakeups parsed (new `hal-pagefault` row); new mechanisms `dvs-rescan` (≥ 10
  `INTERFACE_CHANGE`/min from the dvs_manager log) and `vm-bridge` (kernel promiscuous-mode
  toggles + Parallels dispatcher VM state changes); every HAL client-timeout episode
  (reports ≤ 10 s apart) is a pseudo-mark with the same `[−60 s, +5 s]` table and an
  attribution label; streaming reader for `powermetrics.plist[.gz]` (244 MB RSS instead of
  the whole 2.5 GB in memory; 2 min for the Sep 14 file).
- **`parallels-vm-log.py`** (new): slices `/Library/Logs/parallels.log` VM state changes into
  `parallels-vm.log`; `off` runs it. The unified log has nothing usable for VM start/stop; the
  dispatcher log has `Vm state was changed from VMS_RUNNING to VMS_STOPPING …`.
- **`obs-stats.py`**: no CSV row without `GetStats` data (obs-websocket accepted the socket at
  18:20:21 before OBS was ready and the empty first row broke the counter arithmetic); waits for
  `GetVersion` to answer before logging "connected"; negative `cpuUsage` (4 rows of −35,000 %)
  → empty.
- **`stream-mode.zsh`**: `off` counted marks as "0\n0" (`grep -c` prints 0 *and* exits 1);
  `off` gzips `powermetrics.plist` after the analysis; `PM_INTERVAL_MS` 5000 → 10000 (2.5 GB
  and a "Second underflow occured." per sample at 5 s); Parallels VM state (`prlctl list`,
  `net0` type + interface) in `session.json`/`session-end.json`; preflight warns when a VM runs
  on a bridged NIC and when Safari is running.
- **`memory-sampler.zsh`**: `top-rss.log` (top 25 by RSS every 60 s).
- **`stall-watch.zsh`**: `dvs-rescan-burst` trigger (≥ 15 `INTERFACE_CHANGE` within 30 s,
  sliding window; lines replayed from a fresh daemon log don't count).
- **`unified-log.zsh`**: `setDetailedThermalPowerBudget` excluded (654 false "thermal" lines),
  `promiscuous`/`bridge_set_lro` included explicitly.
- Verified: analyzer on the Sep 14 session (timeline to 01:44:57, OBS row computed, thermal
  quiet, 6 HAL episodes each attributed); dry run `on --no-quit` → `mark` ×2 → `off` on a
  scratch log root (VM state in both JSONs, `parallels-vm.log`, "2 dropout marks", Spotify
  reverted, `top-rss.log`); burst trigger and targeted spindump with a scratch DVS log.

### Findings from the re-analysis (change the round-2 premises)
- **Observer effect — all 6 HAL client-timeout episodes fell inside a stall-watch spindump
  run.** `spindump -notarget 3` samples every process for 3 s ("Unable to process samples fast
  enough, throttling") and then symbolicates a 14–27 MB dump for 15–23 s at 600–825 ms/s CPU
  (powermetrics), under pressure level 2 with < 100 MB free. Each episode came 7–15 s after
  the spindump's *trigger*, which was always something milder: the 1.70 s / 1.74 s DVS stalls
  (18:58, 22:04) or a µs-scale "Unknown"/budget overload report (19:13:53, 20:03:20, 20:14:23
  — the Parallels VM's own audio client —, 23:24:45). Windows: 18:58:30–53 ⊃ 18:58:45;
  19:13:53–14:09 ⊃ 19:14:03; 20:03:20–34 ⊃ 20:03:28; 20:14:23–38 ⊃ 20:14:32; 22:04:20–33 ⊃
  22:04:28; 23:24:45–59 ⊃ 23:24:52. The Sep 13 baseline had 6 client-timeout episodes with no
  instrument at all, so the fragility is real (OBS's 64-frame client on Loopback:D reports
  ~1.25 ms of IO per 1.33 ms cycle), but on Sep 14 the instrument was a sufficient
  perturbation every time. **Change:** `hal` no longer triggers a spindump; `dvs`/`dvs-rescan`
  take a targeted (`dvsd -onlyTarget -proc conmon_server -proc dvs_ape`, 1.5 MB, ~4 s)
  background-band dump; `analyze.py` flags any episode inside a spindump run. Microstackshots
  (`spindump -microstackshots_save`, 0.08 s) were tried as a zero-cost alternative and
  rejected: 0.46 samples/s machine-wide is too sparse for a 2 s stall.
- **Units:** the HAL report durations are nanoseconds (`io_cycle_budget` = 11,354,166 for the
  512-frame client = 11.35 ms), so `multi_cycle_io_page_faults_duration` = 4,501–11,293 is
  **4.5–11.3 µs**, not ms as the plan's H2 row says — under 1 % of a 1.33 ms cycle. H2's
  page-fault evidence is 1000× weaker than stated; the pressure itself (42.6 % of the night at
  level 2) stands.
- **Three VM bridge cycles, not two**: 20:13:43→20:14:05, 22:03:50→22:04:19 and (after the
  stream) 01:16:28→01:34:41 — each a VM stop → Parallels config editor → two commits →
  `DspCmdVmStart`, each toggling en8's promiscuous mode and firing an `INTERFACE_CHANGE` burst
  (86, 101, 52+62). The VM is configured with **6144 MB**, not 2 GB (Q4). Pressure episode 3
  ended at 22:03:45, five seconds before the VM stopped.
- **Re-scan bursts without a VM trigger**: 826 `INTERFACE_CHANGE` in the session, 26 minutes
  ≥ 10 in 23 bursts; besides the VM cycles, minutes of 10–22 at 18:14, 18:58, 20:10, 20:43,
  21:27, 23:49, 00:18 … and 6/min every hour at :35 coinciding with USB "pipe stalled"
  control errors on the 2.5G LAN adapter (also at every bridge cycle). The 18:58 burst (16)
  is the Safari-launch cascade. Source of the others: unknown — `route -n monitor` logs the
  triggering pid per RTM message and is the instrument for it (round-2 candidate).
- **Q3 — the 64-frame client is the atkAudio plugin, not OBS monitoring.** `Loopback:D` in the
  reports is *Stream Split* (`com.rogueamoeba.Loopback:C4DE22E6…`, the macOS default + system
  output device; the analytics report scrubs the GUID). No OBS source has monitoring enabled, so
  OBS's AudioQueue monitor never runs. `plugin_config/atkaudio-pluginforobs/atkAudio Plugin for
  OBS.settings` → `global.audio_server.device_setups["CoreAudio|Stream Split"]` =
  `audioDeviceRate=48000 audioDeviceBufferSize=64`, 6 in / 6 out: a JUCE CoreAudio device the
  plugin's audio server keeps open for the whole session (the `atkAudio DeviceIo` filter on the
  `Media` source routes through it). Every Loopback device defaults to 512 frames (range
  15–3072; `audiodevs.swift` enumeration), so 64 is this client's explicit request — the
  plugin's device-settings panel has the buffer-size combo. Lever for H3; not applied.
- `dvs_manager_step` is only logged when it sets a new maximum (1.74 s at 22:04:20 stands for
  the rest of the night), so stall *counts* are invisible; the re-scan bursts are the proxy.
- The 6 HAL episodes by attribution (pseudo-marks, before the observer effect is applied):
  18:58 DVS re-scan burst (16) + 1.70 s stall + jetsam sweep + pressure onset (Safari);
  19:14 and 20:03 pressure in progress, nothing else instrumented; 20:14 and 22:04 VM bridge
  cycle (VM start 26 s / 8 s earlier, 1.74 s stall at 22:04:20); 23:24 pressure + 5.9 µs of
  page faults.

## Sessions
(appended by `stream-mode off`)
- 2026-09-14-1810: session 2026-09-14T18:10:11-0400 → 2026-09-15T01:47:40-0400; 0 dropout marks; logs in `/Users/connor/stream-logs/2026-09-14-1810`; see `timeline.md` there (re-analyzed 2026-09-15 with the round-2 analyzer; round-1 output kept as `timeline.round1.md`)
- 2026-09-15: session 2026-09-15T19:27:04-0400 → 2026-09-16T03:04:01-0400; 0 dropout marks; logs in `/Users/connor/stream-logs/2026-09-15`; see `timeline.md` there
- 2026-09-16: session 2026-09-16T13:29:09-0400 → 2026-09-16T20:00:25-0400; 0 dropout marks; logs in `/Users/connor/stream-logs/2026-09-16`; see `timeline.md` there
- 2026-09-16-2121: session 2026-09-16T21:21:31-0400 → 2026-09-17T01:01:04-0400; 0 dropout marks; logs in `/Users/connor/stream-logs/2026-09-16-2121`; see `timeline.md` there
