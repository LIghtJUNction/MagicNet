#!/usr/bin/env python3
"""Host regression tests; Android activity launching is mocked, not claimed tested."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, build_opener

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/MagicNet"
BUSYBOX = shutil.which("busybox")
OPENER = build_opener(ProxyHandler({}))


@unittest.skipUnless(BUSYBOX, "BusyBox is required (including httpd and timeout)")
class UninstallTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="magicnet-uninstall-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.module = self.root / "MagicNet"
        for name in ("uninstall.sh", "lib/magicnet/uninstall.sh",
                     "lib/kamfw-web/launcher.sh", "lib/magicnet/farewell/index.html"):
            target = self.module / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / name, target)
        self.lib = self.module / "lib/magicnet/uninstall.sh"
        (self.module / "module.prop").write_text("id=MagicNet\nversion=v1.5.4+test\n")
        cli = self.module / "cli"
        cli.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$TEST_CALLS"\n'
                       '[ "$*" != "${TEST_FAIL:-}" ]\n')
        cli.chmod(0o755)
        self.calls = self.root / "calls"
        self.env = dict(os.environ, MODDIR=str(self.module), TEST_CALLS=str(self.calls),
                        MN_UNINSTALL_BB=str(BUSYBOX), TEST_ROOT=str(self.root))

    def run_shell(self, script: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(BUSYBOX), "ash", "-c", '. "$1"; ' + script,
                               "test-uninstall", str(self.lib)],
                              env=dict(self.env, **env), text=True, capture_output=True,
                              timeout=12, check=False)

    def assert_ok(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_shell_syntax(self) -> None:
        for file in [self.lib, self.module / "uninstall.sh"]:
            subprocess.run([str(BUSYBOX), "ash", "-n", str(file)], check=True)

    def test_cleanup_order_and_restart_gate(self) -> None:
        self.assert_ok(self.run_shell("magicnet_uninstall_cleanup"))
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["mcp stop", "supervisor stop all", "service stop", "state reconcile"])
        self.assertTrue((self.module / "disable").is_file())

    def test_failures_do_not_skip_remaining_cleanup(self) -> None:
        for command in ("mcp stop", "supervisor stop all", "service stop", "state reconcile"):
            with self.subTest(command=command):
                self.calls.unlink(missing_ok=True)
                result = self.run_shell("magicnet_uninstall_cleanup", TEST_FAIL=command)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Some cleanup failed", result.stderr)
                self.assertEqual(len(self.calls.read_text().splitlines()), 4)

    def test_legacy_appended_commands_never_run_or_hide_failure(self) -> None:
        hook = self.module / "uninstall.sh"
        with hook.open("a") as stream:
            stream.write('printf "blind-delete\\n" >>"$TEST_CALLS"; exit 0\n')
        for failure in ("", "service stop"):
            with self.subTest(failure=failure):
                self.calls.unlink(missing_ok=True)
                result = subprocess.run([str(BUSYBOX), "ash", str(hook)],
                    env=dict(self.env, TEST_FAIL=failure, MAGICNET_NONINTERACTIVE="1"),
                    text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1 if failure else 0, result.stderr)
                self.assertNotIn("blind-delete", self.calls.read_text())
                self.assertEqual(len(self.calls.read_text().splitlines()), 4)

    def test_missing_cli_is_not_reported_as_success(self) -> None:
        (self.module / "cli").unlink()
        result = self.run_shell("magicnet_uninstall_cleanup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not be verified", result.stderr)

    def test_disable_symlink_is_not_followed(self) -> None:
        sentinel = self.root / "sentinel"
        sentinel.write_text("keep")
        (self.module / "disable").symlink_to(sentinel)
        self.assertNotEqual(self.run_shell("magicnet_uninstall_cleanup").returncode, 0)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_state_symlink_is_rejected(self) -> None:
        (self.module / ".state").symlink_to(self.root)
        self.assertNotEqual(self.run_shell("magicnet_uninstall_main").returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_wrong_module_is_rejected(self) -> None:
        (self.module / "module.prop").write_text("id=AnotherVPN\n")
        self.assertNotEqual(self.run_shell("magicnet_uninstall_main").returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_silent_and_recovery_uninstall_still_clean(self) -> None:
        for options in ({"MAGICNET_NONINTERACTIVE": "1"},
                        {"MAGICNET_UNINSTALL_FAREWELL": "0"}, {"BOOTMODE": "false"}):
            with self.subTest(options=options):
                result = self.run_shell('magicnet_farewell_stage() { echo opened >"$TEST_ROOT/opened"; }; '
                                        'magicnet_uninstall_main', **options)
                self.assert_ok(result)
                self.assertFalse((self.root / "opened").exists())
        self.assertEqual(len(self.calls.read_text().splitlines()), 12)

    def test_browser_failure_does_not_change_successful_cleanup(self) -> None:
        result = self.run_shell("magicnet_farewell_allowed() { return 0; }; "
                                "magicnet_farewell_stage() { return 1; }; magicnet_uninstall_main")
        self.assert_ok(result)
        self.assertIn("not blocked", result.stderr)

    def test_only_one_browser_attempt_but_cleanup_is_idempotent(self) -> None:
        script = ('magicnet_farewell_allowed() { return 0; }; '
                  'magicnet_farewell_stage() { echo attempt >>"$TEST_ROOT/opened"; }; '
                  'magicnet_uninstall_main; magicnet_uninstall_main')
        self.assert_ok(self.run_shell(script))
        self.assertEqual((self.root / "opened").read_text().splitlines(), ["attempt"])
        self.assertEqual(len(self.calls.read_text().splitlines()), 8)

    def test_existing_lock_does_not_start_duplicate_cleanup(self) -> None:
        (self.module / ".state/uninstall.lock").mkdir(parents=True)
        self.assert_ok(self.run_shell("magicnet_uninstall_main"))
        self.assertFalse(self.calls.exists())

    def test_failed_staging_removes_temporary_files(self) -> None:
        (self.module / "lib/magicnet/farewell/index.html").unlink()
        result = self.run_shell('magicnet_farewell_parent() { printf "%s\\n" "$TEST_ROOT"; }; '
                                'magicnet_farewell_stage')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.root.glob(".magicnet-farewell.*")), [])

    def stage_live_page(self, version: str = "v1.5.4+test") -> tuple[str, Path]:
        (self.module / "module.prop").write_text(f"id=MagicNet\nversion={version}\n")
        # Override only Android readiness/ActivityManager in the fixture copy.
        # Staging, copied BusyBox, httpd, timeout and cleanup are the real code.
        with self.lib.open("a") as stream:
            stream.write('\nmagicnet_farewell_android_ready() { return 0; }\n'
                         'magicnet_farewell_open() { printf "%s\\n" "$2" >"$TEST_ROOT/url"; '
                         '"$MN_FAREWELL_BB" sleep 4; return 1; }\n')
        self.assert_ok(self.run_shell('magicnet_farewell_parent() { printf "%s\\n" "$TEST_ROOT"; }; '
                                     'magicnet_farewell_stage'))
        deadline = time.monotonic() + 4
        while not (self.root / "url").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue((self.root / "url").exists(), "worker did not reach browser launch")
        stages = list(self.root.glob(".magicnet-farewell.*"))
        self.assertEqual(len(stages), 1)
        return (self.root / "url").read_text().strip(), stages[0]

    def wait_removed(self, stage: Path) -> None:
        deadline = time.monotonic() + 7
        while stage.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(stage.exists(), "worker left staging files")

    def test_standalone_server_survives_module_removal_then_cleans(self) -> None:
        url, stage = self.stage_live_page()
        self.assertEqual(stage.stat().st_mode & 0o777, 0o700)
        self.assertIn("#version=v1.5.4+test", url)
        shutil.rmtree(self.module)
        with OPENER.open(url.split("#")[0], timeout=2) as response:
            page = response.read().decode()
        self.assertIn('id="farewell"', page)
        self.assertNotIn("subscription.url", page)
        with self.assertRaises(HTTPError):
            OPENER.open(url.split("/", 3)[0] + "//" + url.split("/", 3)[2] + "/module.prop", timeout=2)
        self.wait_removed(stage)
        with self.assertRaises((URLError, TimeoutError)):
            OPENER.open(url.split("#")[0], timeout=1)

    def test_version_is_data_not_shell(self) -> None:
        sentinel = self.root / "injected"
        url, stage = self.stage_live_page(f"$(touch {sentinel})")
        self.assertTrue(url.endswith("#version=unknown"))
        self.assertFalse(sentinel.exists())
        self.wait_removed(stage)


if __name__ == "__main__":
    if not BUSYBOX:
        raise SystemExit("BusyBox with httpd is required; tests were NOT run")
    unittest.main(verbosity=2)
