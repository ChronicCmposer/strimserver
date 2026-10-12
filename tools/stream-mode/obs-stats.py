#!/usr/bin/env python3
"""obs-stats.py — instrument 3: poll obs-websocket (protocol 5) at 1 Hz.

Stdlib only: a minimal RFC 6455 client (text frames, client-side masking,
ping/pong) talking JSON to obs-websocket. Each tick sends one RequestBatch
(GetStats, GetRecordStatus, GetStreamStatus) and appends a CSV row; output
state changes and ExitStarted are appended to obs-events.log. Reconnects
forever, so it can be started before OBS and survives OBS restarts.

  obs-stats.py --session ~/stream-logs/2026-09-14 [--url ws://127.0.0.1:4455]
               [--config "~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json"]
               [--interval 1]
"""
import argparse, base64, hashlib, json, os, socket, struct, sys, time
from datetime import datetime
from urllib.parse import urlparse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
EV_GENERAL, EV_OUTPUTS = 1 << 0, 1 << 6


def ts():
    return datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def log(msg):
    print(f"{ts()} [obs-stats] {msg}", flush=True)


class WS:
    """Just enough WebSocket for obs-websocket: one text frame in, one out."""

    def __init__(self, url, timeout=5.0):
        u = urlparse(url)
        self.host, self.port = u.hostname, u.port or 4455
        self.path = u.path or "/"
        self.sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {self.path} HTTP/1.1\r\nHost: {self.host}:{self.port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
               "Sec-WebSocket-Protocol: obswebsocket.json\r\n\r\n")
        self.sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("closed during handshake")
            resp += chunk
        head, _, rest = resp.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise ConnectionError(f"handshake rejected: {status.decode(errors='replace')}")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        if accept.encode() not in head:
            raise ConnectionError("bad Sec-WebSocket-Accept")
        self.buf = rest

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode, payload=b""):
        mask = os.urandom(4)
        n = len(payload)
        hdr = bytes([0x80 | opcode])
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack("!Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(hdr + mask + masked)

    def send_text(self, s):
        self._send_frame(0x1, s.encode())

    def recv_text(self):
        """Next complete text message (control frames handled inline)."""
        message, fragments = None, []
        while message is None:
            b0, b1 = self._read(2)
            fin, opcode, masked, n = b0 & 0x80, b0 & 0x0F, b1 & 0x80, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            mask = self._read(4) if masked else None
            payload = self._read(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x9:                      # ping → pong
                self._send_frame(0xA, payload)
            elif opcode == 0xA:                    # pong
                pass
            elif opcode == 0x8:                    # close
                try:
                    self._send_frame(0x8, payload[:2])
                finally:
                    raise ConnectionError(f"server closed: {payload[2:].decode(errors='replace')}")
            elif opcode in (0x1, 0x0):
                fragments.append(payload)
                if fin:
                    message = b"".join(fragments).decode()
            elif opcode == 0x2:
                raise ConnectionError("unexpected binary frame (msgpack?)")
        return message

    def close(self):
        try:
            self._send_frame(0x8, struct.pack("!H", 1000))
        except OSError:
            pass
        self.sock.close()


class OBS:
    def __init__(self, url, password, events_path):
        self.ws = WS(url)
        self.events_path = events_path
        self.seq = 0
        hello = self.recv_op(0)["d"]
        auth = None
        if "authentication" in hello:
            if not password:
                raise ConnectionError("obs-websocket requires a password but none was found")
            a = hello["authentication"]
            secret = base64.b64encode(hashlib.sha256((password + a["salt"]).encode()).digest()).decode()
            auth = base64.b64encode(hashlib.sha256((secret + a["challenge"]).encode()).digest()).decode()
        ident = {"rpcVersion": 1, "eventSubscriptions": EV_GENERAL | EV_OUTPUTS}
        if auth:
            ident["authentication"] = auth
        self.send({"op": 1, "d": ident})
        self.recv_op(2)
        self.version = hello.get("obsWebSocketVersion")

    def send(self, obj):
        self.ws.send_text(json.dumps(obj))

    def event(self, d):
        et = d.get("eventType")
        if et in ("RecordStateChanged", "StreamStateChanged", "ReplayBufferStateChanged", "VirtualcamStateChanged"):
            ed = d.get("eventData", {})
            line = f"{ts()}\t{et}\t{ed.get('outputState')}\tactive={ed.get('outputActive')}\t{ed.get('outputPath', '')}"
        elif et == "ExitStarted":
            line = f"{ts()}\tExitStarted"
        else:
            return
        with open(self.events_path, "a") as f:
            f.write(line + "\n")
        log(line.split("\t", 1)[1])

    def recv_op(self, want, deadline=10.0):
        end = time.time() + deadline
        while time.time() < end:
            msg = json.loads(self.ws.recv_text())
            if msg.get("op") == 5:
                self.event(msg["d"])
                continue
            if msg.get("op") == want:
                return msg
            if msg.get("op") in (7, 9):           # stale response from a timed-out tick
                continue
            raise ConnectionError(f"unexpected op {msg.get('op')}")
        raise TimeoutError(f"no op {want} within {deadline}s")

    def request(self, rtype, data=None):
        self.seq += 1
        rid = f"r{self.seq}"
        d = {"requestType": rtype, "requestId": rid}
        if data:
            d["requestData"] = data
        self.send({"op": 6, "d": d})
        while True:
            msg = self.recv_op(7)
            if msg["d"]["requestId"] == rid:
                return msg["d"].get("responseData", {})

    def batch(self, types):
        self.seq += 1
        rid = f"b{self.seq}"
        reqs = [{"requestType": t, "requestId": f"{rid}.{i}"} for i, t in enumerate(types)]
        self.send({"op": 8, "d": {"requestId": rid, "haltOnFailure": False, "executionType": 0, "requests": reqs}})
        while True:
            msg = self.recv_op(9)
            if msg["d"]["requestId"] == rid:
                out = {}
                for r in msg["d"]["results"]:
                    out[r["requestType"]] = r.get("responseData", {}) if r["requestStatus"].get("result") else {}
                return out


COLUMNS = ["ts", "active_fps", "avg_render_ms", "render_skipped", "render_total", "output_skipped",
           "output_total", "cpu_pct", "mem_mb", "disk_free_gb", "rec_active", "rec_paused", "rec_timecode",
           "rec_bytes", "stream_active", "stream_reconnecting", "stream_congestion", "stream_skipped",
           "stream_total", "ws_in", "ws_out"]


def row(res):
    s, r, st = res.get("GetStats", {}), res.get("GetRecordStatus", {}), res.get("GetStreamStatus", {})
    b = lambda v: "" if v is None else int(bool(v))
    f = lambda v, nd=2: "" if v is None else f"{v:.{nd}f}"
    cpu = s.get("cpuUsage")
    if cpu is not None and cpu < 0:
        cpu = None   # GetStats occasionally returns a large negative cpuUsage; not a measurement
    return [ts(), f(s.get("activeFps"), 2), f(s.get("averageFrameRenderTime"), 3), s.get("renderSkippedFrames", ""),
            s.get("renderTotalFrames", ""), s.get("outputSkippedFrames", ""), s.get("outputTotalFrames", ""),
            f(cpu, 2), f(s.get("memoryUsage"), 1), f(s.get("availableDiskSpace", 0) / 1024 if s.get("availableDiskSpace") is not None else None, 2),
            b(r.get("outputActive")), b(r.get("outputPaused")), r.get("outputTimecode", ""), r.get("outputBytes", ""),
            b(st.get("outputActive")), b(st.get("outputReconnecting")), f(st.get("outputCongestion"), 3),
            st.get("outputSkippedFrames", ""), st.get("outputTotalFrames", ""),
            s.get("webSocketSessionIncomingMessages", ""), s.get("webSocketSessionOutgoingMessages", "")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", default=os.environ.get("STREAM_SESSION"), required=os.environ.get("STREAM_SESSION") is None)
    ap.add_argument("--url", default=os.environ.get("OBS_WS_URL", "ws://127.0.0.1:4455"))
    ap.add_argument("--config", default=os.environ.get("OBS_WS_CONFIG", os.path.expanduser(
        "~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")))
    ap.add_argument("--interval", type=float, default=float(os.environ.get("OBS_STATS_INTERVAL", "1")))
    ap.add_argument("--once", action="store_true", help="one sample, then exit (testing)")
    a = ap.parse_args()

    csv_path = os.path.join(a.session, "obs-stats.csv")
    events_path = os.path.join(a.session, "obs-events.log")
    if not os.path.exists(csv_path) or os.path.getsize(csv_path) == 0:
        with open(csv_path, "a") as f:
            f.write(",".join(COLUMNS) + "\n")
    password = None
    try:
        with open(a.config) as f:
            cfg = json.load(f)
        password = cfg.get("server_password") if cfg.get("auth_required") else None
        if not cfg.get("server_enabled"):
            log(f"warning: server_enabled is false in {a.config}")
    except (OSError, ValueError) as e:
        log(f"warning: cannot read obs-websocket config ({e}); trying without auth")

    backoff_logged = False
    while True:
        try:
            obs = OBS(a.url, password, events_path)
            for _ in range(60):   # obs-websocket listens before OBS is ready and answers NotReady meanwhile
                v = obs.request("GetVersion")
                if v:
                    break
                time.sleep(1)
            log(f"connected: OBS {v.get('obsVersion')} obs-websocket {v.get('obsWebSocketVersion')} rpc {v.get('rpcVersion')}")
            with open(events_path, "a") as f:
                f.write(f"{ts()}\tConnected\tOBS {v.get('obsVersion')}\n")
            backoff_logged = False
            while True:
                t0 = time.time()
                res = obs.batch(["GetStats", "GetRecordStatus", "GetStreamStatus"])
                if res.get("GetStats"):   # no row without stats (an empty first row breaks the counter arithmetic)
                    with open(csv_path, "a") as f:
                        f.write(",".join(str(x) for x in row(res)) + "\n")
                if a.once:
                    print(",".join(str(x) for x in row(res)))
                    obs.ws.close()
                    return 0
                time.sleep(max(0.0, a.interval - (time.time() - t0)))
        except (OSError, ConnectionError, TimeoutError, ValueError, KeyError) as e:
            if not backoff_logged:
                log(f"not connected ({e.__class__.__name__}: {e}); retrying every 5 s")
                backoff_logged = True
            if a.once:
                return 1
            time.sleep(5)
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    sys.exit(main())
