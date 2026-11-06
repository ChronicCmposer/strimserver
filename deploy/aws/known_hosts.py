#!/usr/bin/env python3
"""Dedicated private known_hosts store for the strimserver AWS scripts.

The operator's default SSH known_hosts file is never read or written. Ephemeral
EC2 instances routinely reuse a public IP, so a stale key is the normal case and
would otherwise abort a connection with "REMOTE HOST IDENTIFICATION HAS
CHANGED" before cloud-init has even finished. This module owns the one private
store (``$XDG_STATE_HOME/strimserver/known_hosts`` by default) plus the helpers
that prune it and record which instance each host belongs to.

Everything here is intentionally small and side-effect free on import: callers
decide when to create the 0700 directory, and a failure to create or secure it
raises ``KnownHostsError`` instead of silently leaving the store world-readable.
"""

import fcntl
import os
import subprocess
import tempfile
import time

KNOWN_HOSTS_ENV = "STRIMSERVER_KNOWN_HOSTS_FILE"
LOCK_TIMEOUT_ENV = "STRIMSERVER_KNOWN_HOSTS_LOCK_TIMEOUT"
LOCK_TIMEOUT_DEFAULT = 30.0
MAP_SUFFIX = ".instances"
STRICT_HOST_KEY_CHECKING = "accept-new"

# ssh reports a stale key with one of these; both mean "prune this host".
HOST_KEY_MISMATCH_MARKERS = (
    "Host key verification failed",
    "REMOTE HOST IDENTIFICATION HAS CHANGED",
)


class KnownHostsError(RuntimeError):
    """The private store could not be created, secured, or rewritten."""


def known_hosts_path(env=None):
    """Absolute path of the private known_hosts file.

    ``STRIMSERVER_KNOWN_HOSTS_FILE`` wins; otherwise the store lives under
    ``${XDG_STATE_HOME:-$HOME/.local/state}/strimserver/known_hosts``. Raising
    here (rather than returning a bogus relative path) keeps a missing HOME from
    silently writing a store into the current directory.
    """
    env = os.environ if env is None else env
    override = env.get(KNOWN_HOSTS_ENV, "").strip()
    if override:
        return os.path.abspath(os.path.expanduser(override))

    state_home = env.get("XDG_STATE_HOME", "").strip()
    if not state_home:
        home = env.get("HOME", "").strip()
        if not home:
            raise KnownHostsError(
                "cannot locate the private known_hosts store: set "
                f"{KNOWN_HOSTS_ENV}, XDG_STATE_HOME, or HOME")
        state_home = os.path.join(home, ".local", "state")
    return os.path.abspath(os.path.join(
        os.path.expanduser(state_home), "strimserver", "known_hosts"))


def ensure_known_hosts_dir(path=None):
    """Create the store's parent directory with mode 0700 and return it.

    Safe to call repeatedly. A mkdir/chmod failure is fatal: the store holds
    host keys and instance ids, so leaving it world-readable is a real error,
    not a best-effort nicety.
    """
    path = path or known_hosts_path()
    directory = os.path.dirname(os.path.abspath(path))
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
    except OSError as exc:
        raise KnownHostsError(
            f"could not create or secure the private known_hosts directory "
            f"{directory} (mode 0700): {exc}") from exc
    return directory


def ssh_options(path=None):
    """The ``-o`` options every ssh invocation must carry."""
    path = path or known_hosts_path()
    return [
        "-o", f"StrictHostKeyChecking={STRICT_HOST_KEY_CHECKING}",
        "-o", f"UserKnownHostsFile={path}",
    ]


def scp_options(path=None):
    """scp accepts the same ``-o`` options; only its port flag differs (-P)."""
    return ssh_options(path)


def _forget_host_unlocked(host, path):
    """Remove a host without taking the map lock (caller already holds it)."""
    if not host:
        return False
    try:
        subprocess.run(
            ["ssh-keygen", "-f", path, "-R", host],
            capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return False
    return True


def forget_host(host, path=None):
    """Remove every key for ``host`` from the private store.

    Quiet and tolerant of an absent file/entry, so it is safe before the first
    connection of a run. Returns True when ssh-keygen ran, False when it could
    not (e.g. not installed) - pruning is never allowed to fail the caller.
    The file is mutated under the same map lock as bind_host_instance: an
    unlocked ssh-keygen -R can race a concurrent bind's stale-row prune.
    """
    if not host:
        return False
    path = path or known_hosts_path()
    ensure_known_hosts_dir(path)
    with _MapLock(instance_map_path(path)):
        return _forget_host_unlocked(host, path)


def is_host_key_mismatch(stderr):
    """True when ssh's stderr is the stale-host-key signature."""
    return any(marker in (stderr or "") for marker in HOST_KEY_MISMATCH_MARKERS)


def prune_command(host, path=None):
    """The exact remediation command printed when a stale key persists."""
    return f"ssh-keygen -f {path or known_hosts_path()} -R {host}"


def instance_map_path(path=None):
    """Path of the host -> instance-id binding map beside the store."""
    return (path or known_hosts_path()) + MAP_SUFFIX


def _lock_timeout(env=None):
    raw = (os.environ if env is None else env).get(LOCK_TIMEOUT_ENV, "").strip()
    if not raw:
        return LOCK_TIMEOUT_DEFAULT
    try:
        seconds = float(raw)
    except ValueError as exc:
        raise KnownHostsError(
            f"{LOCK_TIMEOUT_ENV} must be a positive number of seconds "
            f"(got {raw!r})") from exc
    if seconds <= 0:
        raise KnownHostsError(
            f"{LOCK_TIMEOUT_ENV} must be a positive number of seconds "
            f"(got {raw!r})")
    return seconds


class _MapLock:
    """Exclusive, bounded lock around a map read-modify-write."""

    def __init__(self, map_path, timeout=None):
        self._lock_path = map_path + ".lock"
        self._timeout = _lock_timeout() if timeout is None else timeout
        self._fd = None

    def __enter__(self):
        try:
            self._fd = os.open(self._lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        except OSError as exc:
            raise KnownHostsError(
                f"could not open the instance map lock {self._lock_path}: "
                f"{exc}") from exc

        deadline = time.monotonic() + self._timeout
        while True:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(self._fd)
                    self._fd = None
                    raise KnownHostsError(
                        f"could not acquire the instance map lock "
                        f"{self._lock_path} within {self._timeout:g}s "
                        f"(a stale lock holder?); refusing to block")
                time.sleep(0.05)

    def __exit__(self, exc_type, exc, tb):
        if self._fd is not None:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)
            self._fd = None
        return False


def _read_map(map_path):
    """Parse ``<host> <instance-id>`` rows, ignoring malformed lines."""
    rows = []
    try:
        with open(map_path, encoding="utf-8") as fh:
            for line in fh:
                fields = line.split()
                if len(fields) == 2:
                    rows.append((fields[0], fields[1]))
    except FileNotFoundError:
        return []
    return rows


def _write_map_atomic(map_path, rows):
    """Replace the map via a unique sibling temp + os.replace."""
    directory = os.path.dirname(os.path.abspath(map_path))
    try:
        fd, tmp = tempfile.mkstemp(
            prefix=os.path.basename(map_path) + ".", dir=directory)
    except OSError as exc:
        raise KnownHostsError(
            f"could not create a temp file beside the instance map "
            f"{map_path}: {exc}") from exc

    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for host, instance_id in rows:
                fh.write(f"{host} {instance_id}\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, map_path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise KnownHostsError(
            f"could not rewrite the instance map {map_path}: {exc}") from exc


def bind_host_instance(host, instance_id, path=None):
    """Record ``host -> instance_id``, self-healing a reused host.

    When ``host`` was last bound to a DIFFERENT instance, every host bound to
    that old instance is forgotten from the known_hosts store before the new
    binding is recorded. This is what makes a relaunch that reused an IP or
    name self-healing without operator intervention.
    """
    if not host or not instance_id:
        return
    path = path or known_hosts_path()
    ensure_known_hosts_dir(path)
    map_path = instance_map_path(path)
    with _MapLock(map_path):
        rows = _read_map(map_path)
        recorded = next((iid for h, iid in rows if h == host), "")
        if recorded and recorded != instance_id:
            for stale_host in (h for h, iid in rows if iid == recorded):
                _forget_host_unlocked(stale_host, path)
            rows = [(h, iid) for h, iid in rows if iid != recorded]
        rows = [(h, iid) for h, iid in rows if h != host]
        rows.append((host, instance_id))
        _write_map_atomic(map_path, rows)


def forget_instance(instance_id, path=None):
    """Forget every host bound to ``instance_id`` and drop its map rows."""
    if not instance_id:
        return
    path = path or known_hosts_path()
    ensure_known_hosts_dir(path)
    map_path = instance_map_path(path)
    with _MapLock(map_path):
        # The existence check lives inside the lock so a concurrent writer
        # creating/removing the map cannot make us skip a real forget.
        if not os.path.exists(map_path):
            return
        rows = _read_map(map_path)
        for stale_host in (h for h, iid in rows if iid == instance_id):
            _forget_host_unlocked(stale_host, path)
        _write_map_atomic(
            map_path, [(h, iid) for h, iid in rows if iid != instance_id])
