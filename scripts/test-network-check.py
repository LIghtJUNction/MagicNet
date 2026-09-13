#!/usr/bin/env python3
"""Offline regressions: real curl/TLS fixtures + deterministic transport failures.

No Internet, subscription or credentials required. Passing these tests validates
probe behavior, NOT the reachability of the public target corpus from a phone.
"""
from __future__ import annotations

import contextlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "src/MagicNet/network-check.sh"
CORPUS = ROOT / "src/MagicNet/lib/magicnet/network-targets.tsv"
REAL_CURL = shutil.which("curl")

# A mock is used only for failures that need deterministic network conditions.
MOCK = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
url = args[args.index('--url') + 1]
scenario = url.rsplit('/', 1)[-1]
Path(os.environ['CALLS'], str(os.getpid()) + '.json').write_text(json.dumps(args))
if scenario.startswith('exit'):
    # Even HTTP 200 with a nonzero curl exit is NOT a completed response.
    print('200|0|10|0.001|0.002|0.003|0.004|2', end='')
    sys.exit(int(scenario[4:]))
if scenario == 'flaky':
    mark = Path(os.environ['CALLS']) / 'flaky-marker'
    if mark.exists():
        scenario = '200'
    else:
        mark.touch()
        scenario = '503'
if scenario == 'redirect204':
    print('204|1|0|0.001|0.002|0.003|0.004|2', end='')
elif scenario == 'body204':
    print('204|0|9|0.001|0.002|0.003|0.004|2', end='')
elif scenario == 'empty':
    pass
else:
    print(f'{scenario}|0|0|0.001|0.002|0.003|0.004|2', end='')
'''


def result_rows(output: str) -> list[list[str]]:
    return [line.split("\t") for line in output.splitlines()
            if line and not line.startswith(("#", "target\t"))]


class ProbeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="magicnet-check-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        # Release gates run after Android binaries have been staged in src/bin.
        # Test the exact script in an isolated module, never execute those binaries.
        self.script = self.work / "module" / "network-check.sh"
        self.script.parent.mkdir()
        shutil.copyfile(SCRIPT, self.script)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.calls = self.work / "calls"
        self.calls.mkdir()
        fake = self.bin / "curl"
        fake.write_text(MOCK)
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TMPDIR=str(self.work), CALLS=str(self.calls))

    def run_probe(self, rows: list[str], *options: str,
                  env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        targets = self.work / "targets"
        targets.write_text("\n".join(rows) + "\n")
        return subprocess.run(["sh", str(self.script), "--targets", str(targets), *options],
                              env=env or self.env, capture_output=True, text=True, timeout=20)

    def one(self, scenario: str, expected: int = 200, *options: str):
        return self.run_probe([f"probe|test|https://example.invalid/{scenario}|{expected}"], *options)

    def test_shell_syntax(self):
        subprocess.run(["sh", "-n", str(SCRIPT)], check=True)

    def test_public_corpus_coverage_and_unique_ids(self):
        rows = [line.split("|") for line in CORPUS.read_text().splitlines()
                if line and not line.startswith("#")]
        self.assertEqual(len(rows), 24)
        self.assertEqual(len(rows), len({row[0] for row in rows}))
        ids = {row[0] for row in rows}
        self.assertTrue({"google_play", "google_login", "google_download", "android_connectivity",
                         "chatgpt", "weixin", "bilibili", "github", "baidu"} <= ids)
        for row in rows:
            self.assertEqual(len(row), 4)
            self.assertTrue(row[2].startswith("https://"))
            self.assertIn(row[3], {"200", "204"})

    def test_http_success_is_exact(self):
        for code in (200, 204):
            with self.subTest(code=code):
                result = self.one(str(code), code)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("pass=1 fail=0 incomplete=0", result.stdout)

    def test_http_error_and_unfinished_redirect_never_pass(self):
        for code in (100, 206, 301, 302, 401, 403, 404, 407, 429, 500, 502, 503, 599):
            with self.subTest(code=code):
                result = self.one(str(code))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(result_rows(result.stdout)[0][5], "FAIL")

    def test_captive_portal_and_redirected_204_fail(self):
        for scenario in ("200", "redirect204", "body204"):
            with self.subTest(scenario=scenario):
                self.assertEqual(self.one(scenario, 204).returncode, 1)

    def test_transport_failures_override_http_200(self):
        reasons = {5: "dns", 6: "dns", 7: "connect", 28: "timeout", 35: "tls", 60: "tls",
                   18: "transport", 52: "transport", 56: "transport"}
        for code, reason in reasons.items():
            with self.subTest(code=code):
                result = self.one(f"exit{code}")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result_rows(result.stdout)[0][6], reason)

    def test_missing_capability_and_size_limit_are_incomplete(self):
        for code in (1, 2, 4, 48, 63):
            with self.subTest(code=code):
                result = self.one(f"exit{code}")
                self.assertEqual(result.returncode, 2)
                self.assertIn("pass=0 fail=0 incomplete=1", result.stdout)

    def test_empty_metadata_never_passes(self):
        self.assertNotEqual(self.one("empty").returncode, 0)

    def test_invalid_options_make_no_requests(self):
        for options in (("--jobs", "0"), ("--jobs", "9"), ("--jobs", "bad"),
                        ("--rounds", "4"), ("--timeout", "31"), ("--mode", "tun"),
                        ("--family", "5"), ("--family", "6"), ("--unknown",),
                        ("--proxy", "http://user:secret@example.com:80"),
                        ("--proxy", "http://127.0.0.1:99999")):
            with self.subTest(options=options):
                result = self.one("200", 200, *options)
                self.assertEqual(result.returncode, 64, result.stdout)
        self.assertFalse(list(self.calls.glob("*.json")))

    def test_invalid_corpora_make_no_requests(self):
        good = "one|test|https://example.invalid/200|200"
        for rows in ([], ["# comment"], [good, good], ["broken"],
                     ["../oops|test|https://example.invalid/200|200"],
                     ["one|test|http://example.invalid/200|200"],
                     ["one|test|https://user:secret@example.invalid/200|200"],
                     ["one|test|https://example.invalid/200|403"]):
            with self.subTest(rows=rows):
                self.assertEqual(self.run_probe(rows).returncode, 64)
        self.assertFalse(list(self.calls.glob("*.json")))

    def test_proxy_path_resists_environment_and_does_not_claim_dns_family(self):
        result = self.one("200")
        self.assertEqual(result.returncode, 0)
        args = json.loads(next(self.calls.glob("*.json")).read_text())
        self.assertEqual(args[0], "--disable")
        self.assertEqual(args[args.index("--noproxy") + 1], "")
        self.assertEqual(args[args.index("--proxy") + 1], "http://127.0.0.1:7892")
        self.assertNotIn("--insecure", args)
        self.assertNotIn("--retry", args)
        self.assertEqual(result_rows(result.stdout)[0][9], "proxy_managed")
        self.assertIn("NOT_TESTED: app_uid_routing", result.stdout)

    def test_system_family_and_proxy_bypass_are_explicit(self):
        for family in ("4", "6"):
            result = self.one("200", 200, "--mode", "system", "--family", family)
            self.assertEqual(result.returncode, 0)
        args = [json.loads(path.read_text()) for path in self.calls.glob("*.json")]
        self.assertTrue(any("--ipv4" in a for a in args))
        self.assertTrue(any("--ipv6" in a for a in args))
        for a in args:
            self.assertEqual(a[a.index("--proxy") + 1], "")
            self.assertEqual(a[a.index("--noproxy") + 1], "*")

    def test_later_success_does_not_hide_an_earlier_failure(self):
        result = self.one("flaky", 200, "--rounds", "3", "--jobs", "1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("total=3 pass=2 fail=1 incomplete=0", result.stdout)

    def test_multi_target_multi_round_aggregation_and_cleanup(self):
        rows = [f"p{i}|test|https://example.invalid/200|200" for i in range(8)]
        result = self.run_probe(rows, "--rounds", "3", "--jobs", "4")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result_rows(result.stdout)), 24)
        self.assertIn("total=24 pass=24 fail=0 incomplete=0", result.stdout)
        self.assertFalse(list(self.work.glob(".network-check.*")))

    def test_failures_take_priority_over_incomplete(self):
        result = self.run_probe(["a|test|https://example.invalid/403|200",
                                 "b|test|https://example.invalid/exit63|200"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("pass=0 fail=1 incomplete=1", result.stdout)

    def test_private_urls_are_not_in_report(self):
        result = self.run_probe(["private|test|https://example.invalid/secret-token/200|200"])
        self.assertNotIn("secret-token", result.stdout + result.stderr)


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        server = self.server
        with server.counter_lock:
            server.active += 1
            server.peak = max(server.peak, server.active)
        try:
            if self.path == "/slow":
                time.sleep(2)
            if self.path == "/parallel":
                time.sleep(0.15)
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "/ok")
                self.end_headers()
                return
            if self.path == "/loop":
                self.send_response(302)
                self.send_header("Location", "/loop")
                self.end_headers()
                return
            if self.path == "/downgrade":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:9/")
                self.end_headers()
                return
            code = 204 if self.path == "/204" else (503 if self.path == "/503" else 200)
            body = b"" if code == 204 else b"fixture-ok"
            self.send_response(code)
            size = 10000 if self.path == "/truncated" else len(body)
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with contextlib.suppress(BrokenPipeError, ssl.SSLError, ConnectionResetError):
                self.wfile.write(body)
        finally:
            with server.counter_lock:
                server.active -= 1


@unittest.skipUnless(REAL_CURL and shutil.which("openssl"), "real TLS tests require curl and openssl")
class RealTlsTests(unittest.TestCase):
    setUp = ProbeTests.setUp
    run_probe = ProbeTests.run_probe
    # These cases use actual sockets and curl, not mocked connectivity.
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="magicnet-tls-")
        cls.addClassCleanup(cls.fixture.cleanup)
        base = Path(cls.fixture.name)
        cls.cert, key = base / "cert.pem", base / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-days", "1", "-subj", "/CN=localhost", "-addext",
                        "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1", "-keyout",
                        str(key), "-out", str(cls.cert)], check=True, capture_output=True)
        cls.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.context.load_cert_chain(cls.cert, key)
        cls.server = cls.make_server(socket.AF_INET)

    @classmethod
    def make_server(cls, family):
        class Server(http.server.ThreadingHTTPServer):
            address_family = family
            daemon_threads = True
        server = Server(("::1" if family == socket.AF_INET6 else "127.0.0.1", 0), FixtureHandler)
        server.counter_lock = threading.Lock()
        server.active = server.peak = 0
        server.socket = cls.context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        cls.addClassCleanup(server.server_close)
        cls.addClassCleanup(server.shutdown)
        return server

    def real(self, paths, *options, trust=True, server=None):
        realbin = self.work / "realbin"
        realbin.mkdir(exist_ok=True)
        link = realbin / "curl"
        if not link.exists():
            link.symlink_to(REAL_CURL)
        env = dict(self.env, PATH=f"{realbin}:{os.environ['PATH']}",
                   http_proxy="http://127.0.0.1:9", https_proxy="http://127.0.0.1:9",
                   ALL_PROXY="http://127.0.0.1:9", HOME=str(self.work))
        # A user's curlrc cannot disable certificate checking in an acceptance run.
        (self.work / ".curlrc").write_text("insecure\n")
        env.pop("CURL_CA_BUNDLE", None)
        env.pop("SSL_CERT_FILE", None)
        env.pop("SSL_CERT_DIR", None)
        if trust:
            env["CURL_CA_BUNDLE"] = str(self.cert)
        server = server or self.server
        host = "[::1]" if server.address_family == socket.AF_INET6 else "127.0.0.1"
        rows = [f"p{i}|tls|https://{host}:{server.server_port}/{path}|{expected}"
                for i, (path, expected) in enumerate(paths)]
        return self.run_probe(rows, "--mode", "system", *options, env=env)

    def test_real_get_redirect_and_204(self):
        result = self.real([("ok", 200), ("redirect", 200), ("204", 204)], "--family", "4")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("total=3 pass=3 fail=0", result.stdout)

    def test_real_untrusted_tls_not_bypassed_by_curlrc(self):
        result = self.real([("ok", 200)], trust=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result_rows(result.stdout)[0][6], "tls")

    def test_real_truncated_200_fails(self):
        result = self.real([("truncated", 200)])
        self.assertEqual(result.returncode, 1)
        self.assertNotEqual(result_rows(result.stdout)[0][7], "0")

    def test_real_server_error_and_redirect_loop_fail(self):
        for path in ("503", "loop", "downgrade"):
            with self.subTest(path=path):
                result = self.real([(path, 200)])
                self.assertEqual(result.returncode, 1)

    def test_real_captive_portal_200_does_not_satisfy_204(self):
        self.assertEqual(self.real([("ok", 204)]).returncode, 1)

    def test_real_timeout_is_bounded(self):
        started = time.monotonic()
        result = self.real([("slow", 200)], "--timeout", "1")
        self.assertEqual(result.returncode, 1)
        self.assertLess(time.monotonic() - started, 4)
        self.assertEqual(result_rows(result.stdout)[0][6], "timeout")

    def test_real_parallelism_is_bounded_and_all_connections_complete(self):
        # Wait for the timeout fixture to finish before measuring concurrency.
        deadline = time.monotonic() + 3
        while self.server.active and time.monotonic() < deadline:
            time.sleep(0.01)
        self.server.peak = 0
        result = self.real([("parallel", 200)] * 8, "--jobs", "3", "--rounds", "2")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("total=16 pass=16 fail=0", result.stdout)
        self.assertGreater(self.server.peak, 1)
        self.assertLessEqual(self.server.peak, 3)

    def test_real_ipv6_loopback(self):
        try:
            server = self.make_server(socket.AF_INET6)
        except OSError as exc:
            self.skipTest(f"IPv6 loopback unavailable: {exc}")
        result = self.real([("ok", 200)], "--family", "6", server=server)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
