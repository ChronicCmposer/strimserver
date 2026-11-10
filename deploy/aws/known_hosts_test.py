#!/usr/bin/env python3
"""Pure-stdlib tests for deploy/aws/known_hosts.py.

Run directly with `python3 deploy/aws/known_hosts_test.py` or via the Bazel
`//deploy/aws:known_hosts_test` sh_test wrapper.
"""

import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import known_hosts  # noqa: E402


class KnownHostsPathTest(unittest.TestCase):
    def test_default_uses_xdg_state_home(self):
        env = {"XDG_STATE_HOME": "/state", "HOME": "/home/op"}
        self.assertEqual(
            known_hosts.known_hosts_path(env),
            "/state/strimserver/known_hosts")

    def test_default_falls_back_to_home(self):
        env = {"HOME": "/home/op"}
        self.assertEqual(
            known_hosts.known_hosts_path(env),
            "/home/op/.local/state/strimserver/known_hosts")

    def test_override_wins_over_xdg(self):
        env = {
            known_hosts.KNOWN_HOSTS_ENV: "/custom/known_hosts",
            "XDG_STATE_HOME": "/state",
            "HOME": "/home/op",
        }
        self.assertEqual(
            known_hosts.known_hosts_path(env), "/custom/known_hosts")

    def test_relative_override_is_made_absolute(self):
        env = {known_hosts.KNOWN_HOSTS_ENV: "relative-known_hosts"}
        self.assertEqual(
            known_hosts.known_hosts_path(env),
            os.path.join(os.getcwd(), "relative-known_hosts"))

    def test_missing_home_fails_loud(self):
        with self.assertRaises(known_hosts.KnownHostsError):
            known_hosts.known_hosts_path({})


class EnsureDirectoryTest(unittest.TestCase):
    def test_directory_is_created_0700(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "state", "known_hosts")
            directory = known_hosts.ensure_known_hosts_dir(store)
            mode = stat.S_IMODE(os.stat(directory).st_mode)
            self.assertEqual(mode, 0o700)

    def test_unenforceable_permissions_fail_loud(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "state", "known_hosts")
            with mock.patch.object(
                    known_hosts.os, "chmod",
                    side_effect=OSError("injected chmod failure")):
                with self.assertRaises(known_hosts.KnownHostsError) as ctx:
                    known_hosts.ensure_known_hosts_dir(store)
            self.assertIn("could not create or secure", str(ctx.exception))


class OptionConstructionTest(unittest.TestCase):
    def test_ssh_options_use_accept_new_and_private_store(self):
        options = known_hosts.ssh_options("/tmp/store/known_hosts")
        self.assertIn("StrictHostKeyChecking=accept-new", options)
        self.assertIn("UserKnownHostsFile=/tmp/store/known_hosts", options)
        self.assertNotIn("StrictHostKeyChecking=no", options)

    def test_scp_options_match_ssh_options(self):
        self.assertEqual(
            known_hosts.scp_options("/tmp/store/known_hosts"),
            known_hosts.ssh_options("/tmp/store/known_hosts"))


class StaleKeyClassificationTest(unittest.TestCase):
    def test_both_mismatch_markers_are_recognized(self):
        self.assertTrue(known_hosts.is_host_key_mismatch(
            "Host key verification failed."))
        self.assertTrue(known_hosts.is_host_key_mismatch(
            "@@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@@"))

    def test_other_failures_are_not_misclassified(self):
        self.assertFalse(known_hosts.is_host_key_mismatch(
            "Permission denied (publickey)."))
        self.assertFalse(known_hosts.is_host_key_mismatch(""))

    def test_prune_command_is_exact_and_uses_the_private_store(self):
        self.assertEqual(
            known_hosts.prune_command("1.2.3.4", "/tmp/store/known_hosts"),
            "ssh-keygen -f /tmp/store/known_hosts -R 1.2.3.4")


class ForgetHostTest(unittest.TestCase):
    def test_absent_file_is_tolerated(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "known_hosts")
            self.assertTrue(known_hosts.forget_host("1.2.3.4", store))

    def test_entry_is_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "known_hosts")
            Path(store).write_text(
                "1.2.3.4 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDfake\n"
                "host-b ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake\n",
                encoding="utf-8")
            known_hosts.forget_host("1.2.3.4", store)
            text = Path(store).read_text(encoding="utf-8")
            self.assertNotIn("1.2.3.4", text)
            self.assertIn("host-b", text)


class InstanceMapTest(unittest.TestCase):
    def test_reused_host_forgets_old_instance_bindings(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "known_hosts")
            Path(store).write_text(
                "host-a ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDfake\n"
                "host-b ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDfake\n",
                encoding="utf-8")
            known_hosts.bind_host_instance("host-a", "i-old", store)
            known_hosts.bind_host_instance("host-b", "i-old", store)
            # The host now points at a different instance: every host bound to
            # the old one must be forgotten and its map rows dropped.
            known_hosts.bind_host_instance("host-a", "i-new", store)

            rows = dict(known_hosts._read_map(store + known_hosts.MAP_SUFFIX))
            self.assertEqual(rows, {"host-a": "i-new"})
            text = Path(store).read_text(encoding="utf-8")
            self.assertNotIn("host-a", text)
            self.assertNotIn("host-b", text)

    def test_forget_instance_drops_bound_hosts(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "known_hosts")
            Path(store).write_text(
                "host-a ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDfake\n"
                "host-b ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDfake\n",
                encoding="utf-8")
            known_hosts.bind_host_instance("host-a", "i-1", store)
            known_hosts.bind_host_instance("host-b", "i-2", store)
            known_hosts.forget_instance("i-1", store)

            rows = dict(known_hosts._read_map(store + known_hosts.MAP_SUFFIX))
            self.assertEqual(rows, {"host-b": "i-2"})
            text = Path(store).read_text(encoding="utf-8")
            self.assertNotIn("host-a", text)
            self.assertIn("host-b", text)

    def test_concurrent_binds_keep_every_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "known_hosts")
            hosts = [f"host-{index}" for index in range(20)]
            errors = []

            def bind(host):
                try:
                    known_hosts.bind_host_instance(host, "i-shared", store)
                except Exception as exc:  # noqa: BLE001 - surfaced below
                    errors.append(exc)

            threads = [threading.Thread(target=bind, args=(host,))
                       for host in hosts]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()

            self.assertEqual(errors, [])
            rows = dict(known_hosts._read_map(store + known_hosts.MAP_SUFFIX))
            self.assertEqual(rows, {host: "i-shared" for host in hosts})

    def test_lock_wait_is_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "known_hosts")
            directory = known_hosts.ensure_known_hosts_dir(store)
            lock_path = store + known_hosts.MAP_SUFFIX + ".lock"
            fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                with mock.patch.dict(
                        os.environ,
                        {known_hosts.LOCK_TIMEOUT_ENV: "0.1"}):
                    with self.assertRaises(known_hosts.KnownHostsError):
                        known_hosts.bind_host_instance("host", "i-1", store)
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
            self.assertTrue(os.path.isdir(directory))


class SourceHygieneTest(unittest.TestCase):
    """No script may fall back to the operator's default known_hosts file."""

    SOURCES = (
        "known_hosts.py",
        "launch",
        "setup_strimserver",
        "start_strimserver",
        "stop_strimserver",
        "terminate",
    )

    def test_no_operator_known_hosts_reference(self):
        operator_ssh_dir = re.compile(r"(^|[^A-Za-z0-9_])\.ssh(\b|/)")
        for name in self.SOURCES:
            text = (HERE / name).read_text(encoding="utf-8")
            self.assertIsNone(
                operator_ssh_dir.search(text),
                f"{name} references the operator's SSH dir")
            self.assertNotIn(
                "StrictHostKeyChecking=no", text,
                f"{name} disables host key checking")

    def test_launch_prints_the_dedicated_store_remediation(self):
        self.assertIn("prune_command", (HERE / "launch").read_text(encoding="utf-8"))

    def test_start_and_stop_honor_port_identity_and_private_store(self):
        for name in ("start_strimserver", "stop_strimserver"):
            text = (HERE / name).read_text(encoding="utf-8")
            self.assertIn('UserKnownHostsFile=$known_hosts_file', text)
            self.assertIn('ssh_port="${SSH_PORT:-22}"', text)
            self.assertIn("SSH_IDENTITY", text)
            self.assertIn('-p "$ssh_port"', text)

    def test_setup_wires_the_shared_options_into_ssh_and_scp(self):
        text = (HERE / "setup_strimserver").read_text(encoding="utf-8")
        self.assertIn("known_hosts.ssh_options()", text)
        self.assertIn("known_hosts.scp_options()", text)
        self.assertIn('"-P"', text)


def _load_script(name, module_name):
    loader = importlib.machinery.SourceFileLoader(module_name, str(HERE / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError(f"could not build a module spec for {name}")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def _load_launch():
    return _load_script("launch", "strimserver_launch")


class WaitForSshTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.launch = _load_launch()

    def _ssh(self):
        return self.launch.Ssh(
            cmd=["ssh"], user="ec2-user", port="22",
            known_hosts_file="/tmp/store/known_hosts")

    @staticmethod
    def _result(stderr, returncode=255):
        return subprocess.CompletedProcess(["ssh"], returncode, "", stderr)

    def test_refused_key_keeps_polling_until_the_budget_expires(self):
        calls = []

        def fake_run(*args, **kwargs):
            calls.append(args)
            return self._result("Permission denied (publickey).")

        with mock.patch.object(self.launch.subprocess, "run",
                               side_effect=fake_run):
            status = self.launch.wait_for_ssh(
                self._ssh(), "1.2.3.4",
                total=0.05, interval=0.01, connect_timeout=1)
        self.assertIs(status, self.launch.Probe.REACHABLE)
        self.assertGreater(len(calls), 1)

    def test_stale_key_is_pruned_once_then_the_retry_succeeds(self):
        responses = [
            self._result("Host key verification failed."),
            self._result("", returncode=0),
        ]
        with mock.patch.object(self.launch.subprocess, "run",
                               side_effect=responses), \
                mock.patch.object(known_hosts, "forget_host") as forget:
            status = self.launch.wait_for_ssh(
                self._ssh(), "1.2.3.4",
                total=1, interval=0.01, connect_timeout=1)
        self.assertIs(status, self.launch.Probe.READY)
        forget.assert_called_once_with("1.2.3.4", "/tmp/store/known_hosts")

    def test_persistent_stale_key_returns_a_distinct_status(self):
        with mock.patch.object(
                self.launch.subprocess, "run",
                return_value=self._result("Host key verification failed.")), \
                mock.patch.object(known_hosts, "forget_host") as forget:
            status = self.launch.wait_for_ssh(
                self._ssh(), "1.2.3.4",
                total=1, interval=0.01, connect_timeout=1)
        self.assertIs(status, self.launch.Probe.HOST_KEY_MISMATCH)
        self.assertEqual(forget.call_count, 1)


class SetupWiringTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.setup = _load_script("setup_strimserver", "strimserver_setup")

    @staticmethod
    def _capture_run(captured):
        def fake_run(cmd, **kwargs):
            captured.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, "", "")
        return fake_run

    def test_ssh_run_uses_the_private_store_and_port_before_the_host(self):
        captured = []
        with mock.patch.dict(
                os.environ,
                {"STRIMSERVER_KNOWN_HOSTS_FILE": "/tmp/kh"}), \
                mock.patch.object(self.setup.subprocess, "run",
                                  side_effect=self._capture_run(captured)):
            self.setup.ssh_run("1.2.3.4", "ec2-user", 2222, "true")

        command = captured[0]
        self.assertIn("StrictHostKeyChecking=accept-new", command)
        self.assertIn("UserKnownHostsFile=/tmp/kh", command)
        self.assertEqual(command[command.index("-p") + 1], "2222")
        self.assertLess(
            command.index("-p"), command.index("ec2-user@1.2.3.4"))

    def test_scp_uses_dash_P_and_the_private_store(self):
        captured = []
        with mock.patch.dict(
                os.environ,
                {"STRIMSERVER_KNOWN_HOSTS_FILE": "/tmp/kh"}), \
                mock.patch.object(self.setup.subprocess, "run",
                                  side_effect=self._capture_run(captured)):
            self.setup.scp_to_remote(
                "/tmp/local", "1.2.3.4", "ec2-user", 2222, "/tmp/remote")

        command = captured[0]
        self.assertIn("UserKnownHostsFile=/tmp/kh", command)
        self.assertEqual(command[command.index("-P") + 1], "2222")
        self.assertNotIn("-p", command)


DEPLOYMENT_ASSETS = (
    "strimserver-deployment-go-amd64.tar",
    "strimserver-deployment-c-amd64.tar",
    "strimserver-deployment-go-arm64.tar",
    "strimserver-deployment-c-arm64.tar",
)


class ResolveSourceTest(unittest.TestCase):
    """resolve_source() derives the on-box filename from the source basename.

    DEPLOYMENT stays an explicit override; the legacy $S3_BUCKET path keeps
    defaulting to the go-amd64 bundle.
    """

    @classmethod
    def setUpClass(cls):
        cls.setup = _load_script("setup_strimserver", "strimserver_setup")

    def _resolve(self, env):
        with mock.patch.dict(os.environ, env, clear=True):
            return self.setup.resolve_source()

    def test_s3_source_selects_its_own_basename(self):
        src = "s3://bucket/strimserver-deployment-c-amd64.tar"
        self.assertEqual(
            self._resolve({"DEPLOYMENT_SRC": src}),
            (src, "strimserver-deployment-c-amd64.tar"))

    def test_every_s3_asset_basename_is_preserved(self):
        for name in DEPLOYMENT_ASSETS:
            with self.subTest(name=name):
                src = f"s3://bucket/{name}"
                self.assertEqual(self._resolve({"DEPLOYMENT_SRC": src}),
                                 (src, name))

    def test_every_https_asset_basename_is_preserved(self):
        for name in DEPLOYMENT_ASSETS:
            with self.subTest(name=name):
                src = ("https://github.com/ChronicCmposer/strimserver/"
                       f"releases/latest/download/{name}")
                self.assertEqual(self._resolve({"DEPLOYMENT_SRC": src}),
                                 (src, name))

    def test_local_path_basename_is_preserved(self):
        src = "~/Downloads/strimserver-deployment-c-amd64.tar"
        self.assertEqual(
            self._resolve({"DEPLOYMENT_SRC": src}),
            (src, "strimserver-deployment-c-amd64.tar"))

    def test_explicit_deployment_overrides_a_differently_basnamed_source(self):
        src = "s3://bucket/strimserver-deployment-go-arm64.tar"
        self.assertEqual(
            self._resolve({
                "DEPLOYMENT_SRC": src,
                "DEPLOYMENT": "strimserver-deployment-c-amd64.tar",
            }),
            (src, "strimserver-deployment-c-amd64.tar"))

    def test_explicit_deployment_that_disagrees_warns_on_stderr(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            deployment = self._resolve({
                "DEPLOYMENT_SRC":
                    "s3://bucket/strimserver-deployment-go-arm64.tar",
                "DEPLOYMENT": "strimserver-deployment-c-amd64.tar",
            })[1]
        self.assertEqual(deployment, "strimserver-deployment-c-amd64.tar")
        self.assertIn("strimserver-deployment-c-amd64.tar", stderr.getvalue())

    def test_legacy_bucket_defaults_to_go_amd64(self):
        self.assertEqual(
            self._resolve({"S3_BUCKET": "s3://bucket"}),
            ("s3://bucket/strimserver-deployment-go-amd64.tar",
             "strimserver-deployment-go-amd64.tar"))

    def test_legacy_bucket_honors_explicit_deployment(self):
        self.assertEqual(
            self._resolve({
                "S3_BUCKET": "s3://bucket",
                "DEPLOYMENT": "strimserver-deployment-c-amd64.tar",
            }),
            ("s3://bucket/strimserver-deployment-c-amd64.tar",
             "strimserver-deployment-c-amd64.tar"))

    def test_no_source_configured_exits(self):
        with self.assertRaises(SystemExit):
            self._resolve({})

    def test_source_without_a_filename_exits(self):
        with self.assertRaises(SystemExit):
            self._resolve({"DEPLOYMENT_SRC": "s3://bucket/"})


class LaunchDeploymentDefaultsTest(unittest.TestCase):
    """default_deployment_env() must not clobber an operator-provided source
    and must derive the matching arm64 asset from an explicit DEPLOYMENT."""

    @classmethod
    def setUpClass(cls):
        cls.launch = _load_launch()

    @staticmethod
    def _arm64():
        return mock.Mock(arch="arm64")

    def test_explicit_source_leaves_deployment_for_setup_to_resolve(self):
        src = ("https://github.com/ChronicCmposer/strimserver/"
               "releases/latest/download/strimserver-deployment-c-arm64.tar")
        with mock.patch.dict(os.environ, {"DEPLOYMENT_SRC": src}, clear=True), \
                mock.patch.object(self.launch, "fetch_release_sha256",
                                  return_value="deadbeef") as fetch:
            self.launch.default_deployment_env(self._arm64())
            self.assertNotIn("DEPLOYMENT", os.environ)
            fetch.assert_not_called()

    def test_no_source_defaults_all_three_to_go_arm64(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(self.launch, "fetch_release_sha256",
                                  return_value="deadbeef") as fetch:
            self.launch.default_deployment_env(self._arm64())
            self.assertEqual(os.environ["DEPLOYMENT"],
                             "strimserver-deployment-go-arm64.tar")
            self.assertTrue(os.environ["DEPLOYMENT_SRC"].endswith(
                "strimserver-deployment-go-arm64.tar"))
            self.assertEqual(os.environ["DEPLOYMENT_SHA256"], "deadbeef")
            fetch.assert_called_once_with(
                "strimserver-deployment-go-arm64.tar")

    def test_explicit_deployment_selects_the_matching_asset(self):
        with mock.patch.dict(
                os.environ,
                {"DEPLOYMENT": "strimserver-deployment-c-arm64.tar"},
                clear=True), \
                mock.patch.object(self.launch, "fetch_release_sha256",
                                  return_value="deadbeef") as fetch:
            self.launch.default_deployment_env(self._arm64())
            self.assertTrue(os.environ["DEPLOYMENT_SRC"].endswith(
                "strimserver-deployment-c-arm64.tar"))
            fetch.assert_called_once_with(
                "strimserver-deployment-c-arm64.tar")

    def test_legacy_bucket_defaults_deployment_without_a_source(self):
        with mock.patch.dict(os.environ, {"S3_BUCKET": "s3://bucket"},
                             clear=True), \
                mock.patch.object(self.launch, "fetch_release_sha256",
                                  return_value="deadbeef"):
            self.launch.default_deployment_env(self._arm64())
            self.assertEqual(os.environ["DEPLOYMENT"],
                             "strimserver-deployment-go-arm64.tar")
            self.assertNotIn("DEPLOYMENT_SRC", os.environ)

    def test_amd64_leaves_the_environment_untouched(self):
        env = {
            "DEPLOYMENT": "strimserver-deployment-c-amd64.tar",
            "DEPLOYMENT_SRC": "s3://bucket/strimserver-deployment-c-amd64.tar",
        }
        with mock.patch.dict(os.environ, env, clear=True):
            before = dict(os.environ)
            self.launch.default_deployment_env(mock.Mock(arch="amd64"))
            self.assertEqual(dict(os.environ), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
