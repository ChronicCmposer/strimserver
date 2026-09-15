#!/usr/bin/env python3
"""analyze.py — merge one stream-mode session into timeline.md.

  analyze.py ~/stream-logs/2026-09-14 [--before 30] [--after 5] [-o timeline.md]

Reads whatever the session directory has (every input is optional):
  marks.log, obs-stats.csv, obs-events.log, unified-log.ndjson, dvs-events.log,
  dvs-logs-end/*.log, memory.csv, top-rss.log, watchdog.log, powermetrics.plist[.gz],
  parallels-vm.log, route-monitor.log, spindump-*.txt, obs-log.txt, session.json, session-end.json
and writes timeline.md: success-criteria check, one section per dropout mark
(everything that fired in [mark-before, mark+after], earliest first, plus the
busiest tasks from powermetrics at that moment), the same section for every HAL
client-timeout episode (a pseudo-mark, so the episodes are attributed even when
nobody pressed Mark), a per-mechanism verdict table, and the merged timeline.
Stdlib only.
"""
import argparse, bisect, csv, glob, gzip, json, math, os, plistlib, re, sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

# --------------------------------------------------------------------------- time
ISO_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?([+-]\d{4}|Z)?")
LOCAL_TZ = datetime.now().astimezone().tzinfo


def parse_ts(s):
    """ISO-ish ('2026-09-14T16:39:41-0400', '2026-09-13 23:51:44.512461-0400') → aware datetime."""
    m = ISO_RE.match(s.strip())
    if not m:
        return None
    d, t, frac, tz = m.groups()
    dt = datetime.strptime(d + " " + t, "%Y-%m-%d %H:%M:%S")
    if frac:
        dt = dt.replace(microsecond=int((frac[1:] + "000000")[:6]))
    if tz and tz != "Z":
        dt = dt.replace(tzinfo=timezone(timedelta(hours=int(tz[:3]), minutes=int(tz[0] + tz[3:]))))
    elif tz == "Z":
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.replace(tzinfo=LOCAL_TZ)
    return dt


def fmt(dt):
    return dt.astimezone(LOCAL_TZ).strftime("%H:%M:%S.%f")[:-3] if dt else "?"


def fmt_full(dt):
    return dt.astimezone(LOCAL_TZ).strftime("%Y-%m-%d %H:%M:%S %z") if dt else "?"


def fmt_dur(seconds):
    return f"{seconds / 60:.1f} min" if seconds >= 120 else f"{seconds:.0f} s"


def fmt_delta(seconds):
    """Signed offset from a mark; long offsets (episodes in progress) in minutes."""
    return f"{seconds / 60:+.1f} min" if abs(seconds) >= 120 else f"{seconds:+.1f} s"


# ------------------------------------------------------------------------- events
class Ev:
    __slots__ = ("ts", "ts_end", "mech", "sev", "src", "text", "n", "fields")

    def __init__(self, ts, mech, sev, src, text, n=1, ts_end=None, fields=None):
        self.ts, self.ts_end, self.mech, self.sev, self.src, self.text, self.n = ts, ts_end or ts, mech, sev, src, text, n
        self.fields = fields   # parsed HAL report fields (hal-* events only)

    def __repr__(self):
        return f"{fmt(self.ts)} {self.mech} {self.text}"

    @property
    def span(self):
        return (self.ts_end - self.ts).total_seconds()


MECH_DESC = {
    "hal-timeout":   "coreaudiod overload report, cause=ClientTimeout (an audio client missed its IO deadline)",
    "hal-overload":  "coreaudiod overload report with another cause (client exceeded its IO cycle budget / unknown)",
    "hal-pagefault": "page faults inside the HAL IO cycle of an overload report (multi_cycle_io_page_faults_duration > 0)",
    "dvs-stall":     "DVS control plane: new max dvs_manager_step / keepalive timeout / process respawn",
    "dvs-rescan":    "DVS network re-scan burst: ≥ 10 INTERFACE_CHANGE events in a minute (dvs_manager log)",
    "dvs-error":     "DVS daemon Error/Critical lines",
    "vm-bridge":     "Parallels VM state change / promiscuous-mode toggle on the bridged NIC (VM start/stop)",
    "route":         "routing-socket message (RTM_MISS = unroutable lookup, RTM_IFINFO = interface up/down, RTM_NEWADDR/DELADDR = address change) — what DVS re-scans on",
    "obs-encode":    "OBS output frames skipped (encoding lag)",
    "obs-render":    "OBS render frames skipped (rendering lag)",
    "obs-audio":     "OBS 'Max audio buffering reached' (global audio resync)",
    "obs-output":    "OBS record/stream output state changes",
    "obs-gap":       "obs-stats sampling gap (OBS or obs-websocket not reachable)",
    "memory":        "kernel memory pressure ≥ warn (one event per episode) or swap growth ≥ 1 GB",
    "jetsam":        "kernel memorystatus / jetsam activity",
    "thermal":       "thermal pressure above Nominal (powermetrics) or thermalmonitord lines",
    "dante-flow":    "new UDP socket on en7 to a Dante audio port (14336–14600): audio flow (re)created",
    "nic-usb":       "kernel messages about en7/en8 (USB NICs) or USB",
    "ark":           "arkaudiod (Loopback ARK) log lines",
    "spindump":      "stall spindump taken (see file)",
    "watchdog":      "watchdog notification",
    "mark":          "dropout mark (Stream Deck / CLI)",
    "hal-episode":   "HAL client-timeout episode (pseudo-mark)",
    "session":       "stream-mode on/off",
}
MECHANISMS = ["hal-timeout", "hal-overload", "hal-pagefault", "dvs-stall", "dvs-rescan", "dvs-error", "vm-bridge", "route",
              "obs-encode", "obs-render", "obs-audio", "memory", "jetsam", "thermal", "dante-flow", "nic-usb", "ark"]
SYMPTOMS = ("hal-timeout", "hal-overload", "hal-pagefault")   # never the "first mechanism" of a HAL episode
# Same-second tie-break for "first mechanism" (the DVS logs have whole-second timestamps): the
# VM state change causes the bridge toggle, which causes the re-scan burst, which causes the stall.
CAUSAL_RANK = {"vm-bridge": 0, "route": 1, "jetsam": 2, "dvs-rescan": 3, "dvs-stall": 4, "memory": 5}
DANTE_UDP = re.compile(r"^udp connect(?:ed)?: \[[^\]]*:(\d+)<->[^\]]*:(\d+)\] interface: en7")


# ------------------------------------------------------------------------ readers
def read_lines(path):
    try:
        with open(path, errors="replace") as f:
            return [l.rstrip("\n") for l in f]
    except OSError:
        return []


def read_marks(d):
    marks, sess = [], []
    for l in read_lines(os.path.join(d, "marks.log")):
        parts = l.split("\t")
        ts = parse_ts(parts[0]) if parts else None
        if not ts or len(parts) < 2:
            continue
        if parts[1] == "mark":
            marks.append(Ev(ts, "mark", "mark", "marks.log", parts[2] if len(parts) > 2 and parts[2] else "mark"))
        elif parts[1] == "session":
            sess.append(Ev(ts, "session", "info", "marks.log", "stream-mode " + (parts[2] if len(parts) > 2 else "")))
    return marks, sess


def read_obs_stats(d):
    """Returns (events, summary). Bursts = runs of seconds with new skipped frames (≤2 s gaps).
    The skipped/total counters restart with every video output start, so totals are summed
    per output run (a run ends where the total counter goes backwards); rows without stats
    (obs-websocket answered before OBS was ready) are skipped."""
    path = os.path.join(d, "obs-stats.csv")
    rows = []
    try:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                ts = parse_ts(r.get("ts", ""))
                if ts:
                    rows.append((ts, r))
    except OSError:
        return [], {}
    evs, summary = [], {}

    def ival(r, k):
        try:
            return int(float(r[k]))
        except (KeyError, ValueError, TypeError):
            return None

    def bursts(key, mech, label):
        cur, prev, out = None, None, []
        for ts, r in rows:
            v = ival(r, key)
            if v is None:
                continue
            if prev is not None and v > prev[1]:
                delta = v - prev[1]
                if cur and (ts - cur["last"]).total_seconds() <= 2.5:
                    cur["n"] += delta; cur["last"] = ts
                else:
                    if cur:
                        out.append(cur)
                    cur = {"start": ts, "last": ts, "n": delta}
            prev = (ts, v)
        if cur:
            out.append(cur)
        for b in out:
            dur = (b["last"] - b["start"]).total_seconds() + 1
            evs.append(Ev(b["start"], mech, "high" if b["n"] >= 60 else "med", "obs-stats.csv",
                          f"{label}: +{b['n']} frames over {dur:.0f} s"))
        return out

    def counter_runs(skey, tkey):
        """[{start, end, skipped, total}] per output run; a run ends where the total goes backwards."""
        runs, cur, prev_t = [], None, None
        for ts, r in rows:
            s, t = ival(r, skey), ival(r, tkey)
            if s is None or t is None:
                continue
            if cur is None or (prev_t is not None and t < prev_t):
                cur = {"start": ts, "end": ts, "s0": s, "t0": t, "s": s, "t": t, "first_active": None}
                runs.append(cur)
            cur["end"], cur["s"], cur["t"] = ts, s, t
            if cur["first_active"] is None and t > 0:
                cur["first_active"] = ts
            prev_t = t
        out = []
        for c in runs:
            if c["t"] - c["t0"] <= 0:
                continue   # no frames output in this run (OBS idle)
            out.append({"start": c["first_active"] or c["start"], "end": c["end"],
                        "skipped": c["s"] - c["s0"], "total": c["t"] - c["t0"]})
        return out

    enc = bursts("output_skipped", "obs-encode", "encoding-lag skips")
    bursts("render_skipped", "obs-render", "rendering-lag skips")
    # gaps (OBS unreachable) and output state
    prev_ts, prev_rec = None, None
    for ts, r in rows:
        if prev_ts and (ts - prev_ts).total_seconds() > 10:
            evs.append(Ev(prev_ts, "obs-gap", "info", "obs-stats.csv", f"no OBS stats for {(ts - prev_ts).total_seconds():.0f} s"))
        rec = r.get("rec_active")
        if rec and prev_rec is not None and rec != prev_rec:
            evs.append(Ev(ts, "obs-output", "info", "obs-stats.csv", f"record output {'ACTIVE' if rec == '1' else 'stopped'}"))
        prev_ts, prev_rec = ts, rec if rec else prev_rec
    if rows:
        runs = counter_runs("output_skipped", "output_total")
        if runs:
            ds, dt_ = sum(r["skipped"] for r in runs), max(sum(r["total"] for r in runs), 1)
            summary["encode_skipped"], summary["encode_total"], summary["encode_pct"] = ds, dt_, 100.0 * ds / dt_
            summary["encode_runs"] = runs
        rruns = counter_runs("render_skipped", "render_total")
        if rruns:
            rs, rt = sum(r["skipped"] for r in rruns), max(sum(r["total"] for r in rruns), 1)
            summary["render_skipped"], summary["render_total"], summary["render_pct"] = rs, rt, 100.0 * rs / rt
        summary["encode_max_burst"] = max([b["n"] for b in enc], default=0)
        summary["encode_bursts"] = len(enc)
        try:
            fps = [float(r["active_fps"]) for _, r in rows if r.get("active_fps")]
            rt_ = [float(r["avg_render_ms"]) for _, r in rows if r.get("avg_render_ms")]
            if fps and rt_:
                summary["fps_min"], summary["render_ms_max"] = min(fps), max(rt_)
        except ValueError:
            pass
        summary["samples"] = len(rows)
        summary["span"] = (rows[0][0], rows[-1][0])
    return evs, summary


def read_obs_events(d):
    evs = []
    for l in read_lines(os.path.join(d, "obs-events.log")):
        p = l.split("\t")
        ts = parse_ts(p[0]) if p else None
        if ts and len(p) > 1:
            evs.append(Ev(ts, "obs-output", "info", "obs-events.log", " ".join(p[1:])))
    return evs


# --- coreaudiod overload reports -------------------------------------------------
# Each overload produces, in order: 'HALthreadID', 'adjusted start', an optional cause line
# ('Overload possibly due to client timeout.' / '... exceeding io cycle budget.'), 'Audio IO
# Overload thread: …' and finally a CoreAnalytics 'Sending message. { … }' report whose
# fields name the client, the device, the buffer size and the durations (nanoseconds). One
# event per report; the preamble lines are dropped when a report follows within 0.2 s.
HAL_FIELD = re.compile(r'"(\w+)": Optional\(([^)]*)\)')
HAL_NUM = ("HAL_client_IO_duration", "io_cycle_budget", "multi_cycle_io_page_faults_duration", "wg_external_wakeups",
           "io_buffer_size", "smallest_buffer_frame_size", "io_cycle", "num_continuous_nonzero_io_cycles")
HAL_STR = ("cause", "HostApplicationDisplayID", "output_device_uid_list", "issue_type")
HAL_APP = {"com.obsproject.obs-studio": "OBS", "com.parallels.vm": "Parallels VM", "com.rogueamoeba.arkaudiod": "arkaudiod",
           "com.spotify.client": "Spotify", "com.apple.coreaudiod": "coreaudiod"}


def parse_hal_report(msg):
    f = {}
    for k, v in HAL_FIELD.findall(msg):
        if k in HAL_NUM:
            try:
                f[k] = int(v)
            except ValueError:
                pass
        elif k in HAL_STR:
            f[k] = v.strip()
    return f


def hal_app(f):
    a = f.get("HostApplicationDisplayID", "?")
    return HAL_APP.get(a, a.replace("com.", "", 1))


def hal_dev(f):
    return f.get("output_device_uid_list", "").replace("com.rogueamoeba.", "") or "(input)"


def ms(ns):
    return f"{ns / 1e6:.3f} ms" if ns is not None else "?"


def hal_report_event(ts, f):
    cause = f.get("cause", "?")
    faults, wake = f.get("multi_cycle_io_page_faults_duration"), f.get("wg_external_wakeups")
    budget = f.get("io_cycle_budget") or 0
    io = f.get("HAL_client_IO_duration")
    text = f"{cause}: {hal_app(f)} on {hal_dev(f)}, buf {f.get('io_buffer_size', '?')} frames, client IO {ms(io)}"
    if budget:
        text += f" (budget {ms(budget)})"
    if faults is not None:
        text += f", page faults {faults / 1e3:.1f} µs"
    if wake is not None:
        text += f", ext wakeups {wake}"
    if cause == "ClientTimeout":
        mech, sev = "hal-timeout", "high"
    elif cause == "ClientHALIODurationExceededBudget":
        mech, sev = "hal-overload", "med"
    else:
        mech, sev = "hal-overload", "low"
    evs = [Ev(ts, mech, sev, "unified-log", text, fields=f)]
    if faults:
        evs.append(Ev(ts, "hal-pagefault", "med", "unified-log",
                      f"{faults / 1e3:.1f} µs of page faults inside the IO cycle ({cause} report, {hal_app(f)} on {hal_dev(f)})", fields=f))
    return evs


def hal_events(lines):
    """lines: [(ts, msg)] from coreaudiod in log order → events (see above)."""
    report_ts = sorted(ts for ts, msg in lines if msg.startswith("Sending message"))

    def report_follows(ts):
        i = bisect.bisect_left(report_ts, ts)
        return i < len(report_ts) and (report_ts[i] - ts).total_seconds() <= 0.2

    evs = []
    for ts, msg in lines:
        low = msg.lower()
        if msg.startswith("Sending message"):
            evs.extend(hal_report_event(ts, parse_hal_report(msg)))
        elif any(k in msg for k in ("vm_rtfault_records", "HALthreadID", "adjusted start")):
            continue   # per-overload bookkeeping lines, no information
        elif report_follows(ts):
            continue   # preamble of a report that carries the same information plus the fields
        elif "client timeout" in low:
            evs.append(Ev(ts, "hal-timeout", "high", "unified-log", msg[:160]))
        elif "exceeding io cycle budget" in low:
            evs.append(Ev(ts, "hal-overload", "med", "unified-log", "HAL client exceeded its IO cycle budget (client CPU overrun, not a timeout)"))
        elif "audio io overload" in low:
            evs.append(Ev(ts, "hal-overload", "med", "unified-log", msg[:160]))
        elif "overload" in low or "timeout" in low or "timed out" in low:
            evs.append(Ev(ts, "hal-overload", "low", "unified-log", msg[:160]))
    return evs


PROMISC = re.compile(r"^(en\d+): promiscuous mode (enable|disable)")
# The USB LAN adapter's control requests fail in a burst whenever the bridge reconfigures it (VM
# start/stop) and once an hour on their own; three kernel spellings of the same thing.
USB_NIC_ERR = re.compile(r"AppleUSBNCMControl::sendMER|AppleUSBIORequest::complete: device \d+ \(USB [^)]*LAN|ifnet_ioctl_event_callback:\d+ en\d+ ifnet_ioctl returned")


def read_unified(d):
    evs, hal = [], []
    for l in read_lines(os.path.join(d, "unified-log.ndjson")):
        if not l.startswith("{"):
            continue
        try:
            j = json.loads(l)
        except ValueError:
            continue
        ts = parse_ts(j.get("timestamp", "") or "")
        if not ts:
            continue
        proc = os.path.basename(j.get("processImagePath") or "") or "kernel"
        msg = (j.get("eventMessage") or "").strip()
        low = msg.lower()
        if proc == "coreaudiod":
            hal.append((ts, msg))
        elif proc in ("kernel", "log"):
            pm = PROMISC.match(msg)
            if pm:
                evs.append(Ev(ts, "vm-bridge", "med", "unified-log", f"bridge: {pm.group(1)} promiscuous mode {pm.group(2)} (VM {'started' if pm.group(2) == 'enable' else 'stopped'} on the bridged NIC)"))
            elif msg.startswith("bridge_set_lro"):
                evs.append(Ev(ts, "vm-bridge", "info", "unified-log", msg[:120]))
            elif USB_NIC_ERR.search(msg):
                evs.append(Ev(ts, "nic-usb", "med", "unified-log", "USB LAN adapter control errors (AppleUSBNCMControl sendMER pipe stalled / ifnet_ioctl EIO) — bridge reconfiguration or the hourly burst"))
            elif "memorystatus" in low or "jetsam" in low:
                # real pressure/kill activity only; "Denying dirty-tracking opt-in" etc. is noise
                if "ANE_" not in msg and any(k in low for k in ("kill", "idle-exit", "idle exit", "pressure", "sweep", "jetsam", "freeze", "purge")):
                    evs.append(Ev(ts, "jetsam", "med", "unified-log", msg[:160]))
            elif DANTE_UDP.match(msg):
                m = DANTE_UDP.match(msg)
                ports = {int(m.group(1)), int(m.group(2))}
                if any(14336 <= p_ <= 14600 for p_ in ports):
                    evs.append(Ev(ts, "dante-flow", "med", "unified-log", msg[:120]))
                else:
                    evs.append(Ev(ts, "nic-usb", "low", "unified-log", msg[:120]))
            elif "en7" in msg or "en8" in msg or "usb" in low:
                evs.append(Ev(ts, "nic-usb", "med" if "AppleUSBIORequest" in msg or "ifnet_ioctl" in msg else "low", "unified-log", msg[:160]))
            # kernel lines merely containing "thermal" (ApplePPMPolicyCPMS power-budget chatter) are not thermal events
        elif proc == "thermalmonitord":
            evs.append(Ev(ts, "thermal", "low", "unified-log", msg[:160]))
        elif proc == "arkaudiod":
            evs.append(Ev(ts, "ark", "low", "unified-log", msg[:160]))
    return evs + hal_events(hal)


DVS_LINE = re.compile(r"^([A-Z][a-z]{2}) +(\d{1,2}) (\d{2}:\d{2}:\d{2}) (\w+):? (.*)$")
MONTHS = {m: i for i, m in enumerate(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}
RESCAN_BURST = 10   # INTERFACE_CHANGE per minute that counts as a burst


def read_dvs_logs(d, start, end):
    """DVS daemon logs snapshotted at 'off' (and at 'on', for the pre-session max). Also counts
    dvs_manager's INTERFACE_CHANGE re-scans per minute; runs of minutes ≥ RESCAN_BURST become
    one dvs-rescan event each."""
    evs, maxstep, keepalive = [], 0.0, 0
    year = (start or datetime.now(LOCAL_TZ)).year
    seen = set()
    rescan = defaultdict(list)   # minute → [ts, ...]
    for path in sorted(glob.glob(os.path.join(d, "dvs-logs-end", "*.log")) + glob.glob(os.path.join(d, "dvs-logs-end", "*.1.log"))):
        name = os.path.basename(path)
        for l in read_lines(path):
            m = DVS_LINE.match(l)
            if not m:
                continue
            mon, day, hms, level, msg = m.groups()
            if mon not in MONTHS:
                continue
            try:
                ts = datetime(year, MONTHS[mon], int(day), *map(int, hms.split(":")), tzinfo=LOCAL_TZ)
            except ValueError:
                continue
            if start and ts < start - timedelta(minutes=1):
                continue
            if end and ts > end + timedelta(minutes=1):
                continue
            if "event INTERFACE_CHANGE" in msg:
                rescan[ts.replace(second=0)].append(ts)   # several per second are distinct events
                continue
            key = (ts, name, msg)
            if key in seen:
                continue
            seen.add(key)
            low = msg.lower()
            if "new maximum processing time" in low:
                try:
                    v = float(msg.rsplit(" ", 1)[1]); maxstep = max(maxstep, v)
                except ValueError:
                    v = None
                evs.append(Ev(ts, "dvs-stall", "high" if (v or 0) >= 1.5 else "med", name, msg))
            elif "keepalive" in low or "timed out" in low or "timeout while waiting" in low or "not responding" in low:
                keepalive += 1
                evs.append(Ev(ts, "dvs-stall", "high", name, msg[:160]))
            elif "terminateprocess" in low or "spawnprocess:starting" in low or "exited" in low:
                evs.append(Ev(ts, "dvs-stall", "high", name, msg[:160]))
            elif msg.startswith("Command line:") or re.match(r"^(Conmon Server|Dante Virtual Soundcard Manager) ", msg) or "Daemon started at" in msg:
                if start and ts > start + timedelta(minutes=1):   # a banner mid-session is a daemon (re)start
                    evs.append(Ev(ts, "dvs-stall", "high", name, "daemon (re)started: " + msg[:120]))
            elif level in ("Error", "Critical"):
                evs.append(Ev(ts, "dvs-error", "low", name, msg[:160]))
    summary = {"dvs_max_step": maxstep, "dvs_keepalive": keepalive,
               "rescan_total": sum(len(v) for v in rescan.values()),
               "rescan_max_min": max((len(v) for v in rescan.values()), default=0),
               "rescan_burst_minutes": sum(1 for v in rescan.values() if len(v) >= RESCAN_BURST)}
    cur = None
    bursts = []
    for minute in sorted(rescan):
        n = len(rescan[minute])
        if n < RESCAN_BURST:
            continue
        if cur and (minute - cur["last_min"]) <= timedelta(minutes=1):
            cur["n"] += n; cur["last_min"] = minute; cur["end"] = max(rescan[minute]); cur["peak"] = max(cur["peak"], n)
        else:
            cur = {"n": n, "last_min": minute, "start": min(rescan[minute]), "end": max(rescan[minute]), "peak": n}
            bursts.append(cur)
    for b in bursts:
        dur = (b["end"] - b["start"]).total_seconds() + 1
        evs.append(Ev(b["start"], "dvs-rescan", "high" if b["n"] >= 50 else "med", "dvs_manager log",
                      f"DVS re-scan burst: {b['n']} INTERFACE_CHANGE over {dur:.0f} s (peak {b['peak']}/min)", n=b["n"], ts_end=b["end"]))
    summary["rescan_bursts"] = len(bursts)
    return evs, summary


def read_dvs_events(d):
    """stall-watch's live log: only the spindump records are unique to it."""
    evs = []
    for l in read_lines(os.path.join(d, "dvs-events.log")):
        p = l.split("\t")
        ts = parse_ts(p[0]) if p else None
        if ts and len(p) >= 4 and p[1] == "spindump":
            evs.append(Ev(ts, "spindump", "info", "stall-watch", f"trigger={p[2]} {os.path.basename(p[3])}"))
    return evs


VM_STATE = re.compile(r"Vm state was changed from (\w+) to (\w+) .*?\(name='([^']*)'\)")


def read_parallels(d):
    """parallels-vm.log: the Parallels dispatcher log's VM state changes, sliced at 'off'."""
    evs = []
    for l in read_lines(os.path.join(d, "parallels-vm.log")):
        ts = parse_ts(l)
        if not ts:
            continue
        m = VM_STATE.search(l)
        if m:
            a, b, name = m.groups()
            if a != b:
                evs.append(Ev(ts, "vm-bridge", "med", "parallels-vm.log", f"VM '{name}': {a.replace('VMS_', '')} → {b.replace('VMS_', '')}"))
        elif "RaiseConfigEditor" in l:
            evs.append(Ev(ts, "vm-bridge", "info", "parallels-vm.log", "Parallels: VM configuration editor opened"))
        elif "DspCmdDirVmEditCommit" in l:
            evs.append(Ev(ts, "vm-bridge", "info", "parallels-vm.log", "Parallels: VM configuration committed"))
    return evs


ROUTE_HDR = re.compile(r"^got message of size \d+ on (.+)$")
ROUTE_MSG = re.compile(r"^(RTM_[A-Z_]+):(.*)$")


def read_route_monitor(d):
    """route-monitor.log (`route -n monitor`): one event per message, text 'RTM_MISS <addr>' /
    'RTM_IFINFO if#8 link: up'. Kernel-generated misses carry pid 0, so the address is the
    only identity of a probe."""
    evs, ts, kind, detail, want_addr = [], None, None, "", False
    lines = read_lines(os.path.join(d, "route-monitor.log"))

    def flush():
        if ts and kind:
            evs.append(Ev(ts, "route", "low", "route-monitor.log", (kind + " " + detail).strip()))

    for l in lines:
        m = ROUTE_HDR.match(l)
        if m:
            flush()
            try:
                ts = datetime.strptime(m.group(1).strip(), "%a %b %d %H:%M:%S %Y").replace(tzinfo=LOCAL_TZ)
            except ValueError:
                ts = None
            kind, detail, want_addr = None, "", False
            continue
        m = ROUTE_MSG.match(l)
        if m and ts:
            kind, rest = m.group(1), m.group(2)
            mi = re.search(r"if# ?(\d+)", rest)
            ml = re.search(r"link: (\w+)", rest)
            detail = (f"if#{mi.group(1)}" if mi else "") + (f" link: {ml.group(1)}" if ml else "")
            continue
        if l.startswith("sockaddrs:"):
            want_addr = True
            continue
        if want_addr and l.startswith(" ") and l.strip():
            detail = (detail + " " + l.strip().split()[0]).strip()
            want_addr = False
    flush()
    return evs


def read_top_rss(d):
    """top-rss.log (memory-sampler, every TOP_RSS_INTERVAL s): ts \\t pid \\t rss_kb \\t comm.
    Returns [(ts, {app: rss_mb})] with helper processes summed into their app."""
    samples, cur_ts, cur = [], None, None
    for l in read_lines(os.path.join(d, "top-rss.log")):
        p = l.split("\t")
        if len(p) < 4:
            continue
        ts = parse_ts(p[0])
        if not ts:
            continue
        if ts != cur_ts:
            cur_ts, cur = ts, defaultdict(float)
            samples.append((ts, cur))
        try:
            cur[re.sub(r" Helper.*$", "", os.path.basename(p[3]))] += float(p[2]) / 1024   # "Google Chrome Helper (Renderer)" → "Google Chrome"
        except ValueError:
            pass
    return samples


def top_rss_at(samples, ts, k=4):
    near = [s for s in samples if s[0] <= ts + timedelta(seconds=30)]
    if not near:
        return ""
    t, apps = near[-1]
    top = sorted(apps.items(), key=lambda kv: -kv[1])[:k]
    return f"top RSS at {fmt(t)}: " + ", ".join(f"{a} {v / 1024:.1f} GB" if v >= 1024 else f"{a} {v:.0f} MB" for a, v in top)


def read_memory(d, rss_samples=(), growth_mb=1024, warn_level=2):
    """memory.csv → one 'memory' event per pressure episode (level ≥ warn_level, contiguous
    samples), swap-growth events, and a summary with the time under pressure."""
    path = os.path.join(d, "memory.csv")
    evs, summary, rows = [], {}, []
    try:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                ts = parse_ts(r.get("ts", ""))
                if ts:
                    rows.append((ts, r))
    except OSError:
        return evs, summary
    base_swap, next_swap = None, None
    episodes, cur = [], None

    def close(ep):
        episodes.append(ep)
        dur = (ep["end"] - ep["start"]).total_seconds() + ep["interval"]
        text = (f"pressure level {ep['max_level']} episode: {fmt_dur(dur)} (→ {fmt(ep['end'])}), "
                f"min free {ep['min_free']:.0f} MB at {fmt(ep['min_free_ts'])}, swap {ep['swap0']:.0f} → {ep['swap1']:.0f} MB")
        top = top_rss_at(rss_samples, ep["min_free_ts"])
        if top:
            text += "; " + top
        evs.append(Ev(ep["start"], "memory", "high" if ep["max_level"] >= 4 else "med", "memory.csv", text, ts_end=ep["end"]))

    prev_ts = None
    for ts, r in rows:
        try:
            level, swap, free = int(r["pressure_level"]), float(r["swap_used_mb"]), float(r["free_mb"])
        except (KeyError, ValueError):
            continue
        interval = (ts - prev_ts).total_seconds() if prev_ts else 5.0
        prev_ts = ts
        if base_swap is None:
            base_swap, next_swap = swap, swap + growth_mb
        if level >= warn_level:
            if cur is None:
                cur = {"start": ts, "end": ts, "min_free": free, "min_free_ts": ts, "max_level": level,
                       "swap0": swap, "swap1": swap, "interval": min(interval, 60.0)}
            cur["end"], cur["swap1"], cur["max_level"] = ts, swap, max(cur["max_level"], level)
            if free < cur["min_free"]:
                cur["min_free"], cur["min_free_ts"] = free, ts
        elif cur is not None:
            close(cur); cur = None
        if swap >= next_swap:
            evs.append(Ev(ts, "memory", "med", "memory.csv", f"swap {swap:.0f} MB (+{swap - base_swap:.0f} MB since start)"))
            next_swap += growth_mb
        summary["pressure_max"] = max(summary.get("pressure_max", 0), level)
        summary["swap_max"] = max(summary.get("swap_max", 0), swap)
        summary["free_min"] = min(summary.get("free_min", 1e9), free)
    if cur is not None:
        close(cur)
    if rows:
        summary["swap_start"] = base_swap
        summary["swap_growth"] = summary["swap_max"] - base_swap
        span = max((rows[-1][0] - rows[0][0]).total_seconds(), 1.0)
        under = sum((e["end"] - e["start"]).total_seconds() + e["interval"] for e in episodes)
        summary["pressure_episodes"], summary["pressure_time_s"], summary["pressure_pct"] = len(episodes), under, 100.0 * under / span
        summary["pressure_longest_s"] = max(((e["end"] - e["start"]).total_seconds() + e["interval"] for e in episodes), default=0.0)
    return evs, summary


def read_watchdog(d, gap=15.0):
    """watchdog.log has one line per sample while a condition holds (every 5 s for the whole of a
    pressure episode); runs of the same key become one event so they cannot crowd the timeline."""
    evs, runs, cur = [], [], None
    for l in read_lines(os.path.join(d, "watchdog.log")):
        p = l.split("\t")
        ts = parse_ts(p[0]) if p else None
        if not ts or len(p) < 3:
            continue
        if cur and cur["key"] == p[1] and (ts - cur["end"]).total_seconds() <= gap:
            cur["end"], cur["n"] = ts, cur["n"] + 1
        else:
            cur = {"key": p[1], "start": ts, "end": ts, "n": 1, "first": p[2]}
            runs.append(cur)
    for r in runs:
        text = f"{r['key']}: {r['first']}" if r["n"] == 1 else f"{r['key']}: {r['n']} watchdog lines over {fmt_dur((r['end'] - r['start']).total_seconds())}; first: {r['first']}"
        evs.append(Ev(r["start"], "watchdog", "info", "watchdog.log", text, n=r["n"], ts_end=r["end"]))
    return evs


def nul_chunks(f, bufsize=1 << 22):
    """Yield the NUL-separated records of a stream without holding the whole file in memory."""
    buf = b""
    while True:
        data = f.read(bufsize)
        if not data:
            if buf.strip():
                yield buf
            return
        buf += data
        parts = buf.split(b"\x00")
        buf = parts.pop()
        for p in parts:
            yield p


def read_powermetrics(d):
    """NUL-separated plists (powermetrics.plist or .plist.gz) → (events, samples[(ts, thermal, cpu_mW, gpu_mW, top_tasks)])."""
    samples, evs, prev_thermal = [], [], None
    for path, opener in ((os.path.join(d, "powermetrics.plist"), open), (os.path.join(d, "powermetrics.plist.gz"), gzip.open)):
        try:
            f = opener(path, "rb")
        except OSError:
            continue
        with f:
            for chunk in nul_chunks(f):
                chunk = chunk.strip()
                if not chunk.startswith(b"<?xml"):
                    continue
                try:
                    p = plistlib.loads(chunk)
                except Exception:
                    continue
                ts = p.get("timestamp")
                if isinstance(ts, datetime):
                    ts = ts.replace(tzinfo=timezone.utc) if ts.tzinfo is None else ts
                else:
                    continue
                thermal = p.get("thermal_pressure")
                proc = p.get("processor", {}) if isinstance(p.get("processor"), dict) else {}
                cpu_mw = proc.get("cpu_power") or proc.get("cpu_energy")
                gpu = p.get("gpu", {}) if isinstance(p.get("gpu"), dict) else {}
                gpu_mw = gpu.get("gpu_power") or gpu.get("gpu_energy")
                tasks = p.get("tasks") or []
                top = []
                for t in tasks:
                    if not isinstance(t, dict):
                        continue
                    c = t.get("cputime_ms_per_s")
                    if c is None:
                        continue
                    top.append((float(c), t.get("name", "?"), t.get("pid")))
                top.sort(reverse=True)
                samples.append((ts, thermal, cpu_mw, gpu_mw, top[:8]))
                if thermal and thermal != prev_thermal:
                    if prev_thermal is not None or thermal != "Nominal":
                        evs.append(Ev(ts, "thermal", "info" if thermal == "Nominal" else "high", "powermetrics", f"thermal pressure {prev_thermal} → {thermal}"))
                    prev_thermal = thermal
        break
    return evs, samples


def read_spindumps(d):
    evs = []
    for path in sorted(glob.glob(os.path.join(d, "spindump-*.txt"))):
        m = re.search(r"spindump-(\d{8}T\d{6})-([\w-]+)\.txt$", path)
        if not m:
            continue
        ts = datetime.strptime(m.group(1), "%Y%m%dT%H%M%S").replace(tzinfo=LOCAL_TZ)
        size = os.path.getsize(path) / 1e6
        # the file is written when symbolication ends: its mtime closes the run window
        done = datetime.fromtimestamp(os.path.getmtime(path), LOCAL_TZ)
        done = done if done > ts else ts
        evs.append(Ev(ts, "spindump", "info", "spindump", f"trigger={m.group(2)} {os.path.basename(path)} ({size:.1f} MB; sampling + symbolication until {fmt(done)})", ts_end=done))
    return evs


OBS_LOG_LINE = re.compile(r"^(\d{2}):(\d{2}):(\d{2})\.(\d{3}): (.*)$")


def read_obs_log(d, start, end=None):
    """OBS's own log (copied at 'off'): 'Max audio buffering reached' events inside the session
    window, plus the end-of-output encoding/rendering-lag totals. The newest OBS log may predate
    the session (OBS not relaunched), so the summary is labelled with the log's launch time."""
    path = os.path.join(d, "obs-log.txt")
    lines = read_lines(path)
    if not lines:
        return [], {}
    evs, summary = [], {}
    launch = None
    for l in lines[:20]:
        mm = re.search(r"Current Date/Time: (\d{4}-\d{2}-\d{2}), (\d{2}:\d{2}:\d{2})", l)
        if mm:
            launch = datetime.strptime(mm.group(1) + " " + mm.group(2), "%Y-%m-%d %H:%M:%S").replace(tzinfo=LOCAL_TZ)
            break
    if launch is None:
        launch = (start or datetime.now(LOCAL_TZ)).replace(hour=0, minute=0, second=0, microsecond=0)
    summary["obs_log_launch"] = fmt_full(launch)
    lo = (start - timedelta(minutes=5)) if start else None
    hi = (end + timedelta(minutes=5)) if end else None
    day, last_t = launch.date(), None
    last_seen = None
    for l in lines:
        mm = OBS_LOG_LINE.match(l)
        if not mm:
            continue
        h, mi, s, ms_, msg = mm.groups()
        t = datetime(day.year, day.month, day.day, int(h), int(mi), int(s), int(ms_) * 1000, tzinfo=LOCAL_TZ)
        if last_t and t < last_t - timedelta(hours=1):
            day = day + timedelta(days=1)
            t = t + timedelta(days=1)
        last_t = t
        last_seen = t
        low = msg.lower()
        if "skipped frames due to encoding lag" in low:
            summary["obs_log_encoding_lag"] = msg; continue
        if "lagged frames due to rendering lag" in low:
            summary["obs_log_rendering_lag"] = msg; continue
        if (lo and t < lo) or (hi and t > hi):
            continue
        if "max audio buffering reached" in low:
            evs.append(Ev(t, "obs-audio", "high", "obs-log", msg[:160])); summary["max_audio_buffering"] = summary.get("max_audio_buffering", 0) + 1
        elif "adding 2" in low and "audio buffering" in low:
            evs.append(Ev(t, "obs-audio", "low", "obs-log", msg[:160]))
    summary["obs_log_last"] = last_seen
    summary["obs_log_stale"] = bool(start and last_seen and last_seen < start)
    return evs, summary


# ------------------------------------------------------------------------ report
COLLAPSE_WINDOW = {"jetsam": 30.0, "nic-usb": 5.0, "ark": 5.0, "dvs-error": 5.0, "route": 10.0}
NO_COLLAPSE = ("mark", "session", "spindump", "obs-encode", "obs-render", "obs-output", "memory", "watchdog", "thermal",
               "hal-timeout", "hal-overload", "hal-pagefault", "dvs-rescan", "vm-bridge")


def collapse(evs):
    """Merge same-mechanism events that follow each other within a per-mechanism window
    (jetsam idle-exit sweeps kill dozens of processes, arkaudiod chatters). Events that carry
    their own fields or span (HAL reports, episodes, bursts) are never merged."""
    out, last = [], {}
    for e in sorted(evs, key=lambda e: e.ts):
        w = COLLAPSE_WINDOW.get(e.mech, 1.0)
        prev = last.get(e.mech)
        if prev and e.mech not in NO_COLLAPSE and prev.sev == e.sev and (e.ts - prev.ts_end).total_seconds() <= w \
                and (e.mech != "route" or prev.text == e.text):
            prev.n += e.n
            prev.ts_end = e.ts   # the group extends; ts stays at its first line
            continue
        ne = Ev(e.ts, e.mech, e.sev, e.src, e.text, e.n, ts_end=e.ts_end, fields=e.fields)
        out.append(ne); last[e.mech] = ne
    for e in out:
        dur = e.span
        if e.mech == "jetsam" and e.n > 1:
            e.text = f"idle-exit sweep: {e.n} memorystatus lines (~{e.n // 2} kills) over {dur:.0f} s; first: {e.text[:80]}"
        elif e.n > 1 and dur >= 2 and e.mech not in NO_COLLAPSE:
            e.text = f"{e.text} [{dur:.0f} s]"
    return sorted(out, key=lambda e: e.ts)


def group_episodes(evs, gap):
    """Consecutive events (sorted) closer than `gap` seconds → one group."""
    groups, cur = [], None
    for e in sorted(evs, key=lambda e: e.ts):
        if cur and (e.ts - cur[-1].ts_end).total_seconds() <= gap:
            cur.append(e)
        else:
            cur = [e]; groups.append(cur)
    return groups


def cap_rows(events, cap):
    """Keep at most `cap` rows per mechanism: every med/high row, then an even sample of the rest.
    Returns (rows, {mech: omitted})."""
    by, keep, omitted = defaultdict(list), set(), {}
    for e in events:
        by[e.mech].append(e)
    for m, lst in by.items():
        if len(lst) <= cap:
            keep.update(map(id, lst)); continue
        strong = [e for e in lst if e.sev in ("med", "high", "mark")]
        weak = [e for e in lst if e.sev not in ("med", "high", "mark")]
        room = max(cap - len(strong), 0)
        chosen = strong + ([weak[int(i * len(weak) / room)] for i in range(room)] if room and weak else [])
        keep.update(map(id, chosen)); omitted[m] = len(lst) - len(chosen)
    return [e for e in events if id(e) in keep], omitted


def md_table(headers, rows):
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        lines.append("| " + " | ".join(str(c).replace("|", "\\|").replace("\n", " ") for c in r) + " |")
    return "\n".join(lines)


def yes(b):
    return "✅" if b else "❌"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("--before", type=float, default=30.0, help="seconds before a mark to look for causes")
    ap.add_argument("--after", type=float, default=5.0, help="seconds after a mark (reaction-time slack)")
    ap.add_argument("--hal-gap", type=float, default=10.0, help="ClientTimeout reports closer than this are one episode")
    ap.add_argument("--hal-before", type=float, default=60.0, help="seconds before a HAL episode to look for causes (a VM stop/start cycle takes ~30 s)")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--max-per-mech", type=int, default=300, help="timeline rows per mechanism (med/high kept first)")
    a = ap.parse_args()
    d = os.path.abspath(a.session)
    out_path = a.output or os.path.join(d, "timeline.md")

    session = {}
    for name in ("session.json", "session-end.json"):
        try:
            session.update(json.load(open(os.path.join(d, name))))
        except (OSError, ValueError):
            pass
    start = parse_ts(session.get("start", "")) if session.get("start") else None
    end = parse_ts(session.get("end", "")) if session.get("end") else None

    marks, sess_evs = read_marks(d)
    obs_evs, obs_sum = read_obs_stats(d)
    uni_evs = read_unified(d)
    dvs_evs, dvs_sum = read_dvs_logs(d, start, end)
    rss_samples = read_top_rss(d)
    mem_evs, mem_sum = read_memory(d, rss_samples)
    pm_evs, pm_samples = read_powermetrics(d)
    obslog_evs, obslog_sum = read_obs_log(d, start, end)
    route_evs = read_route_monitor(d)
    for b in [e for e in dvs_evs if e.mech == "dvs-rescan"]:   # what the routing socket said during the burst
        lo, hi = b.ts - timedelta(seconds=10), b.ts_end
        c = Counter(e.text for e in route_evs if lo <= e.ts <= hi)
        if c:
            b.text += " — routing socket: " + ", ".join(f"{k} ×{v}" if v > 1 else k for k, v in c.most_common(4))
    spin_evs = read_spindumps(d)
    have = {e.text.split()[1] for e in spin_evs}   # spindump file names on disk
    spin_evs += [e for e in read_dvs_events(d) if e.text.split()[1] not in have]
    events = (sess_evs + marks + obs_evs + read_obs_events(d) + uni_evs + dvs_evs + spin_evs + read_parallels(d) + route_evs
              + mem_evs + read_watchdog(d) + pm_evs + obslog_evs)
    events = collapse(events)   # a collapsed group's ts is its first line, ts_end its last
    if start is None and events:
        start = min(e.ts for e in events)
    if end is None and events:
        end = max(e.ts for e in events)

    before, after, hal_before = timedelta(seconds=a.before), timedelta(seconds=a.after), timedelta(seconds=a.hal_before)
    mech_events = [e for e in events if e.mech in MECHANISMS]

    # ---- HAL client-timeout episodes → pseudo-marks
    hal_groups = group_episodes([e for e in events if e.mech == "hal-timeout"], a.hal_gap)
    pseudo = []
    for g in hal_groups:
        f0 = g[0].fields or {}
        faults = max((e.fields.get("multi_cycle_io_page_faults_duration", 0) for e in g if e.fields), default=0)
        who = f"{hal_app(f0)} on {hal_dev(f0)}, buf {f0.get('io_buffer_size', '?')}" if f0 else "(no report fields)"
        span = (g[-1].ts_end - g[0].ts).total_seconds()
        text = f"{sum(e.n for e in g)} ClientTimeout reports over {f'{span * 1e3:.0f} ms' if span < 1 else f'{span:.1f} s'}: {who}, page faults max {faults / 1e3:.1f} µs"
        pseudo.append(Ev(g[0].ts, "hal-episode", "mark", "unified-log", text, n=len(g), ts_end=g[-1].ts_end, fields={"faults": faults, "who": who, "reports": sum(e.n for e in g)}))

    def window(mk, symptom_free=False, lookback=before):
        """Events overlapping [mk−lookback, mk+after]: (started inside the window, in progress since before it)."""
        lo, hi = mk.ts - lookback, mk.ts + after
        started, in_progress = [], []
        for e in mech_events:
            if symptom_free and e.mech in SYMPTOMS:
                continue
            if e.ts <= hi and e.ts_end >= lo:
                (started if e.ts >= lo else in_progress).append(e)
        return started, in_progress

    def first_of(started, until=None):
        """Earliest med/high event (any severity if none), optionally only those at or before `until`:
        a human mark has reaction-time slack, a HAL report has none — what follows it is consequence."""
        pool = [e for e in started if until is None or e.ts <= until]
        strong = [e for e in pool if e.sev in ("med", "high")] or pool
        return min(strong, key=lambda e: (e.ts.replace(microsecond=0), CAUSAL_RANK.get(e.mech, 9), e.ts)) if strong else None

    def window_section(mk, started, in_progress, first):
        rows = [(fmt_delta((e.ts - mk.ts).total_seconds()), fmt(e.ts), e.mech, e.sev,
                 (e.text[:120] + ("…" if len(e.text) > 120 else "")) + (f" ×{e.n}" if e.n > 1 and e.mech not in NO_COLLAPSE else ""))
                for e in sorted(started, key=lambda e: e.ts)]
        s = md_table(["Δ", "time", "mechanism", "sev", "detail"], rows) if rows else "_no events started in the window_"
        if in_progress:
            s += "\n\nin progress since before the window: " + "; ".join(
                f"**{e.mech}** since {fmt(e.ts)} ({fmt_delta((e.ts - mk.ts).total_seconds())}): {e.text[:100]}" for e in sorted(in_progress, key=lambda e: e.ts))
        if pm_samples:
            near = [s_ for s_ in pm_samples if s_[0] <= mk.ts]
            if near:
                s_ = near[-1]
                s += f"\n\npowermetrics sample at {fmt(s_[0])}: thermal={s_[1]} cpu={s_[2]} mW gpu={s_[3]} mW; busiest tasks (CPU ms/s): " + \
                     ", ".join(f"{n} {c:.0f}" for c, n, _ in s_[4])
        return s

    # ---- per-mark analysis (real marks: first-class, feed the verdict table)
    mark_sections, in_window_ids = [], set()
    first_counter, hit_counter = Counter(), Counter()
    for i, mk in enumerate(marks, 1):
        started, in_progress = window(mk)
        for e in started + in_progress:
            in_window_ids.add(id(e))
        first = first_of(started)
        if first:
            first_counter[first.mech] += 1
        for m in {e.mech for e in started + in_progress}:
            hit_counter[m] += 1
        verdict = f"**first mechanism: {first.mech}** at {fmt_delta((first.ts - mk.ts).total_seconds())}" if first else "**nothing instrumented fired in the window**"
        mark_sections.append(f"### Mark {i} — {fmt_full(mk.ts)} ({mk.text})\n\n{verdict}\n\n" + window_section(mk, started, in_progress, first))

    # ---- per HAL episode (pseudo-marks): attribution without a human mark
    def attribution(started, in_progress, faults):
        mechs = {e.mech for e in started}
        if "vm-bridge" in mechs:
            return "VM bridge cycle"
        if "dvs-rescan" in mechs or "dvs-stall" in mechs:
            return "DVS re-scan burst / stall without a VM trigger"
        if faults or "jetsam" in mechs or any(e.mech == "memory" for e in in_progress + started):
            return "memory pressure" + (" + page faults in the IO cycle" if faults else "")
        return "none instrumented"

    hal_sections, hal_rows = [], []
    spindumps = [e for e in events if e.mech == "spindump"]
    for i, pk in enumerate(pseudo, 1):
        started, in_progress = window(pk, symptom_free=True, lookback=hal_before)
        first = first_of(started, until=pk.ts)
        faults = pk.fields["faults"]
        attr = attribution(started, in_progress, faults)
        ctx = ", ".join(f"{e.mech} since {fmt(e.ts)}" for e in in_progress) or "—"
        # observer effect: a stall-watch spindump (all-process sampling + symbolication) running at the time
        spin = [e for e in spindumps if e.ts <= pk.ts <= e.ts_end]
        instr = ", ".join(f"spindump {e.text.split()[0].split('=')[1]} started {fmt_delta((e.ts - pk.ts).total_seconds())}" for e in spin) or "—"
        pk.fields["spindump"] = bool(spin)
        verdict = (f"**attribution: {attr}** — first mechanism **{first.mech}** at {fmt_delta((first.ts - pk.ts).total_seconds())} ({first.text[:90]})"
                   if first else f"**attribution: {attr}** — nothing instrumented started in the window")
        if spin:
            verdict += f"\n\n⚠ **inside a spindump run** ({instr}): the instrument itself was sampling/symbolicating — see the CHANGELOG (observer effect, 2026-09-14)"
        hal_sections.append(f"### HAL episode {i} — {fmt_full(pk.ts)} ({pk.text})\n\n{verdict}\n\n" + window_section(pk, started, in_progress, first))
        hal_rows.append((fmt(pk.ts), pk.fields["reports"], pk.fields["who"], f"{faults / 1e3:.1f} µs" if faults else "0",
                         f"{first.mech} {fmt_delta((first.ts - pk.ts).total_seconds())}" if first else "—", ctx, attr, instr))

    # ---- verdict table
    verdict_rows = []
    nmarks = len(marks)
    for m in MECHANISMS:
        total = sum(e.n for e in mech_events if e.mech == m)
        groups = sum(1 for e in mech_events if e.mech == m)
        inwin = sum(1 for e in mech_events if e.mech == m and id(e) in in_window_ids)
        hits, first = hit_counter[m], first_counter[m]
        if nmarks == 0:
            v = "quiet" if groups == 0 else "active, no marks to correlate"
        elif groups == 0:
            v = "eliminated (never fired)"
        elif hits == 0:
            v = "eliminated (fires, but never near a dropout)"
        elif first >= 1 and hits >= math.ceil(nmarks / 2) and nmarks >= 2:
            v = "**confirmed** (first to fire for %d/%d marks)" % (first, nmarks)
        elif first >= 1 and nmarks == 1:
            v = "suspect (first to fire for the only mark — one sample)"
        elif hits >= 1:
            v = "suspect (present for %d/%d marks, first for %d)" % (hits, nmarks, first)
        else:
            v = "inconclusive"
        verdict_rows.append((m, MECH_DESC[m], f"{groups} ({total} lines)", inwin, f"{hits}/{nmarks}", first, v))

    # ---- success criteria (plan, round 2)
    crit = []
    explained = sum(1 for m in marks if any(e.ts <= m.ts + after and e.ts_end >= m.ts - before for e in mech_events))
    crit.append(("Zero marks, or every mark explained by one mechanism",
                 f"{nmarks} marks; {explained} with ≥1 mechanism in window", yes(nmarks == 0 or explained == nmarks)))
    n_vm = sum(1 for r in hal_rows if r[6] == "VM bridge cycle")
    n_unattr = sum(1 for r in hal_rows if r[6] == "none instrumented")
    n_spin = sum(1 for p in pseudo if p.fields.get("spindump"))
    crit.append(("HAL client-timeout episodes ≤ 2, none tied to a VM bridge cycle, every one attributed",
                 f"{len(pseudo)} episodes ({sum(p.fields['reports'] for p in pseudo)} reports); {n_vm} on a VM bridge cycle; {n_unattr} unattributed; {n_spin} inside a spindump run (observer effect)",
                 yes(len(pseudo) <= 2 and n_vm == 0 and n_unattr == 0)))
    if dvs_sum:
        crit.append(("No DVS keepalive timeouts; dvs_manager_step max < 1.5 s; no minute with ≥ 10 INTERFACE_CHANGE",
                     f"keepalive={dvs_sum.get('dvs_keepalive', '?')} max step={dvs_sum.get('dvs_max_step', 0):.3f}; re-scans {dvs_sum.get('rescan_total', 0)} "
                     f"(max {dvs_sum.get('rescan_max_min', 0)}/min, {dvs_sum.get('rescan_burst_minutes', 0)} burst minutes in {dvs_sum.get('rescan_bursts', 0)} bursts)",
                     yes(dvs_sum.get("dvs_keepalive", 0) == 0 and dvs_sum.get("dvs_max_step", 0) < 1.5 and dvs_sum.get("rescan_burst_minutes", 0) == 0)))
    if obs_sum:
        pct = obs_sum.get("encode_pct")
        crit.append(("OBS encoding-lag skips < 0.05 %, no burst > 60 frames; no 'Max audio buffering'",
                     f"{obs_sum.get('encode_skipped', '?')}/{obs_sum.get('encode_total', '?')} = {pct:.4f} % over {len(obs_sum.get('encode_runs', []))} output run(s); max burst {obs_sum.get('encode_max_burst', 0)} in {obs_sum.get('encode_bursts', 0)} bursts; max-audio-buffering={obslog_sum.get('max_audio_buffering', 0)}" if pct is not None else "no stats",
                     yes(pct is not None and pct < 0.05 and obs_sum.get("encode_max_burst", 0) <= 60 and not obslog_sum.get("max_audio_buffering"))))
    else:
        crit.append(("OBS encoding-lag skips < 0.05 %", obslog_sum.get("obs_log_encoding_lag", "no obs-stats and no OBS log"), "n/a"))
    if mem_sum:
        crit.append(("Pressure level ≥ 2 for < 10 % of the session; swap growth < 1 GB",
                     f"{mem_sum.get('pressure_episodes', 0)} episodes, {fmt_dur(mem_sum.get('pressure_time_s', 0))} = {mem_sum.get('pressure_pct', 0):.1f} % (longest {fmt_dur(mem_sum.get('pressure_longest_s', 0))}); "
                     f"max level {mem_sum.get('pressure_max')}; swap {mem_sum.get('swap_start', 0):.0f} → max {mem_sum.get('swap_max', 0):.0f} MB (+{mem_sum.get('swap_growth', 0):.0f}); min free {mem_sum.get('free_min', 0):.0f} MB",
                     yes(mem_sum.get("pressure_pct", 100) < 10 and mem_sum.get("swap_growth", 0) < 1024)))

    # ---- write
    L = []
    L.append(f"# stream-mode timeline — {os.path.basename(d)}\n")
    L.append(f"- session: {fmt_full(start)} → {fmt_full(end)}" + (f" ({(end - start).total_seconds() / 3600:.2f} h)" if start and end else ""))
    L.append(f"- host {session.get('host', '?')} macOS {session.get('macos', '?')}; OBS {session.get('obs', '?')}, DVS {session.get('dvs', '?')}, Loopback {session.get('loopback', '?')}; sudo_ok={session.get('sudo_ok', '?')}; dvs_method={session.get('dvs_method', '?')}")
    L.append(f"- policy: {json.dumps(session.get('policy', {}))}")
    if session.get("vms") or session.get("vms_end"):
        L.append(f"- VMs at on: {session.get('vms', '?')}; at off: {session.get('vms_end', '?')}")
    L.append(f"- window: −{a.before:.0f} s … +{a.after:.0f} s around each mark, −{a.hal_before:.0f} s … +{a.after:.0f} s around each HAL episode; {len(events)} merged events; obs-stats samples: {obs_sum.get('samples', 0)}; powermetrics samples: {len(pm_samples)}; top-RSS samples: {len(rss_samples)}")
    if obslog_sum.get("obs_log_launch"):
        L.append(f"- OBS log copied at off: launched {obslog_sum['obs_log_launch']}, last line {fmt_full(obslog_sum.get('obs_log_last'))}"
                 + (" — **ended before this session** (OBS was not relaunched); its totals below are from an earlier run" if obslog_sum.get("obs_log_stale") else ""))
    if obslog_sum.get("obs_log_encoding_lag"):
        L.append(f"- OBS log: {obslog_sum['obs_log_encoding_lag']}")
    if obslog_sum.get("obs_log_rendering_lag"):
        L.append(f"- OBS log: {obslog_sum['obs_log_rendering_lag']}")
    if obs_sum.get("encode_runs"):
        L.append("- OBS output runs (obs-stats): " + "; ".join(
            f"{fmt(r['start'])} → {fmt(r['end'])}: {r['skipped']}/{r['total']} skipped ({100.0 * r['skipped'] / max(r['total'], 1):.4f} %)" for r in obs_sum["encode_runs"]))
    L.append("\n## Success criteria (round 2)\n")
    L.append(md_table(["criterion", "measured", "met"], crit))
    L.append("\n## Dropout marks\n")
    L.append("\n\n".join(mark_sections) if mark_sections else "_no marks recorded_")
    L.append("\n## HAL client-timeout episodes (pseudo-marks)\n")
    if hal_rows:
        L.append(md_table(["episode", "reports", "client / device / buffer", "page faults", "first mechanism in window", "in progress", "attribution", "instrument running"], hal_rows))
        L.append("")
        L.append("\n\n".join(hal_sections))
    else:
        L.append("_no ClientTimeout reports_")
    L.append("\n## Mechanism verdicts\n")
    L.append(md_table(["mechanism", "what it is", "event groups", "in mark windows", "marks hit", "fired first", "verdict"], verdict_rows))
    L.append("\n## Timeline\n")
    shown, omitted = cap_rows(events, a.max_per_mech)
    if omitted:
        L.append("_rows omitted (per-mechanism cap %d, low-severity rows sampled): %s_\n" % (a.max_per_mech, ", ".join(f"{m} −{n}" for m, n in sorted(omitted.items()))))
    rows = []
    for e in shown:
        flag = "**" if e.mech == "mark" else ""
        span = f" [{fmt_dur(e.span)}]" if e.span >= 2 and e.mech in NO_COLLAPSE and e.mech not in ("obs-encode", "obs-render") else ""
        rows.append((fmt_full(e.ts), f"{flag}{e.mech}{flag}", e.sev, e.src, (e.text[:140] + ("…" if len(e.text) > 140 else "")) + span + (f" ×{e.n}" if e.n > 1 and e.mech not in NO_COLLAPSE else "")))
    L.append(md_table(["time", "mechanism", "sev", "source", "detail"], rows))
    with open(out_path, "w") as f:
        f.write("\n".join(L) + "\n")
    print(f"wrote {out_path}: {nmarks} marks, {len(pseudo)} HAL episodes, {len(events)} events ({len(shown)} timeline rows)")
    for r in hal_rows:
        print(f"  HAL {r[0]} ×{r[1]:<2} {r[2]:<40} faults={r[3]:<8} first={r[4]:<28} → {r[6]}" + (f"  ⚠ {r[7]}" if r[7] != "—" else ""))
    for r in verdict_rows:
        print(f"  {r[0]:<13} {r[6]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
