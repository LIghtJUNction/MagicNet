#!/usr/bin/env python3
"""Offline regression for the curl fixture used by the packaged-module smoke."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "scripts/fixtures/fake-magisk-curl.sh"
FETCH = ROOT / "src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh"
URL = "https://example.invalid/subscription.yaml"
FORMAT = r"%{http_code}\n%{redirect_url}\n"


class CurlFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="magicnet-curl-fixture-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.body = self.root / "body.yaml"
        self.headers = self.root / "headers"
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith("MAGICNET_FAKE_CURL_"):
                del self.env[key]

    def run_curl(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(FIXTURE), *args], capture_output=True, text=True,
            env=self.env | (env or {}), timeout=10, check=False,
        )

    def test_success_emits_status_redirect_and_separate_headers(self) -> None:
        result = self.run_curl(
            "-q", "-fs", "--globoff", "--path-as-is", "--noproxy", "*",
            "--max-redirs", "0", "--proto", "=https", "--proto-redir", "=https",
            "--compressed", "--max-filesize", "8388608", "--dump-header", str(self.headers),
            "--resolve", "example.invalid:443:1.1.1.1", "--connect-timeout", "2",
            "--max-time", "10", "--write-out", FORMAT, "-o", str(self.body), URL,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "200\n\n")
        self.assertIn("fresh-sub-node", self.body.read_text())
        self.assertIn(b"\r.test", self.body.read_bytes())
        self.assertTrue(self.headers.read_bytes().startswith(b"HTTP/1.1 200 "))
        self.assertTrue(self.headers.read_bytes().endswith(b"\r\n\r\n"))
        self.assertNotIn("HTTP/1.1", self.body.read_text())

    def test_metrics_remain_compatible(self) -> None:
        result = self.run_curl("-w", "%{http_code}|%{time_connect}|%{time_starttransfer}|%{time_total}", "https://www.google.com")
        self.assertEqual(result.stdout, "200|0.010|0.020|0.030")
        self.assertEqual(result.returncode, 0)

    def test_stdout_body_precedes_transfer_metadata(self) -> None:
        result = self.run_curl("--output", "-", "-w", FORMAT, URL)
        self.assertTrue(result.stdout.startswith("proxies:\n"))
        self.assertTrue(result.stdout.endswith("200\n\n"))

    def test_connection_failure_preserves_transport_code(self) -> None:
        result = self.run_curl("-fs", "-o", str(self.body), "-w", FORMAT, URL, env={"MAGICNET_FAKE_CURL_FAIL_URL": URL})
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "000\n\n")
        self.assertFalse(self.body.exists())

    def test_http_error_obeys_fail_flag(self) -> None:
        for flag in ("-f", "-fs", "--fail"):
            with self.subTest(flag=flag):
                result = self.run_curl(flag, "-D", str(self.headers), "-o", str(self.body), "-w", FORMAT, URL,
                    env={"MAGICNET_FAKE_CURL_HTTP_CODE_URL": URL, "MAGICNET_FAKE_CURL_HTTP_CODE": "503"})
                self.assertEqual(result.returncode, 22)
                self.assertEqual(result.stdout, "503\n\n")
                self.assertIn("503", self.headers.read_text())
                self.assertFalse(self.body.exists())

    def test_http_probe_without_fail_still_reports_status(self) -> None:
        result = self.run_curl("-w", FORMAT, URL, env={"MAGICNET_FAKE_CURL_HTTP_CODE_URL": URL})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "429\n\n")

    def test_missing_option_value_fails(self) -> None:
        for option in ("--output", "--dump-header", "--write-out", "--resolve"):
            with self.subTest(option=option):
                self.assertNotEqual(self.run_curl(option).returncode, 0)

    def run_production_fetch(self, extra: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        # Only name resolution is stubbed; the production FIFO, deadline, status,
        # retry and cleanup code is executed unchanged. No external request occurs.
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        curl = mock_bin / "curl"
        curl.write_text('#!/usr/bin/env bash\nprintf "call\\n" >>"$CURL_CALLS"\nexec bash "$CURL_FIXTURE" "$@"\n')
        curl.chmod(0o755)
        script = r'''
. "$FETCH_SOURCE"
warn() { printf '%s\n' "$*" >&2; }
magicnet_singbox_subscription_resolve_public() {
    printf '%s\n' 'example.invalid|443|1.1.1.1'
}
magicnet_singbox_try_fetch_subscription "$FETCH_URL" "$FETCH_TARGET" 2 10
'''
        return subprocess.run(
            ["sh", "-c", script], capture_output=True, text=True, timeout=15, check=False,
            env=self.env | {
                "PATH": str(mock_bin) + os.pathsep + self.env.get("PATH", ""),
                "CURL_FIXTURE": str(FIXTURE), "CURL_CALLS": str(self.root / "calls"),
                "FETCH_SOURCE": str(FETCH), "FETCH_URL": URL, "FETCH_TARGET": str(self.body),
            } | (extra or {}),
        )

    def assert_no_transient_files(self) -> None:
        for suffix in (".response", ".resolve", ".stream", ".headers"):
            self.assertFalse(Path(str(self.body) + suffix).exists(), suffix)

    @unittest.skipUnless(shutil.which("timeout"), "GNU timeout is required for production fetch")
    def test_production_fifo_fetch_accepts_fixture(self) -> None:
        result = self.run_production_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fresh-sub-node", self.body.read_text())
        usage = json.loads(Path(str(self.body) + ".usage.json").read_text())
        self.assertEqual(usage["state"], "fresh")
        self.assertIsNone(usage["total_bytes"])
        self.assertEqual((self.root / "calls").read_text().splitlines(), ["call"])
        self.assert_no_transient_files()

    @unittest.skipUnless(shutil.which("timeout"), "GNU timeout is required for production fetch")
    def test_production_failure_is_retried_not_accepted(self) -> None:
        result = self.run_production_fetch({"MAGICNET_FAKE_CURL_FAIL_URL": URL})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / "calls").read_text().splitlines()), 3)
        self.assertFalse(self.body.exists())
        self.assertFalse(Path(str(self.body) + ".usage.json").exists())
        self.assert_no_transient_files()

    @unittest.skipUnless(shutil.which("timeout"), "GNU timeout is required for production fetch")
    def test_production_http_error_does_not_become_success(self) -> None:
        result = self.run_production_fetch({"MAGICNET_FAKE_CURL_HTTP_CODE_URL": URL, "MAGICNET_FAKE_CURL_HTTP_CODE": "404"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "calls").read_text().splitlines(), ["call"])
        self.assertFalse(self.body.exists())
        self.assert_no_transient_files()


if __name__ == "__main__":
    unittest.main()
