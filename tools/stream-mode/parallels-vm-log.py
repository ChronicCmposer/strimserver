#!/usr/bin/env python3
"""parallels-vm-log.py — slice the Parallels dispatcher log for one session.

  parallels-vm-log.py ~/stream-logs/2026-09-14-1810 [--src /Library/Logs/parallels.log]

Writes <session>/parallels-vm.log: the VM state changes ('Vm state was changed from
VMS_RUNNING to VMS_STOPPING … (name='Debian GNU Linux')'), start/stop/suspend commands and
configuration-editor commits that fall inside the session window (session.json 'start' − 5 min
… session-end.json 'end' + 1 min, or now). The dispatcher log has no year in its timestamps
('09-14 20:13:43.051 F /disp:…/ …'); each kept line is written with the year prefixed so
analyze.py can parse it. A VM start or stop on a bridged adapter toggles promiscuous mode on
the host NIC, which is what fires the DVS re-scan bursts (plan round 2, H1).
"""
import argparse, json, os, re, sys
from datetime import datetime, timedelta

KEEP = re.compile(r"Vm state was changed|DspCmdVm(Start|Stop|Restart|Reset|Suspend|Resume|Pause)'|"
                  r"RaiseConfigEditor <0x[0-9a-f]+> execution|DspCmdDirVmEditCommit'")
LINE = re.compile(r"^(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.\d+ ")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("--src", default="/Library/Logs/parallels.log")
    a = ap.parse_args()
    try:
        start = datetime.strptime(json.load(open(os.path.join(a.session, "session.json")))["start"][:19], "%Y-%m-%dT%H:%M:%S")
    except (OSError, ValueError, KeyError) as e:
        print(f"parallels-vm-log: no session start ({e})", file=sys.stderr)
        return 1
    try:
        end = datetime.strptime(json.load(open(os.path.join(a.session, "session-end.json")))["end"][:19], "%Y-%m-%dT%H:%M:%S")
    except (OSError, ValueError, KeyError):
        end = datetime.now()
    lo, hi = start - timedelta(minutes=5), end + timedelta(minutes=1)
    try:
        src = open(a.src, errors="replace")
    except OSError as e:
        print(f"parallels-vm-log: {e}", file=sys.stderr)
        return 0   # no Parallels on this machine: nothing to record
    n = 0
    with src, open(os.path.join(a.session, "parallels-vm.log"), "w") as out:
        for line in src:
            m = LINE.match(line)
            if not m or not KEEP.search(line):
                continue
            mo, d, h, mi, s = map(int, m.groups())
            # month-day at or after the session start belongs to the start's year, earlier ones to the end's
            year = start.year if (mo, d) >= (start.month, start.day) else end.year
            try:
                ts = datetime(year, mo, d, h, mi, s)
            except ValueError:
                continue
            if lo <= ts <= hi:
                out.write(f"{year}-{line}")
                n += 1
    print(f"parallels-vm.log: {n} lines ({fmt(lo)} … {fmt(hi)})")
    return 0


def fmt(dt):
    return dt.strftime("%Y-%m-%d %H:%M")


if __name__ == "__main__":
    sys.exit(main())
