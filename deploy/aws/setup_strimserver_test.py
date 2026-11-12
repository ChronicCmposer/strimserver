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
import sys
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


class FakeRemote:
    """Records probe/run calls; the most recently registered match wins.

    Last-wins lets a test inject a failure with `when(fail_needle, ...)` after
    the default success rule without depending on needle length.
    """

    def __init__(self):
        self.calls = []  # [("probe"|"run", cmd)]
        self._rules = []

    def when(self, needle, response):
        self._rules.append((needle, response))
        return self

    def probe(self, host, user, port, cmd):
        self.calls.append(("probe", cmd))
        for needle, response in reversed(self._rules):
            if needle in cmd:
                return response(cmd) if callable(response) else response
        return (0, "")

    def run(self, host, user, port, cmd):
        self.calls.append(("run", cmd))

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
