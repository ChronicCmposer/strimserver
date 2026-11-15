#!/usr/bin/env python3
"""Pure-stdlib RED tests for deploy/aws/setup_strimserver NVMe selection.

Run directly with `python3 deploy/aws/setup_strimserver_test.py` or through the
Bazel `//deploy/aws:setup_strimserver_test` sh_test wrapper. No live SSH or AWS
is used: every remote interaction goes through an injected probe callable that
returns `(returncode, stdout)`, and every mutating action goes through an
injected runner callable.

Probe/runner contract implemented by the module under test:

    probe(host, user, port, cmd) -> (returncode: int, stdout: str)
    run(host, user, port, cmd)  -> None

Remote commands used by the selector (the fake probe matches on these):
  * enumerate whole disks:   lsblk -dnrno NAME,TYPE
  * model via the nvme CLI:  nvme id-ctrl <dev>
  * model via sysfs:         cat /sys/block/<name>/device/model
  * canonicalize:            realpath -e <path>
  * block-device check:      test -b <path>

The safety probe additionally reads these (lsblk uses `-P` key=value output so
empty columns stay unambiguous):
  * root source:             findmnt -n -o SOURCE --mountpoint /
  * root ancestors:          lsblk -P -s -n -o NAME,PKNAME <root-source>
  * mount target for dev:    findmnt -n -o TARGET --source <dev>
  * disk rows:               lsblk -P -n -o MOUNTPOINT,NAME,TYPE,FSTYPE,PTTYPE <dev>
  * swap:                    swapon --show=NAME --noheadings
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def _load_setup():
    loader = importlib.machinery.SourceFileLoader(
        "strimserver_setup_under_test", str(HERE / "setup_strimserver"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not build a module spec for setup_strimserver")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


setup = _load_setup()

INSTANCE_STORE = "Amazon EC2 NVMe Instance Storage"
EBS = "Amazon Elastic Block Store"


# Mutating commands the setup flow legitimately runs through `run`. Anything
# else is a surprise and must fail loudly: a silently-permissive runner would
# hide a command that regressed from `probe` (rc-checked) back to `run`
# (check=True), which is exactly how the fresh-host wipe abort went unnoticed.
_EXPECTED_RUN_PATTERNS = (
    "sudo mkdir",
    "sudo mount",
    "sudo chown",
    "sudo mkfs",
    "sudo umount",
    "sudo rm -rf --one-file-system",
    "ctr -n strimserver tasks kill",
    "ctr -n strimserver containers delete",
)


class FakeRemote:
    """Records probe/run calls; the most recently registered match wins.

    Last-wins lets a test inject a failure with `when(fail_needle, ...)` after
    the default success rule without depending on needle length. A probe can be
    made to fail by registering a non-zero `(rc, out)` tuple; a run can be made
    to raise with `fail_run`. `run` refuses any command outside the expected
    mutation surface so a command that silently stops being rc-checked is
    caught by the tests instead of passing as an unexplained success.
    """

    def __init__(self, deploy_rc=0):
        self.calls = []  # [("probe"|"run"|"ssh"|"scp"|"deploy", cmd)]
        self.probe_timeouts = []  # [(cmd, timeout)] for local-bound assertions
        self._rules = []
        self._run_failures = []
        self.deploy_rc = deploy_rc

    def when(self, needle, response):
        self._rules.append((needle, response))
        return self

    def fail_run(self, needle, exc):
        """Make run() raise `exc` for commands containing `needle`."""
        self._run_failures.append((needle, exc))
        return self

    def probe(self, host, user, port, cmd, timeout=None):
        self.calls.append(("probe", cmd))
        self.probe_timeouts.append((cmd, timeout))
        for needle, response in reversed(self._rules):
            if needle in cmd:
                return response(cmd) if callable(response) else response
        return (0, "")

    def run(self, host, user, port, cmd):
        self.calls.append(("run", cmd))
        for needle, exc in reversed(self._run_failures):
            if needle in cmd:
                raise exc
        if not any(pattern in cmd for pattern in _EXPECTED_RUN_PATTERNS):
            raise AssertionError(
                f"unexpected run command (no rule registered): {cmd}")

    # --- main()-flow fakes (ssh/scp/deploy interposition) -------------------

    def ssh_run(self, host, user, port, cmd, capture=False):
        self.calls.append(("ssh", cmd))
        return mock.Mock(returncode=0)

    def scp_to_remote(self, local_path, host, user, port, remote_path):
        self.calls.append(("scp", f"{local_path} -> {remote_path}"))

    def run_deploy(self, host, user, port, cmd):
        self.calls.append(("deploy", cmd))
        return self.deploy_rc

    def commands(self, kind=None):
        return [cmd for k, cmd in self.calls if kind is None or k == kind]

    def first_index(self, kind, needle):
        for index, (k, cmd) in enumerate(self.calls):
            if k == kind and needle in cmd:
                return index
        return None


@contextlib.contextmanager
def captured_output():
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        yield buf


def _disks(*names, model=INSTANCE_STORE):
    return "".join(f"{name} disk\n" for name in names)


def _model_probe(remote, models):
    """Answer nvme-id-ctrl and sysfs model probes for `models` {name: model}."""
    for name, model in models.items():
        remote.when(f"nvme id-ctrl /dev/{name}", (0, f"mn : {model}\n"))
        remote.when(f"cat /sys/block/{name}/device/model", (0, f"{model}\n"))
    return remote


class SelectionTest(unittest.TestCase):
    """Phase 2.1 / 2.2 — pure, model-based selection."""

    def test_root_ebs_plus_instance_store_selects_instance_store(self):
        disks = [("nvme1n1", EBS), ("nvme0n1", INSTANCE_STORE)]
        self.assertEqual(
            setup.select_instance_store_device(disks), "/dev/nvme0n1")

    def test_model_match_ignores_padding_tabs_newlines_and_case(self):
        for model in (
            f"  {INSTANCE_STORE}  ",
            f"\t{INSTANCE_STORE}\n",
            "amazon ec2 nvme instance storage",
            "AMAZON   EC2  NVME INSTANCE STORAGE",
        ):
            with self.subTest(model=model):
                self.assertTrue(setup.is_instance_store(model))

    def test_ebs_model_is_not_instance_store(self):
        self.assertFalse(setup.is_instance_store(EBS))
        self.assertIsNone(
            setup.select_instance_store_device([("nvme1n1", EBS)]))

    def test_multiple_stores_choose_numeric_order_and_warn(self):
        disks = [
            ("nvme10n1", INSTANCE_STORE),
            ("nvme2n1", INSTANCE_STORE),
            ("nvme0n1", INSTANCE_STORE),
        ]
        with captured_output() as out:
            selected = setup.select_instance_store_device(disks)
        self.assertEqual(selected, "/dev/nvme0n1")
        text = out.getvalue()
        self.assertIn("nvme2n1", text)
        self.assertIn("nvme10n1", text)
        self.assertIn("NVME_DEVICE", text)

    def test_numeric_order_beats_lexical_order(self):
        disks = [("nvme10n1", INSTANCE_STORE), ("nvme2n1", INSTANCE_STORE)]
        self.assertEqual(
            setup.select_instance_store_device(disks), "/dev/nvme2n1")

    def test_no_instance_store_returns_none(self):
        self.assertIsNone(setup.select_instance_store_device([]))
        self.assertIsNone(setup.select_instance_store_device(
            [("nvme0n1", "Some other disk")]))


class NoMatchExitTest(unittest.TestCase):
    """Phase 2.3 — caller fails with the fixed message."""

    def test_auto_prepare_exits_with_exact_message(self):
        remote = FakeRemote()
        remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme1n1")))
        _model_probe(remote, {"nvme1n1": EBS})
        # The unmounted-branch wipe must succeed before device selection runs.
        remote.when("findmnt -rn -o TARGET", (0, ""))
        remote.when("systemctl show -p KillMode", (0, "KillMode=process\n"))
        remote.when("ctr -n strimserver tasks list", (0, ""))
        remote.when("pgrep -a containerd-shim", (1, ""))
        remote.when("test -e /var/lib/strimserver/driver-upgrade.state", (1, ""))
        remote.when("test -e /mnt/nvme/", (1, ""))
        remote.when("ls -A /mnt/nvme", (0, ""))
        with mock.patch.dict(os.environ, {"NVME_DEVICE": ""}):
            with self.assertRaises(SystemExit) as ctx:
                setup.prepare_nvme("host", "user", 22, "auto",
                                   probe=remote.probe, run=remote.run)
        self.assertIn(
            "no Amazon EC2 NVMe Instance Storage device found; "
            "set NVME_DEVICE=/dev/nvmeXn1 explicitly",
            str(ctx.exception))


class OverrideTest(unittest.TestCase):
    """Phase 2.4 — NVME_DEVICE normalization and validation."""

    def _resolve(self, value, remote):
        with mock.patch.dict(os.environ, {"NVME_DEVICE": value}):
            return setup.resolve_nvme_device("h", "u", 22, remote.probe)

    def _valid_probe(self, canonical="/dev/nvme0n1"):
        remote = FakeRemote()
        remote.when(f"realpath -e {canonical}", (0, canonical))
        remote.when(f"test -b {canonical}", (0, ""))
        return remote

    def test_absolute_path_is_honored(self):
        remote = self._valid_probe()
        self.assertEqual(self._resolve("/dev/nvme0n1", remote), "/dev/nvme0n1")

    def test_bare_name_is_normalized(self):
        remote = self._valid_probe()
        remote.when("realpath -e /dev/nvme0n1", (0, "/dev/nvme0n1"))
        self.assertEqual(self._resolve("nvme0n1", remote), "/dev/nvme0n1")

    def test_empty_and_whitespace_fall_back_to_model_selection(self):
        for value in ("", "   ", "\t\n"):
            with self.subTest(value=value):
                remote = FakeRemote()
                remote.when("lsblk -dnrno NAME,TYPE",
                            (0, _disks("nvme0n1")))
                _model_probe(remote, {"nvme0n1": INSTANCE_STORE})
                self.assertEqual(
                    self._resolve(value, remote), "/dev/nvme0n1")

    def test_by_id_alias_is_realpath_normalized(self):
        remote = FakeRemote()
        alias = "/dev/disk/by-id/nvme-Amazon_EC2_NVMe_Instance_Storage_XYZ"
        remote.when(f"realpath -e {alias}", (0, "/dev/nvme0n1"))
        remote.when("test -b /dev/nvme0n1", (0, ""))
        self.assertEqual(self._resolve(alias, remote), "/dev/nvme0n1")

    def test_rejected_values_exit_before_use(self):
        for value in (
            "/dev/nvme0n1p1",          # partition
            "/dev/nvme0n1; rm -rf /",  # shell metacharacter
            "/dev/nvme 0n1",           # whitespace
            "/dev/../etc/passwd",      # traversal
            "/dev/$(touch x)",         # command substitution
            "/dev/`touch x`",          # backtick
        ):
            with self.subTest(value=value):
                remote = FakeRemote()
                remote.when("realpath -e", (0, "/dev/nvme0n1"))
                remote.when("test -b", (0, ""))
                with self.assertRaises(SystemExit):
                    self._resolve(value, remote)

    def test_nonexistent_path_is_rejected(self):
        remote = FakeRemote()
        remote.when("realpath -e", (1, ""))
        with self.assertRaises(SystemExit):
            self._resolve("/dev/nvme9n9", remote)

    def test_non_block_device_is_rejected(self):
        remote = FakeRemote()
        remote.when("realpath -e", (0, "/dev/nvme0n1"))
        remote.when("test -b", (1, ""))
        with self.assertRaises(SystemExit):
            self._resolve("/dev/nvme0n1", remote)


def _safety_probe(*, dev="/dev/nvme0n1", block=True,
                  root="/dev/nvme1n1p1",
                  root_chain=("nvme1n1p1", "nvme1n1"),
                  root_rc=0, mounted=None,
                  rows=None, swap=(), fail_needle=None):
    """Build a probe answering the assert_safe_nvme_target command set."""
    remote = FakeRemote()
    remote.when(f"test -b {dev}", (0, "") if block else (1, ""))
    remote.when("findmnt -n -o SOURCE --mountpoint /",
                (root_rc, root if root_rc == 0 else ""))
    chain = "".join(f'NAME="{name}" PKNAME="{parent}"\n'
                    for name, parent in
                    ([(root_chain[0], "")] if len(root_chain) == 1
                     else [(root_chain[0], root_chain[1])])
                    )
    if len(root_chain) > 2:
        chain += "".join(f'NAME="{name}" PKNAME=""\n'
                         for name in root_chain[2:])
    remote.when("lsblk -P -s", (0, chain))
    remote.when(f"findmnt -n -o TARGET --source {dev}",
                (0, mounted) if mounted else (1, ""))
    default_rows = f'NAME="{Path(dev).name}" TYPE="disk" FSTYPE="" PTTYPE="" MOUNTPOINT=""\n'
    remote.when(f"lsblk -P -n -o MOUNTPOINT,NAME,TYPE,FSTYPE,PTTYPE {dev}",
                (0, default_rows if rows is None else rows))
    remote.when("swapon --show=NAME --noheadings", (0, "".join(f"{s}\n" for s in swap)))
    if fail_needle:
        remote.when(fail_needle, (255, ""))
    return remote


class SafetyTest(unittest.TestCase):
    """Phase 2.5 — assert_safe_nvme_target refuses unsafe targets."""

    def _assert_refuses(self, remote, needle, dev="/dev/nvme0n1"):
        with self.assertRaises(SystemExit) as ctx:
            setup.assert_safe_nvme_target("h", "u", 22, dev, remote.probe)
        self.assertIn(needle, str(ctx.exception))

    def test_blank_instance_store_disk_is_accepted(self):
        setup.assert_safe_nvme_target(
            "h", "u", 22, "/dev/nvme0n1", _safety_probe().probe)

    def test_root_disk_through_root_partition_is_refused(self):
        remote = _safety_probe(dev="/dev/nvme1n1",
                               root="/dev/nvme1n1p1",
                               root_chain=("nvme1n1p1", "nvme1n1"))
        self._assert_refuses(remote, "it backs the root filesystem",
                             dev="/dev/nvme1n1")

    def test_btrfs_root_suffix_is_resolved(self):
        remote = _safety_probe(dev="/dev/nvme1n1",
                               root="/dev/nvme1n1p1[/@root]",
                               root_chain=("nvme1n1p1", "nvme1n1"))
        self._assert_refuses(remote, "it backs the root filesystem",
                             dev="/dev/nvme1n1")

    def test_mounted_at_mnt_nvme_is_refused(self):
        remote = _safety_probe(mounted="/mnt/nvme")
        self._assert_refuses(remote, "it is mounted at /mnt/nvme")

    def test_mounted_elsewhere_is_refused(self):
        remote = _safety_probe(mounted="/data")
        self._assert_refuses(remote, "it is mounted at /data")

    def test_child_partition_is_refused(self):
        rows = ('NAME="nvme0n1" TYPE="disk" FSTYPE="" PTTYPE="gpt" MOUNTPOINT=""\n'
                'NAME="nvme0n1p1" TYPE="part" FSTYPE="ext4" PTTYPE="" MOUNTPOINT=""\n')
        remote = _safety_probe(rows=rows)
        self._assert_refuses(remote, "it has partitions")

    def test_partition_table_is_refused(self):
        rows = 'NAME="nvme0n1" TYPE="disk" FSTYPE="" PTTYPE="gpt" MOUNTPOINT=""\n'
        remote = _safety_probe(rows=rows)
        self._assert_refuses(remote, "it has partitions")

    def test_swap_target_is_refused(self):
        remote = _safety_probe(swap=("nvme0n1",))
        with self.assertRaises(SystemExit):
            setup.assert_safe_nvme_target(
                "h", "u", 22, "/dev/nvme0n1", remote.probe)

    def test_non_block_device_is_refused(self):
        remote = _safety_probe(block=False)
        self._assert_refuses(remote, "is not an existing block device")

    def test_unresolved_root_probe_is_refused(self):
        remote = _safety_probe(root_rc=255)
        self._assert_refuses(remote, "could not verify")

    def test_failed_safety_probe_is_refused(self):
        remote = _safety_probe(fail_needle="swapon --show=NAME")
        self._assert_refuses(remote, "could not verify")


class ResolveProbeTest(unittest.TestCase):
    """Phase 2.6 — resolve_nvme_device with a fake probe."""

    def _resolve(self, remote):
        with mock.patch.dict(os.environ, {"NVME_DEVICE": ""}):
            return setup.resolve_nvme_device("h", "u", 22, remote.probe)

    def test_nvme_cli_match(self):
        remote = FakeRemote()
        remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme1n1", "nvme0n1")))
        _model_probe(remote, {"nvme1n1": EBS, "nvme0n1": INSTANCE_STORE})
        self.assertEqual(self._resolve(remote), "/dev/nvme0n1")

    def test_nvme_cli_non_match_returns_none(self):
        remote = FakeRemote()
        remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme1n1")))
        _model_probe(remote, {"nvme1n1": EBS})
        self.assertIsNone(self._resolve(remote))

    def test_nvme_cli_failure_falls_back_to_sysfs(self):
        remote = FakeRemote()
        remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme0n1")))
        remote.when("nvme id-ctrl", (1, ""))
        remote.when("cat /sys/block/nvme0n1/device/model",
                    (0, f"  {INSTANCE_STORE}\t\n"))
        self.assertEqual(self._resolve(remote), "/dev/nvme0n1")

    def test_nvme_absent_falls_back_to_sysfs(self):
        remote = FakeRemote()
        remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme0n1")))
        remote.when("nvme id-ctrl", (127, ""))
        remote.when("cat /sys/block/nvme0n1/device/model",
                    (0, INSTANCE_STORE))
        self.assertEqual(self._resolve(remote), "/dev/nvme0n1")

    def test_sysfs_padded_model_matches(self):
        remote = FakeRemote()
        remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme0n1")))
        remote.when("nvme id-ctrl", (127, ""))
        remote.when("cat /sys/block/nvme0n1/device/model",
                    (0, "\n\t" + INSTANCE_STORE + "   \n"))
        self.assertEqual(self._resolve(remote), "/dev/nvme0n1")

    def test_nvme0c0n1_style_alias_is_excluded(self):
        remote = FakeRemote()
        remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme0c0n1")))
        _model_probe(remote, {"nvme0c0n1": INSTANCE_STORE})
        self.assertIsNone(self._resolve(remote))


class CheckedProbeTest(unittest.TestCase):
    """Phase 2.7 — ssh_capture_rc return-code fidelity."""

    def _run_rc(self, returncode, stdout):
        completed = mock.Mock(returncode=returncode, stdout=stdout)
        with mock.patch.object(setup.subprocess, "run", return_value=completed):
            return setup.ssh_capture_rc("h", "u", 22, "true")

    def test_success_returns_zero_and_stdout(self):
        self.assertEqual(self._run_rc(0, "value\n"), (0, "value"))

    def test_expected_absence_is_one_empty(self):
        self.assertEqual(self._run_rc(1, ""), (1, ""))

    def test_missing_filesystem_is_two_empty(self):
        self.assertEqual(self._run_rc(2, ""), (2, ""))

    def test_ssh_transport_error_is_255(self):
        self.assertEqual(self._run_rc(255, ""), (255, ""))

    def test_carriage_return_is_stripped(self):
        self.assertEqual(self._run_rc(0, "value\r\n"), (0, "value"))

    def test_ssh_capture_remains_a_string_compatibility_wrapper(self):
        completed = mock.Mock(returncode=0, stdout="value\n")
        with mock.patch.object(setup.subprocess, "run", return_value=completed):
            self.assertEqual(setup.ssh_capture("h", "u", 22, "true"), "value")

    def test_transport_error_refuses_before_destructive_command(self):
        remote = _safety_probe(
            fail_needle="findmnt -n -o TARGET --source /dev/nvme0n1")
        with self.assertRaises(SystemExit) as ctx:
            setup.assert_safe_nvme_target(
                "h", "u", 22, "/dev/nvme0n1", remote.probe)
        self.assertIn("could not verify", str(ctx.exception))


def _prepare_probe(*, mounted="", fs="", model=INSTANCE_STORE,
                   root="/dev/nvme1n1p1", rows=None, swap=(), block=True):
    remote = FakeRemote()
    remote.when("findmnt -n -o SOURCE,FSTYPE --mountpoint /mnt/nvme",
                (0, mounted) if mounted else (1, ""))
    remote.when("findmnt -n /mnt/nvme", (0, mounted) if mounted else (1, ""))
    remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme1n1", "nvme0n1")))
    _model_probe(remote, {"nvme1n1": EBS, "nvme0n1": model})
    remote.when("test -b /dev/nvme0n1", (0, "") if block else (1, ""))
    remote.when("findmnt -n -o SOURCE --mountpoint /", (0, root))
    remote.when("lsblk -P -s",
                (0, 'NAME="nvme1n1p1" PKNAME="nvme1n1"\n'))
    remote.when("findmnt -n -o TARGET --source /dev/nvme0n1", (1, ""))
    default_rows = ('NAME="nvme0n1" TYPE="disk" FSTYPE="" PTTYPE="" MOUNTPOINT=""\n')
    remote.when("lsblk -P -n -o MOUNTPOINT,NAME,TYPE,FSTYPE,PTTYPE /dev/nvme0n1",
                (0, default_rows if rows is None else rows))
    remote.when("swapon --show=NAME --noheadings",
                (0, "".join(f"{s}\n" for s in swap)))
    remote.when("blkid -o value -s TYPE /dev/nvme0n1",
                (0, fs) if fs else (2, ""))
    remote.when("lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT",
                (0, _disks("nvme1n1", "nvme0n1")))
    # Defaults for the unmounted-branch allowlist wipe: nothing mounted, no
    # tasks/shims, marker absent, allowlist already gone, /mnt/nvme empty.
    remote.when("findmnt -rn -o TARGET", (0, ""))
    remote.when("systemctl show -p KillMode containerd.service",
                (0, "KillMode=process\n"))
    remote.when("ctr -n strimserver tasks list", (0, ""))
    remote.when("pgrep -a containerd-shim", (1, ""))
    remote.when("test -e /var/lib/strimserver/driver-upgrade.state", (1, ""))
    for name in ("nvidia-rpm", "containerd", "containerd-state"):
        remote.when(f"test -e /mnt/nvme/{name}", (1, ""))
    remote.when("test -d /mnt/nvme", (0, ""))
    remote.when("ls -A /mnt/nvme", (0, ""))
    return remote


def _wipe_probe(*, fs="ext4", tasks="", shim_alive=False,
                killmode="KillMode=process", marker=False,
                mount_targets=(), remaining_after_unmount=None,
                leftovers=(), final_entries="", dir_exists=True,
                **prepare_kwargs):
    """_prepare_probe plus the unmounted allowlist-wipe probe surface.

    `dir_exists=False` models a host where the image-side cleanup already
    removed /mnt/nvme entirely: the emptiness check must accept the absent
    directory and let `_mount_commands` recreate it.
    """
    remote = _prepare_probe(fs=fs, **prepare_kwargs)
    remote.when("test -e /var/lib/strimserver/driver-upgrade.state",
                (0, "") if marker else (1, ""))
    remote.when("systemctl show -p KillMode containerd.service",
                (0, killmode + "\n"))
    remote.when("ctr -n strimserver tasks list", (0, tasks))
    remote.when("pgrep -a containerd-shim",
                (0, "123 containerd-shim-runc-v2\n") if shim_alive else (1, ""))
    state = {"calls": 0}

    def findmnt_targets(_cmd):
        state["calls"] += 1
        if state["calls"] == 1:
            return (0, "".join(f"{t}\n" for t in mount_targets))
        if remaining_after_unmount is not None:
            return (0, "".join(f"{t}\n" for t in remaining_after_unmount))
        return (0, "")

    remote.when("findmnt -rn -o TARGET", findmnt_targets)
    for name in leftovers:
        remote.when(f"test -e /mnt/nvme/{name}", (0, ""))
    remote.when("test -d /mnt/nvme", (0, "") if dir_exists else (1, ""))
    remote.when("test -e /mnt/nvme 2>&1",
                (1, "") if not dir_exists else (0, ""))
    remote.when("ls -A /mnt/nvme",
                (0, final_entries) if dir_exists else (2, ""))
    return remote


class PrepareNvmeTest(unittest.TestCase):
    """Phase 2.8 — prepare_nvme ordering, idempotency and flags."""

    def test_selection_precedes_blkid_and_safety_precedes_mount_and_mkfs(self):
        remote = _prepare_probe(fs="")
        setup.prepare_nvme("h", "u", 22, "auto",
                           probe=remote.probe, run=remote.run)

        selection = remote.first_index("probe", "lsblk -dnrno NAME,TYPE")
        blkid = remote.first_index("probe", "blkid")
        safety = remote.first_index("probe", "findmnt -n -o SOURCE --mountpoint /")
        mkfs = remote.first_index("run", "mkfs")
        mount = remote.first_index("run", "mount")
        self.assertIsNotNone(selection)
        self.assertIsNotNone(blkid)
        self.assertIsNotNone(safety)
        self.assertIsNotNone(mkfs)
        self.assertIsNotNone(mount)
        self.assertLess(selection, blkid)
        self.assertLess(safety, mkfs)
        self.assertLess(safety, mount)

    def test_existing_filesystem_reuses_without_reformatting(self):
        remote = _prepare_probe(fs="ext4")
        setup.prepare_nvme("h", "u", 22, "auto",
                           probe=remote.probe, run=remote.run)
        self.assertFalse(any("mkfs" in c for c in remote.commands("run")))
        self.assertTrue(any("mount" in c for c in remote.commands("run")))

    def test_second_auto_run_is_idempotent(self):
        remote = _prepare_probe(mounted="nvme0n1 ext4", fs="ext4")
        setup.prepare_nvme("h", "u", 22, "auto",
                           probe=remote.probe, run=remote.run)
        self.assertFalse(any("mkfs" in c for c in remote.commands("run")))
        self.assertFalse(any("mount" in c for c in remote.commands("run")))

    def test_mounted_non_ext4_fails_naming_source(self):
        remote = _prepare_probe(mounted="nvme0n1 xfs")
        with self.assertRaises(SystemExit) as ctx:
            setup.prepare_nvme("h", "u", 22, "auto",
                               probe=remote.probe, run=remote.run)
        self.assertIn("nvme0n1", str(ctx.exception))

    def test_format_while_mounted_refuses(self):
        remote = _prepare_probe(mounted="nvme0n1 ext4")
        with self.assertRaises(SystemExit):
            setup.prepare_nvme("h", "u", 22, "format",
                               probe=remote.probe, run=remote.run,
                               input_fn=lambda _: "")

    def test_no_format_without_filesystem_fails_naming_device(self):
        remote = _prepare_probe(fs="")
        with self.assertRaises(SystemExit) as ctx:
            setup.prepare_nvme("h", "u", 22, "reuse",
                               probe=remote.probe, run=remote.run)
        self.assertIn("/dev/nvme0n1", str(ctx.exception))

    def test_conflicting_flags_error(self):
        with self.assertRaises(SystemExit):
            setup.parse_nvme_mode(["prog", "--format", "--no-format"])

    def test_format_prompt_defaults_to_selected_instance_store(self):
        remote = _prepare_probe(fs="")
        prompts = []

        def fake_input(prompt):
            prompts.append(prompt)
            return ""

        setup.prepare_nvme("h", "u", 22, "format",
                           probe=remote.probe, run=remote.run,
                           input_fn=fake_input)
        self.assertTrue(prompts)
        self.assertIn("/dev/nvme0n1", prompts[0])

    def test_format_prompt_eof_fails(self):
        remote = _prepare_probe(fs="")

        def eof_input(_prompt):
            raise EOFError

        with self.assertRaises(SystemExit):
            setup.prepare_nvme("h", "u", 22, "format",
                               probe=remote.probe, run=remote.run,
                               input_fn=eof_input)

    def test_mkfs_never_runs_on_unsafe_target(self):
        rows = ('NAME="nvme0n1" TYPE="disk" FSTYPE="" PTTYPE="gpt" MOUNTPOINT=""\n'
                'NAME="nvme0n1p1" TYPE="part" FSTYPE="ext4" PTTYPE="" MOUNTPOINT=""\n')
        remote = _prepare_probe(fs="", rows=rows)
        with self.assertRaises(SystemExit):
            setup.prepare_nvme("h", "u", 22, "auto",
                               probe=remote.probe, run=remote.run)
        self.assertFalse(any("mkfs" in c for c in remote.commands("run")))
        self.assertFalse(any("mount" in c for c in remote.commands("run")))


class PrepareNvmeRecoveryTest(unittest.TestCase):
    """Phase 4.5 — refuse an unmounted non-empty /mnt/nvme directory."""

    def test_unmounted_non_empty_directory_refuses(self):
        remote = _prepare_probe(fs="")
        remote.when("ls -A /mnt/nvme", (0, "config/\n"))
        with self.assertRaises(SystemExit) as ctx:
            setup.prepare_nvme("h", "u", 22, "auto",
                               probe=remote.probe, run=remote.run)
        self.assertIn("non-empty", str(ctx.exception))


class SelectOnlyTest(unittest.TestCase):
    """Phase 3.9 — --select-only resolves and verifies without mutating."""

    def test_select_only_prints_device_model_size_and_verdict(self):
        remote = _prepare_probe(fs="")
        remote.when("lsblk -dnrno SIZE /dev/nvme0n1", (0, "116.4G\n"))
        with captured_output() as out:
            setup.select_only_nvme("h", "u", 22, remote.probe)
        text = out.getvalue()
        self.assertIn("/dev/nvme0n1", text)
        self.assertIn("116.4G", text)
        self.assertIn("safety:", text)
        self.assertFalse(remote.commands("run"))
        self.assertFalse(any("blkid" in c for c in remote.commands("probe")))

    def test_select_only_no_match_exits_with_message(self):
        remote = FakeRemote()
        remote.when("lsblk -dnrno NAME,TYPE", (0, _disks("nvme1n1")))
        _model_probe(remote, {"nvme1n1": EBS})
        with mock.patch.dict(os.environ, {"NVME_DEVICE": ""}):
            with self.assertRaises(SystemExit) as ctx:
                setup.select_only_nvme("h", "u", 22, remote.probe)
        self.assertIn("no Amazon EC2 NVMe Instance Storage device found",
                      str(ctx.exception))


class SourceHygieneTest(unittest.TestCase):
    """Phase 2.9 — no hardcoded /dev/nvme1n1 default remains."""

    def test_source_has_no_nvme1n1_literal_default(self):
        source = (HERE / "setup_strimserver").read_text(encoding="utf-8")
        self.assertNotIn('"/dev/nvme1n1"', source)
        self.assertNotIn("'/dev/nvme1n1'", source)


class UnmountedWipeOrderTest(unittest.TestCase):
    """Phase 4.6 — unmounted-branch allowlist wipe runs in the pinned order."""

    def _prepare(self, remote, mode="auto"):
        setup.prepare_nvme("h", "u", 22, mode,
                           probe=remote.probe, run=remote.run)

    def test_prestop_task_kill_containerd_then_wipe_then_mount(self):
        remote = _wipe_probe(
            tasks="TASK      PID    STATUS\n"
                  "strim-workload  1234  RUNNING\n")
        self._prepare(remote)
        idx = remote.first_index
        order = [
            idx("probe", "systemctl stop strimserver.service"),
            idx("probe", "systemctl stop strim-ddns.timer"),
            idx("probe", "systemctl stop strim-ddns.service"),
            idx("probe", "systemctl stop strim-ddns-verify.service"),
            idx("probe", "systemctl show -p KillMode containerd.service"),
            idx("probe", "ctr -n strimserver tasks list"),
            idx("run", "tasks kill -s KILL strim-workload"),
            idx("run", "containers delete strim-workload"),
            idx("probe", "systemctl stop containerd.service"),
            idx("probe", "systemctl stop containerd.socket"),
            idx("probe", "pgrep -a containerd-shim"),
            idx("probe", "findmnt -rn -o TARGET"),
            idx("run", "rm -rf --one-file-system /mnt/nvme/nvidia-rpm"),
            idx("run", "rm -rf --one-file-system /mnt/nvme/containerd"),
            idx("run", "rm -rf --one-file-system /mnt/nvme/containerd-state"),
            idx("run", "mount /dev/nvme0n1 /mnt/nvme"),
        ]
        self.assertNotIn(None, order)
        self.assertEqual(order, sorted(order))

    def test_task_list_kill_and_delete_are_bounded(self):
        remote = _wipe_probe(tasks="TASK PID STATUS\nabc 1 RUNNING\n")
        self._prepare(remote)
        lists = [c for c in remote.commands("probe")
                 if "ctr -n strimserver tasks list" in c]
        kill = [c for c in remote.commands("run") if "tasks kill" in c]
        delete = [c for c in remote.commands("run") if "containers delete" in c]
        self.assertTrue(lists and all("timeout -k 5 10" in c for c in lists))
        self.assertTrue(kill and all("timeout -k 5 10" in c for c in kill))
        self.assertTrue(delete and all("timeout -k 5 10" in c for c in delete))

    def test_wipe_runs_before_mount(self):
        remote = _wipe_probe()
        self._prepare(remote)
        rm = remote.first_index("run", "rm -rf --one-file-system")
        mount = remote.first_index("run", "mount /dev/nvme0n1 /mnt/nvme")
        self.assertLess(rm, mount)

    def test_mounted_branch_never_wipes(self):
        remote = _prepare_probe(mounted="nvme0n1 ext4", fs="ext4")
        self._prepare(remote)
        all_cmds = remote.commands()
        self.assertFalse(any("rm -rf" in c for c in all_cmds))
        self.assertFalse(any("systemctl stop" in c for c in all_cmds))
        self.assertFalse(any("umount" in c for c in all_cmds))


class UnmountedWipeGuardTest(unittest.TestCase):
    """Phase 4.7 — the wipe stays fail-closed around shims, mounts and leftovers."""

    def _refuses(self, remote, needle, mode="auto"):
        with self.assertRaises(SystemExit) as ctx:
            setup.prepare_nvme("h", "u", 22, mode,
                               probe=remote.probe, run=remote.run)
        self.assertIn(needle, str(ctx.exception))
        return ctx

    def test_surviving_shim_refuses_with_reboot_remediation(self):
        remote = _wipe_probe(shim_alive=True)
        self._refuses(remote, "reboot the instance, then rerun setup_strimserver")
        self.assertFalse(any("mount" in c for c in remote.commands("run")))

    def test_shim_refusal_precedes_mount(self):
        remote = _wipe_probe(shim_alive=True)
        self._refuses(remote, "reboot the instance, then rerun setup_strimserver")
        self.assertFalse(any("rm -rf" in c for c in remote.commands("run")))

    def test_nested_containerd_mounts_unmount_deepest_first(self):
        targets = (
            "/mnt/nvme/containerd",
            "/mnt/nvme/containerd/io.containerd.runtime.v2.task/strimserver/x",
            "/mnt/nvme/containerd-state",
        )
        remote = _wipe_probe(mount_targets=targets)
        setup.prepare_nvme("h", "u", 22, "auto",
                           probe=remote.probe, run=remote.run)
        umounts = [c for c in remote.commands("run") if "umount" in c]
        expected = [f"sudo umount {t}" for t in sorted(targets, reverse=True)]
        self.assertEqual(umounts, expected)

    def test_non_allowlisted_mount_under_nvme_refuses(self):
        remote = _wipe_probe(mount_targets=("/mnt/nvme/secrets",))
        self._refuses(remote, "outside the allowlist")
        self.assertFalse(any("umount" in c for c in remote.commands("run")))
        self.assertFalse(any("mount" in c for c in remote.commands("run")))

    def test_remaining_mount_after_unmount_refuses(self):
        remote = _wipe_probe(
            mount_targets=("/mnt/nvme/containerd",),
            remaining_after_unmount=("/mnt/nvme/containerd",))
        self._refuses(remote, "remain")
        self.assertFalse(any("rm -rf" in c for c in remote.commands("run")))

    def test_allowlist_leftover_refuses_before_mount(self):
        remote = _wipe_probe(leftovers=("containerd",))
        self._refuses(remote, "still exists")
        self.assertFalse(any("mount" in c for c in remote.commands("run")))

    def test_unmount_failure_fails_closed(self):
        remote = _wipe_probe(mount_targets=("/mnt/nvme/containerd",))
        remote.fail_run("umount /mnt/nvme/containerd",
                        subprocess.CalledProcessError(1, ["umount"]))
        self._refuses(remote, "could not unmount")
        self.assertFalse(any("mount /dev/nvme0n1 /mnt/nvme" in c
                             for c in remote.commands("run")))
        self.assertFalse(any("rm -rf" in c for c in remote.commands("run")))

    def test_unknown_directory_is_refused_before_mount(self):
        remote = _wipe_probe(final_entries="config/\n")
        self._refuses(remote, "non-empty")
        self.assertFalse(any("mount" in c for c in remote.commands("run")))

    def test_resume_marker_warns_but_is_never_removed(self):
        remote = _wipe_probe(marker=True)
        with captured_output() as out:
            setup.prepare_nvme("h", "u", 22, "auto",
                               probe=remote.probe, run=remote.run)
        text = out.getvalue()
        self.assertIn("driver-upgrade.state", text)
        self.assertIn("warning", text.lower())
        for cmd in remote.commands("run"):
            self.assertNotIn("/var/lib/strimserver/driver-upgrade.state", cmd)

    def test_absent_mnt_nvme_directory_is_permitted(self):
        # The image-side CleanNvmeResidue allows /mnt/nvme to be absent; the
        # wipe must accept that and let _mount_commands recreate it.
        remote = _wipe_probe(dir_exists=False)
        setup.prepare_nvme("h", "u", 22, "auto",
                           probe=remote.probe, run=remote.run)
        self.assertTrue(any("mount /dev/nvme0n1 /mnt/nvme" in c
                            for c in remote.commands("run")))
        # It must not try to list a directory that is not there.
        self.assertFalse(any("ls -A /mnt/nvme" in c
                             for c in remote.commands("probe")))

    def test_absent_mnt_nvme_directory_probe_is_bounded(self):
        remote = _wipe_probe(dir_exists=False)
        setup.prepare_nvme("h", "u", 22, "auto",
                           probe=remote.probe, run=remote.run)
        checks = [c for c in remote.commands("probe")
                  if "test -d /mnt/nvme" in c]
        self.assertTrue(checks)
        for cmd in checks:
            self.assertIn("timeout -k 5 10", cmd)

    def test_mnt_nvme_exists_but_is_not_a_directory_refuses(self):
        # MINOR #5: test -d rc 1 is only "absent" for true ENOENT; a path that
        # exists as another kind of file must refuse naming what it is.
        remote = _wipe_probe(dir_exists=False)
        remote.when("test -d /mnt/nvme", (1, ""))
        remote.when("test -e /mnt/nvme 2>&1", (0, ""))
        remote.when("stat -c %F /mnt/nvme", (0, "regular file\n"))
        with self.assertRaises(SystemExit) as ctx:
            setup.prepare_nvme("h", "u", 22, "auto",
                               probe=remote.probe, run=remote.run)
        message = str(ctx.exception)
        self.assertIn("/mnt/nvme", message)
        self.assertIn("not a directory", message)
        self.assertIn("regular file", message)
        self.assertFalse(any("mount /dev/nvme0n1 /mnt/nvme" in c
                             for c in remote.commands("run")))


def _inject_stop_failure(remote, unit, rc, message):
    """Fail a `systemctl stop <unit>` on both transports.

    The hardened flow issues the stop as an rc-checked probe (so it can read
    the "not loaded" diagnostic); registering the failure for both probe and
    run makes the defect reproducible before the fix and keeps the guard if a
    future refactor routes it back through `run`.
    """
    remote.when(f"systemctl stop {unit}", (rc, message + "\n"))
    remote.fail_run(
        f"systemctl stop {unit}",
        subprocess.CalledProcessError(rc, ["systemctl"], output="", stderr=message))
    return remote


class WipeHardeningTest(unittest.TestCase):
    """Attempt-2 defects: fresh-host stop tolerance, bounds, fail-closed probes."""

    def _prepare(self, remote, mode="auto"):
        return setup.prepare_nvme("h", "u", 22, mode,
                                  probe=remote.probe, run=remote.run)

    def _mounted(self, remote):
        return any("mount /dev/nvme0n1 /mnt/nvme" in c
                   for c in remote.commands("run"))

    # Defect #1: absent repo units on a first run are benign.
    def test_missing_repo_unit_is_benign_and_wipe_continues(self):
        remote = _wipe_probe()
        _inject_stop_failure(
            remote, "strimserver.service", 5,
            "Failed to stop strimserver.service: Unit strimserver.service not loaded.")
        with captured_output() as out:
            self._prepare(remote)
        self.assertIn("not loaded", out.getvalue())
        self.assertTrue(any("rm -rf --one-file-system /mnt/nvme/nvidia-rpm" in c
                            for c in remote.commands("run")))
        self.assertTrue(self._mounted(remote))

    def test_missing_containerd_socket_is_benign(self):
        remote = _wipe_probe()
        _inject_stop_failure(
            remote, "containerd.socket", 5,
            "Failed to stop containerd.socket: Unit containerd.socket not found.")
        self._prepare(remote)
        self.assertTrue(self._mounted(remote))

    # Defect #1: a genuine stop error still fails closed.
    def test_genuine_stop_error_fails_closed(self):
        for message in (
            "Failed to stop strimserver.service: Access denied",
            "sudo: systemctl: command not found",
        ):
            with self.subTest(message=message):
                remote = _wipe_probe()
                _inject_stop_failure(
                    remote, "strimserver.service", 1, message)
                with self.assertRaises(SystemExit) as ctx:
                    self._prepare(remote)
                self.assertIn("could not stop strimserver.service",
                              str(ctx.exception))
                self.assertFalse(any("rm -rf" in c
                                     for c in remote.commands("run")))
                self.assertFalse(self._mounted(remote))

    # Defect #6: unexpected KillMode must fail closed; both renderings pass.
    def test_unexpected_killmode_fails_closed(self):
        remote = _wipe_probe(killmode="KillMode=mixed")
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        self.assertIn("expected 'process'", str(ctx.exception))
        self.assertFalse(any("rm -rf" in c for c in remote.commands("run")))
        self.assertFalse(self._mounted(remote))

    def test_killmode_accepts_both_renderings(self):
        for value in ("process", "KillMode=process"):
            with self.subTest(killmode=value):
                remote = _wipe_probe(killmode=value)
                self._prepare(remote)
                self.assertTrue(self._mounted(remote))

    # Defect #5: a failed emptiness probe must fail closed, never read as empty.
    def test_failed_emptiness_probe_fails_closed(self):
        remote = _wipe_probe()
        remote.when("ls -A /mnt/nvme", (2, ""))
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        self.assertIn("could not verify", str(ctx.exception))
        self.assertFalse(self._mounted(remote))

    def test_emptiness_probe_does_not_suppress_errors(self):
        remote = _wipe_probe()
        self._prepare(remote)
        probes = [c for c in remote.commands("probe") if "ls -A /mnt/nvme" in c]
        self.assertTrue(probes)
        for cmd in probes:
            self.assertNotIn("|| true", cmd)
            self.assertNotIn("2>/dev/null", cmd)


class WipeBoundingTest(unittest.TestCase):
    """Attempt-3 defect #13: every wipe-phase probe and stop is time-bounded."""

    _BOUNDED_PROBE_NEEDLES = (
        "systemctl show -p KillMode containerd.service",
        "findmnt -rn -o TARGET",
        "pgrep -a containerd-shim",
        "ls -A /mnt/nvme",
        "test -d /mnt/nvme",
        "test -e /var/lib/strimserver/driver-upgrade.state",
        "test -e /mnt/nvme/nvidia-rpm",
        "test -e /mnt/nvme/containerd",
        "test -e /mnt/nvme/containerd-state",
    )

    def _prepare(self, remote):
        setup.prepare_nvme("h", "u", 22, "auto",
                           probe=remote.probe, run=remote.run)

    def test_all_wipe_probes_are_bounded(self):
        remote = _wipe_probe(tasks="TASK PID STATUS\nabc 1 RUNNING\n")
        self._prepare(remote)
        probes = remote.commands("probe")
        for needle in self._BOUNDED_PROBE_NEEDLES:
            matches = [c for c in probes if needle in c]
            self.assertTrue(matches, f"no probe issued for {needle!r}")
            for cmd in matches:
                self.assertIn("timeout -k 5 10", cmd,
                              f"unbounded probe: {cmd!r}")

    def test_unit_stops_use_the_generous_bound(self):
        remote = _wipe_probe()
        self._prepare(remote)
        stops = [c for c in remote.commands("probe") if "systemctl stop " in c]
        self.assertTrue(stops)
        for unit in (
            "strimserver.service",
            "strim-ddns.timer",
            "strim-ddns.service",
            "strim-ddns-verify.service",
            "containerd.service",
            "containerd.socket",
        ):
            matching = [c for c in stops if f"systemctl stop {unit}" in c]
            self.assertTrue(matching, f"no stop issued for {unit}")
            for cmd in matching:
                self.assertIn(
                    f"sudo timeout -k 5 120 systemctl stop {unit}", cmd,
                    f"stop without the generous 120s bound: {cmd!r}")

    def test_unit_stop_local_timeout_is_at_least_the_remote_bound(self):
        # The remote stop is bounded at 120s + 5s kill grace. The LOCAL
        # transport timeout must exceed that, or a wedged stop is killed by the
        # client before the remote rc 124/137 can ever be observed.
        self.assertGreaterEqual(setup.SSH_STOP_TIMEOUT, 125)
        remote = _wipe_probe()
        self._prepare(remote)
        stop_timeouts = [timeout for cmd, timeout in remote.probe_timeouts
                         if "systemctl stop " in cmd]
        self.assertTrue(stop_timeouts)
        for timeout in stop_timeouts:
            self.assertIsNotNone(timeout)
            self.assertGreaterEqual(timeout, 125,
                                    "stop probe used a short local timeout")

    # Defect #13: a timed-out KillMode probe must refuse, not warn or pass.
    def test_killmode_probe_timeout_refuses_the_wipe(self):
        for rc in (124, 137):
            with self.subTest(rc=rc):
                remote = _wipe_probe()
                remote.when("systemctl show -p KillMode containerd.service",
                            (rc, ""))
                with self.assertRaises(SystemExit) as ctx:
                    self._prepare(remote)
                self.assertIn("could not verify containerd KillMode",
                              str(ctx.exception))
                self.assertFalse(any("rm -rf" in c
                                     for c in remote.commands("run")))

    # Defect #13: a timed-out unit stop is a failure, NEVER an absent unit.
    def test_stop_timeout_fails_closed_and_is_not_treated_as_absent(self):
        for rc in (124, 137):
            with self.subTest(rc=rc):
                remote = _wipe_probe()
                # The diagnostic deliberately looks like an absent unit; the
                # rc must take precedence so a wedged systemd cannot be waved
                # through as "nothing to stop".
                _inject_stop_failure(
                    remote, "strimserver.service", rc,
                    "Unit strimserver.service not loaded.")
                with self.assertRaises(SystemExit) as ctx:
                    self._prepare(remote)
                message = str(ctx.exception)
                self.assertIn("timed out", message)
                self.assertIn("strimserver.service", message)
                self.assertFalse(any("rm -rf" in c
                                     for c in remote.commands("run")))
                self.assertFalse(any("mount /dev/nvme0n1 /mnt/nvme" in c
                                     for c in remote.commands("run")))


class LocalTransportTimeoutTest(unittest.TestCase):
    """Attempt-3 defect #13: a stalled local ssh transport cannot hang forever."""

    def _sleeping_ssh_stub(self, directory):
        stub = os.path.join(directory, "ssh-hang-stub")
        with open(stub, "w", encoding="utf-8") as handle:
            # `exec` so the shell is replaced by sleep: killing the timed-out
            # child then releases the pipe immediately (a plain `sleep 30`
            # grandchild would hold it for the full duration).
            handle.write("#!/bin/sh\nexec sleep 30\n")
        os.chmod(stub, 0o755)
        return stub

    def test_hung_ssh_exits_one_with_clean_timeout_message(self):
        cases = (
            ("ssh_capture_rc",
             lambda: setup.ssh_capture_rc("h", "u", 22, "probe-cmd"),
             "probe-cmd"),
            ("ssh_run",
             lambda: setup.ssh_run("h", "u", 22, "run-cmd"),
             "run-cmd"),
            ("ssh_write_secret",
             lambda: setup.ssh_write_secret("h", "u", 22, "/tmp/secret", "v"),
             "umask 077"),
        )
        with tempfile.TemporaryDirectory() as directory:
            stub = self._sleeping_ssh_stub(directory)
            for label, call, needle in cases:
                with self.subTest(label=label):
                    env = {"SSH_CMD": stub, "SETUP_SSH_TIMEOUT": "1"}
                    with mock.patch.dict(os.environ, env):
                        with captured_output() as out:
                            with self.assertRaises(SystemExit) as ctx:
                                call()
                    self.assertEqual(ctx.exception.code, 1)
                    text = out.getvalue()
                    self.assertIn("timed out", text)
                    self.assertIn("1s", text)
                    self.assertIn(needle, text)
                    self.assertNotIn("Traceback", text)

    def test_stop_path_local_timeout_fires_through_run_ssh(self):
        # MINOR #7: drive the real _run_ssh/subprocess timeout layer for a
        # stop rather than injecting rc 124 via the fake probe. A tiny
        # SETUP_SSH_TIMEOUT override lets the local bound fire quickly; the
        # production bound must still cover the remote 120s stop + 5s grace.
        self.assertGreaterEqual(setup.SSH_STOP_TIMEOUT, 125)
        with tempfile.TemporaryDirectory() as directory:
            stub = self._sleeping_ssh_stub(directory)
            env = {"SSH_CMD": stub, "SETUP_SSH_TIMEOUT": "1"}
            with mock.patch.dict(os.environ, env):
                with captured_output() as out:
                    with self.assertRaises(SystemExit) as ctx:
                        setup._stop_unit("h", "u", 22, setup.ssh_capture_rc,
                                         "containerd.service")
        self.assertEqual(ctx.exception.code, 1)
        text = out.getvalue()
        self.assertIn("timed out", text)
        self.assertIn("1s", text)
        self.assertIn("systemctl stop containerd.service", text)
        self.assertNotIn("Traceback", text)

    def test_scp_has_a_local_timeout_converted_cleanly(self):
        with mock.patch.dict(os.environ, {"SETUP_SSH_TIMEOUT": "1"}):
            with mock.patch.object(
                    setup.subprocess, "run",
                    side_effect=subprocess.TimeoutExpired("scp", 1)):
                with captured_output() as out:
                    with self.assertRaises(SystemExit) as ctx:
                        setup.scp_to_remote("/tmp/local", "h", "u", 22, "/remote")
        self.assertEqual(ctx.exception.code, 1)
        text = out.getvalue()
        self.assertIn("timed out", text)
        self.assertIn("1s", text)
        self.assertIn("/tmp/local", text)
        self.assertNotIn("Traceback", text)


class SshTransportOptionsTest(unittest.TestCase):
    """Attempt-3 defect #13: keepalives are centralized and never after the host."""

    _KEEPALIVES = (
        "ConnectTimeout=10",
        "ServerAliveInterval=15",
        "ServerAliveCountMax=4",
    )

    def _argv_for(self, call):
        completed = mock.Mock(returncode=0, stdout="")
        with mock.patch.object(setup.subprocess, "run",
                               return_value=completed) as run:
            call()
        return run.call_args

    def test_probe_argv_places_keepalives_before_destination(self):
        call = self._argv_for(
            lambda: setup.ssh_capture_rc("host", "user", 22, "true"))
        argv = call.args[0]
        destination = argv.index("user@host")
        for option in self._KEEPALIVES:
            self.assertIn(option, argv)
            self.assertLess(argv.index(option), destination)
        self.assertEqual(call.kwargs.get("timeout"), setup.SSH_PROBE_TIMEOUT)

    def test_run_deploy_keeps_keepalives_but_has_no_local_timeout(self):
        call = self._argv_for(
            lambda: setup.run_deploy("host", "user", 22, "deploy"))
        argv = call.args[0]
        for option in self._KEEPALIVES:
            self.assertIn(option, argv)
        self.assertNotIn("timeout", call.kwargs)

    def test_scp_shares_keepalives_and_has_a_local_timeout(self):
        completed = mock.Mock(returncode=0)
        with mock.patch.object(setup.subprocess, "run",
                               return_value=completed) as run:
            setup.scp_to_remote("/tmp/local", "host", "user", 22, "/remote")
        call = run.call_args
        argv = call.args[0]
        destination = argv.index("user@host:/remote")
        for option in self._KEEPALIVES:
            self.assertIn(option, argv)
            self.assertLess(argv.index(option), destination)
        self.assertEqual(call.kwargs.get("timeout"), setup.SSH_COPY_TIMEOUT)


class NonWipeProbeDiagnosticsTest(unittest.TestCase):
    """MINOR #6: non-wipe probe refusals must name the rc and captured output."""

    def _assert_refusal_names(self, remote, needle, *, message_needle,
                              prepare=True):
        with self.assertRaises(SystemExit) as ctx:
            if prepare:
                setup.prepare_nvme("h", "u", 22, "auto",
                                   probe=remote.probe, run=remote.run)
            else:
                setup.assert_safe_nvme_target(
                    "h", "u", 22, "/dev/nvme0n1", remote.probe)
        message = str(ctx.exception)
        self.assertIn(message_needle, message)
        self.assertIn("rc=255", message)
        self.assertIn(needle, message)

    def test_candidate_disk_lsblk_failure_names_rc_and_output(self):
        remote = _prepare_probe(fs="ext4")
        remote.when("lsblk -dnrno NAME,TYPE", (255, "lsblk: transport error"))
        self._assert_refusal_names(
            remote, "lsblk: transport error", message_needle="candidate disks")

    def test_nvme_findmnt_failure_names_rc_and_output(self):
        remote = _prepare_probe(fs="ext4")
        remote.when("findmnt -n -o SOURCE,FSTYPE --mountpoint /mnt/nvme",
                    (255, "findmnt: bus error"))
        self._assert_refusal_names(
            remote, "findmnt: bus error", message_needle="could not verify /mnt/nvme")

    def test_blkid_failure_names_rc_and_output(self):
        remote = _prepare_probe(fs="ext4")
        remote.when("blkid -o value -s TYPE /dev/nvme0n1",
                    (255, "blkid: transport error"))
        self._assert_refusal_names(
            remote, "blkid: transport error", message_needle="blkid failed")

    def test_safety_findmnt_target_failure_names_rc_and_output(self):
        remote = _safety_probe()
        remote.when("findmnt -n -o TARGET --source /dev/nvme0n1",
                    (255, "findmnt: bus error"))
        self._assert_refusal_names(
            remote, "findmnt: bus error",
            message_needle="findmnt target failed", prepare=False)

    def test_safety_lsblk_failure_names_rc_and_output(self):
        remote = _safety_probe()
        remote.when("lsblk -P -n -o MOUNTPOINT,NAME,TYPE,FSTYPE,PTTYPE "
                    "/dev/nvme0n1", (255, "lsblk: bus error"))
        self._assert_refusal_names(
            remote, "lsblk: bus error", message_needle="lsblk failed",
            prepare=False)

    def test_safety_swapon_failure_names_rc_and_output(self):
        remote = _safety_probe()
        remote.when("swapon --show=NAME --noheadings", (255, "swapon: bus error"))
        self._assert_refusal_names(
            remote, "swapon: bus error", message_needle="swapon failed",
            prepare=False)


def _run_main(remote, started, env_overrides=None):
    env = {
        "SSH_HOST": "h",
        "SSH_USER": "u",
        "SSH_PORT": "22",
        "DEPLOYMENT_SRC": "https://example.com/strimserver-deployment-go-amd64.tar",
        "ENABLE_DDNS": "false",
    }
    env.update(env_overrides or {})
    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.dict(os.environ, env, clear=True))
        stack.enter_context(mock.patch.object(
            setup.known_hosts, "ensure_known_hosts_dir", lambda: None))
        stack.enter_context(mock.patch.object(
            setup.known_hosts, "forget_host", lambda host: None))
        stack.enter_context(mock.patch.object(
            setup, "bind_target_instance", lambda host: None))
        stack.enter_context(mock.patch.object(
            setup, "prepare_nvme", lambda *a, **k: None))
        stack.enter_context(mock.patch.object(setup, "ssh_run", remote.ssh_run))
        stack.enter_context(mock.patch.object(
            setup, "run_deploy", remote.run_deploy))
        stack.enter_context(mock.patch.object(
            setup, "scp_to_remote", remote.scp_to_remote))
        stack.enter_context(mock.patch.object(
            setup, "offer_exec_start",
            lambda host, user: started.append((host, user))))
        setup.main(argv=["setup_strimserver"], env=env)


class DeployHandoffTest(unittest.TestCase):
    """Phase 4.8 — deploy rc propagation and clean failure messages."""

    def test_zero_exit_still_offers_start(self):
        remote = FakeRemote(deploy_rc=0)
        started = []
        _run_main(remote, started)
        self.assertEqual(started, [("h", "u")])
        self.assertTrue(any("./deploy.sh" in c for c in remote.commands("deploy")))

    def test_nonzero_exit_propagates_and_skips_start(self):
        expectations = {
            1: "before M1",
            3: "DDNS stage failed",
            4: "backstop timeout",
            5: "another deploy holds the lock",
            129: "interrupted; any in-flight DDNS unit was stopped",
            130: "interrupted; any in-flight DDNS unit was stopped",
            143: "interrupted; any in-flight DDNS unit was stopped",
        }
        for rc, needle in expectations.items():
            with self.subTest(rc=rc):
                remote = FakeRemote(deploy_rc=rc)
                started = []
                with captured_output() as out:
                    with self.assertRaises(SystemExit) as ctx:
                        _run_main(remote, started)
                self.assertEqual(ctx.exception.code, rc)
                self.assertEqual(started, [])
                self.assertIn(needle, out.getvalue())

    def test_exit_three_and_four_print_dns_unverified_hint(self):
        for rc in (3, 4):
            with self.subTest(rc=rc):
                remote = FakeRemote(deploy_rc=rc)
                started = []
                with captured_output() as out:
                    with self.assertRaises(SystemExit):
                        _run_main(remote, started)
                text = out.getvalue()
                self.assertIn("DNS is unverified", text)
                self.assertIn("ssh u@h sudo systemctl start strimserver.service",
                              text)
                self.assertEqual(started, [])

    def test_ssh_255_reports_connection_lost_and_names_log_and_rc(self):
        remote = FakeRemote(deploy_rc=255)
        started = []
        with captured_output() as out:
            with self.assertRaises(SystemExit) as ctx:
                _run_main(remote, started)
        self.assertEqual(ctx.exception.code, 255)
        self.assertEqual(started, [])
        text = out.getvalue()
        self.assertIn("connection lost", text)
        self.assertIn("/mnt/nvme/logs/deploy-", text)
        self.assertIn("deploy-last.rc", text)

    def test_scp_failure_exits_one_with_clean_message(self):
        error = subprocess.CalledProcessError(1, ["scp"])
        with mock.patch.object(setup.subprocess, "run", side_effect=error):
            with captured_output() as out:
                with self.assertRaises(SystemExit) as ctx:
                    setup.scp_to_remote("local", "h", "u", 22, "/mnt/nvme/x")
        self.assertEqual(ctx.exception.code, 1)
        text = out.getvalue()
        self.assertIn("failed", text.lower())
        self.assertNotIn("Traceback", text)

    def test_ssh_run_failure_exits_one_with_clean_message(self):
        error = subprocess.CalledProcessError(7, ["ssh"])
        with mock.patch.object(setup.subprocess, "run", side_effect=error):
            with captured_output() as out:
                with self.assertRaises(SystemExit) as ctx:
                    setup.ssh_run("h", "u", 22, "false")
        self.assertEqual(ctx.exception.code, 1)
        text = out.getvalue()
        self.assertIn("failed", text.lower())
        self.assertNotIn("Traceback", text)


def _killmode_fallback(remote, *, show=(0, "KillMode=process\n"),
                       local=None, run_copy=None, distro=None,
                       dropins=None, dropin_dirs=None,
                       dropin_dir_exists=True, dropin_dir_errors=None,
                       dropin_not_dirs=(), cat_errors=None):
    """Register the manager-independent KillMode file-fallback probe surface.

    `local`, `run_copy` and `distro` are the full-unit copies in /etc, /run and
    /usr/lib. `dropins` maps a *.conf basename to text for the /etc drop-in
    directory; `dropin_dirs` overrides that with an explicit
    {dir: {basename: text}} map. Listings are returned in REVERSE lexical order
    on purpose so the implementation must sort them. `dropin_dir_errors` and
    `cat_errors` inject failures by directory or path; `dropin_not_dirs` models
    a path that exists but is not a directory.
    """
    remote.when("systemctl show -p KillMode containerd.service", show)

    full_units = {
        setup._CONTAINERD_FULL_UNIT_PATHS[0]: local,
        setup._CONTAINERD_FULL_UNIT_PATHS[1]: run_copy,
        setup._CONTAINERD_FULL_UNIT_PATHS[2]: distro,
    }
    for path, text in full_units.items():
        remote.when(f"test -e {path}",
                    (0, "") if text is not None else (1, ""))

    if dropin_dirs is None:
        dropin_dirs = ({setup._CONTAINERD_DROPIN_DIR: dict(dropins or {})}
                       if dropin_dir_exists else {})
    dropin_dir_errors = dropin_dir_errors or {}
    cat_errors = cat_errors or {}

    for directory in setup._CONTAINERD_DROPIN_DIRS:
        mapping = dropin_dirs.get(directory, {})
        if directory in dropin_dir_errors:
            remote.when(f"test -d {directory}", dropin_dir_errors[directory])
        elif directory in dropin_not_dirs:
            remote.when(f"test -d {directory}", (1, ""))
        else:
            remote.when(f"test -d {directory}",
                        (0, "") if directory in dropin_dirs else (1, ""))
        exists = directory in dropin_dirs or directory in dropin_not_dirs
        remote.when(f"test -e {directory}", (0, "") if exists else (1, ""))
        listing = "".join(name + "\n" for name in reversed(sorted(mapping)))
        remote.when(f"ls -1 {directory}", (0, listing))

    def cat_response(cmd):
        tokens = cmd.split()
        path = tokens[tokens.index("cat") + 1]
        if path in full_units:
            text = full_units[path]
            return (0, text + "\n") if text is not None else (1, "")
        for directory, mapping in dropin_dirs.items():
            if path.startswith(directory + "/"):
                name = path.rsplit("/", 1)[-1]
                if name in mapping:
                    return (0, mapping[name] + "\n")
                return (1, "")
        return (1, "")

    remote.when("sudo timeout -k 5 10 cat ", cat_response)
    for path, response in cat_errors.items():
        remote.when(f"cat {path}", response)
    return remote


class WipeProbeDiagnosticsTest(unittest.TestCase):
    """Attempt-4 defect #15a/#15b: refusals carry rc + captured diagnostics."""

    def _prepare(self, remote):
        return setup.prepare_nvme("h", "u", 22, "auto",
                                  probe=remote.probe, run=remote.run)

    def test_killmode_probe_runs_under_sudo(self):
        remote = _wipe_probe()
        self._prepare(remote)
        probes = [c for c in remote.commands("probe")
                  if "systemctl show -p KillMode containerd.service" in c]
        self.assertTrue(probes)
        for cmd in probes:
            self.assertTrue(
                cmd.startswith(
                    "sudo timeout -k 5 10 systemctl show -p KillMode containerd.service"),
                f"KillMode probe must be sudo'd and bounded: {cmd!r}")

    def test_failed_killmode_probe_refusal_names_rc_and_output(self):
        remote = _wipe_probe()
        _killmode_fallback(remote, show=(127, "sudo: systemctl: command not found"),
                           dropin_dir_exists=False)
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        message = str(ctx.exception)
        self.assertIn("rc=127", message)
        self.assertIn("command not found", message)
        self.assertIn("could not verify containerd KillMode", message)

    def test_failed_shim_probe_refusal_names_rc_and_output(self):
        remote = _wipe_probe()
        remote.when("pgrep -a containerd-shim", (255, "pgrep: transport error"))
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        message = str(ctx.exception)
        self.assertIn("rc=255", message)
        self.assertIn("transport error", message)

    def test_failed_mount_enumeration_refusal_names_rc_and_output(self):
        remote = _wipe_probe()
        remote.when("findmnt -rn -o TARGET", (255, "findmnt: bus error"))
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        message = str(ctx.exception)
        self.assertIn("rc=255", message)
        self.assertIn("bus error", message)


class KillModeFileFallbackTest(unittest.TestCase):
    """Attempt-4 defect #15c: verify KillMode from unit files, no manager."""

    def _prepare(self, remote):
        return setup.prepare_nvme("h", "u", 22, "auto",
                                  probe=remote.probe, run=remote.run)

    def _mounted(self, remote):
        return any("mount /dev/nvme0n1 /mnt/nvme" in c
                   for c in remote.commands("run"))

    def test_show_failure_with_unit_file_process_proceeds(self):
        remote = _wipe_probe()
        _killmode_fallback(remote, show=(124, "timeout"),
                           distro="[Service]\nKillMode=process",
                           dropin_dir_exists=False)
        self._prepare(remote)
        self.assertTrue(self._mounted(remote))

    def test_show_failure_with_dropin_override_refuses(self):
        remote = _wipe_probe()
        _killmode_fallback(remote, show=(124, "timeout"),
                           distro="[Service]\nKillMode=process",
                           dropins={"10-override.conf": "[Service]\nKillMode=mixed"})
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        message = str(ctx.exception)
        self.assertIn("mixed", message)
        self.assertIn("rc=124", message)
        self.assertFalse(self._mounted(remote))

    def test_show_failure_with_no_files_refuses_with_remediation(self):
        remote = _wipe_probe()
        _killmode_fallback(remote, show=(127, "sudo: systemctl: command not found"),
                           dropin_dir_exists=False)
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        message = str(ctx.exception)
        self.assertIn("could not verify containerd KillMode", message)
        self.assertIn("Restore KillMode=process", message)
        self.assertIn("rc=127", message)
        self.assertIn("command not found", message)
        self.assertFalse(self._mounted(remote))

    def test_full_etc_copy_overrides_distro_unit(self):
        remote = _wipe_probe()
        _killmode_fallback(remote, show=(1, "Failed to connect to bus"),
                           local="[Service]\nKillMode=process",
                           distro="[Service]\nKillMode=mixed",
                           dropin_dir_exists=False)
        self._prepare(remote)
        self.assertTrue(self._mounted(remote))

    def test_last_dropin_wins_in_lexical_order(self):
        remote = _wipe_probe()
        _killmode_fallback(
            remote, show=(1, "Failed to connect to bus"),
            distro="[Service]\nKillMode=process",
            dropins={
                "10-first.conf": "[Service]\nKillMode=mixed",
                "20-last.conf": "[Service]\nKillMode=process",
            })
        self._prepare(remote)
        self.assertTrue(self._mounted(remote))

    def test_later_dropin_can_override_back_to_a_non_process_value(self):
        remote = _wipe_probe()
        _killmode_fallback(
            remote, show=(1, "Failed to connect to bus"),
            distro="[Service]\nKillMode=process",
            dropins={
                "10-first.conf": "[Service]\nKillMode=process",
                "20-last.conf": "[Service]\nKillMode=mixed",
            })
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        self.assertIn("mixed", str(ctx.exception))
        self.assertFalse(self._mounted(remote))

    def test_run_full_copy_overrides_distro_unit(self):
        # MINOR #3: a full /run copy sits between /etc and /usr/lib.
        remote = _wipe_probe()
        _killmode_fallback(remote, show=(1, "Failed to connect to bus"),
                           run_copy="[Service]\nKillMode=process",
                           distro="[Service]\nKillMode=mixed",
                           dropin_dir_exists=False)
        self._prepare(remote)
        self.assertTrue(self._mounted(remote))

    def test_usr_lib_dropin_is_honored(self):
        # MINOR #3: drop-ins are searched in /usr/lib too.
        usr_lib_dropins = setup._CONTAINERD_DROPIN_DIRS[2]
        remote = _wipe_probe()
        _killmode_fallback(
            remote, show=(1, "Failed to connect to bus"),
            distro="[Service]\nKillMode=process",
            dropin_dirs={usr_lib_dropins: {
                "10-override.conf": "[Service]\nKillMode=mixed"}})
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        self.assertIn("mixed", str(ctx.exception))
        self.assertFalse(self._mounted(remote))

    def test_etc_full_copy_and_dropin_same_resolution_dropin_wins(self):
        # MINOR #8: drop-ins attach to the winning /etc full copy and apply last.
        remote = _wipe_probe()
        _killmode_fallback(
            remote, show=(1, "Failed to connect to bus"),
            local="[Service]\nKillMode=process",
            dropins={"10-override.conf": "[Service]\nKillMode=mixed"})
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        self.assertIn("mixed", str(ctx.exception))
        self.assertFalse(self._mounted(remote))

    def test_dropin_listing_error_refuses(self):
        # MINOR #8: an unreadable drop-in directory is an error, not "absent".
        remote = _wipe_probe()
        _killmode_fallback(
            remote, show=(1, "Failed to connect to bus"),
            distro="[Service]\nKillMode=process",
            dropin_dir_errors={
                setup._CONTAINERD_DROPIN_DIR: (2, "ls: permission denied")})
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        message = str(ctx.exception)
        self.assertIn("rc=2", message)
        self.assertIn("permission denied", message)
        self.assertFalse(self._mounted(remote))

    def test_dropin_directory_exists_but_is_not_a_directory_refuses(self):
        # MINOR #4: test -d rc 1 must not be read as "absent" when the path
        # exists as something else.
        remote = _wipe_probe()
        _killmode_fallback(
            remote, show=(1, "Failed to connect to bus"),
            distro="[Service]\nKillMode=process",
            dropin_not_dirs=(setup._CONTAINERD_DROPIN_DIR,))
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        self.assertIn("not a directory", str(ctx.exception))
        self.assertFalse(self._mounted(remote))

    def test_dropin_cat_non_0_1_rc_refuses(self):
        # MINOR #8: a drop-in cat failure (not ENOENT) is an error.
        path = os.path.join(setup._CONTAINERD_DROPIN_DIR, "10-broken.conf")
        remote = _wipe_probe()
        _killmode_fallback(
            remote, show=(1, "Failed to connect to bus"),
            distro="[Service]\nKillMode=process",
            dropins={"10-broken.conf": "[Service]\nKillMode=process"},
            cat_errors={path: (2, "cat: I/O error")})
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        message = str(ctx.exception)
        self.assertIn("rc=2", message)
        self.assertIn("I/O error", message)
        self.assertFalse(self._mounted(remote))

    def test_existing_but_unreadable_unit_is_not_treated_as_missing(self):
        # MINOR #4: rc 1 from cat on a path that exists (e.g. a directory) must
        # fail closed instead of falling through as "missing".
        remote = _wipe_probe()
        _killmode_fallback(
            remote, show=(1, "Failed to connect to bus"),
            distro="[Service]\nKillMode=process",
            cat_errors={setup._DISTRO_CONTAINERD_UNIT:
                        (1, "cat: /usr/lib/systemd/system/containerd.service: "
                            "Is a directory")},
            dropin_dir_exists=False)
        with self.assertRaises(SystemExit) as ctx:
            self._prepare(remote)
        message = str(ctx.exception)
        self.assertIn("Is a directory", message)
        self.assertIn("rc=1", message)
        self.assertFalse(self._mounted(remote))

    def test_fallback_commands_are_bounded_sudo_and_manager_free(self):
        remote = _wipe_probe()
        _killmode_fallback(remote, show=(1, "Failed to connect to bus"),
                           distro="[Service]\nKillMode=process",
                           dropin_dir_exists=False)
        self._prepare(remote)
        fallback = self._fallback_probes(remote)
        self.assertTrue(fallback, "expected file-fallback probes")
        for cmd in fallback:
            self.assertTrue(cmd.startswith("sudo timeout -k 5 10 "),
                            f"fallback probe not bounded/sudo'd: {cmd!r}")

    def test_fallback_never_uses_systemctl(self):
        remote = _wipe_probe()
        _killmode_fallback(remote, show=(1, "Failed to connect to bus"),
                           distro="[Service]\nKillMode=process",
                           dropin_dir_exists=False)
        self._prepare(remote)
        for cmd in self._fallback_probes(remote):
            self.assertNotIn("systemctl", cmd,
                             f"fallback must not touch the manager: {cmd!r}")

    @staticmethod
    def _fallback_probes(remote):
        return [c for c in remote.commands("probe")
                if ("/etc/systemd/system/containerd.service" in c
                    or "/usr/lib/systemd/system/containerd.service" in c)]


if __name__ == "__main__":
    unittest.main(verbosity=2)
