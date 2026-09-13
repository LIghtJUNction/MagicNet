#!/usr/bin/env python3
"""Offline regression tests: real curl/TLS/HTTP on loopback + error fixtures.

No public network or subscription is used; these are NOT Android acceptance tests.
"""
import csv
import io
import json
import os
from pathlib import Path
import shutil
import signal
import select
import socket
import socketserver
import struct
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
PROBE_SHELL = os.environ.get("MAGICNET_TEST_SHELL", "sh")
PROBE = ROOT / "src/MagicNet/lib/magicnet/website_probe.sh"
CATALOG = ROOT / "src/MagicNet/.config/magicnet/website-targets.tsv"


class Handler(BaseHTTPRequestHandler):
    active = 0
    peak = 0
    flaky = 0
    lock = threading.Lock()

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, ssl.SSLError):
            pass

    def do_GET(self):
        path = self.path
        data = b"local HTTPS test body\n"
        status = 200
        if path == "/delay":
            with self.lock:
                Handler.active += 1
                Handler.peak = max(Handler.peak, Handler.active)
            time.sleep(0.12)
            with self.lock:
                Handler.active -= 1
        if path == "/flaky":
            with self.lock:
                Handler.flaky += 1
                status = 503 if Handler.flaky % 2 == 0 else 200
        if path in ("/401", "/403", "/404", "/410", "/429", "/500", "/204"):
            status = int(path[1:])
        if path in ("/empty", "/204"):
            data = b""
        if path in ("/redirect", "/loop", "/downgrade"):
            self.send_response(302)
            self.send_header("Location", {
                "/redirect": "/ok", "/loop": "/loop",
                "/downgrade": f"http://localhost:{self.server.server_port}/ok",
            }[path])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(status)
        length = 3_000_000 if path == "/large" else len(data)
        if path in ("/truncated", "/slow"):
            length += 100
        self.send_header("Content-Length", str(length))
        self.end_headers()
        try:
            if path != "/large":
                self.wfile.write(data)
                self.wfile.flush()
            if path == "/slow":
                time.sleep(1.4)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class SocksHandler(socketserver.BaseRequestHandler):
    """Loopback SOCKS fixture; only the reserved test hostname is permitted."""
    def read_exact(self, count):
        data = b""
        while len(data) < count:
            chunk = self.request.recv(count - len(data))
            if not chunk:
                raise ConnectionError("short SOCKS request")
            data += chunk
        return data

    def handle(self):
        self.request.settimeout(3)
        try:
            version, count = self.read_exact(2)
            methods = self.read_exact(count)
            if version != 5 or 0 not in methods:
                return
            self.request.sendall(b"\x05\x00")
            version, command, reserved, address_type = self.read_exact(4)
            if (version, command, reserved, address_type) != (5, 1, 0, 3):
                return
            hostname = self.read_exact(self.read_exact(1)[0]).decode("ascii")
            port = struct.unpack("!H", self.read_exact(2))[0]
            if hostname != "probe.invalid" or port != self.server.target_port:
                return
            self.server.seen_hostname = hostname
            with socket.create_connection(("127.0.0.1", port), timeout=3) as upstream:
                self.request.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                peers = [self.request, upstream]
                while True:
                    readable, _, _ = select.select(peers, [], [], 3)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        target = upstream if source is self.request else self.request
                        target.sendall(data)
        except (OSError, ConnectionError):
            return


class WebsiteProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.curl = shutil.which("curl")
        openssl = shutil.which("openssl")
        if not cls.curl or not openssl:
            raise RuntimeError("curl and openssl are required; do not silently skip network regressions")
        cls.shared = tempfile.TemporaryDirectory()
        base = Path(cls.shared.name)
        cls.cert = base / "cert.pem"
        key = base / "key.pem"
        subprocess.run([
            openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-keyout", str(key), "-out", str(cls.cert), "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,DNS:probe.invalid",
        ], check=True, capture_output=True, timeout=15)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cls.cert, key)
        cls.server.socket = tls.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.origin = f"https://localhost:{cls.server.server_port}"
        cls.socks = socketserver.ThreadingTCPServer(("127.0.0.1", 0), SocksHandler)
        cls.socks.daemon_threads = True
        cls.socks.target_port = cls.server.server_port
        cls.socks.seen_hostname = None
        cls.socks_thread = threading.Thread(target=cls.socks.serve_forever, daemon=True)
        cls.socks_thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.socks.shutdown()
        cls.socks.server_close()
        cls.socks_thread.join(timeout=3)
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=3)
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.env = dict(os.environ, MAGICNET_CURL=self.curl,
                        CURL_CA_BUNDLE=str(self.cert), TMPDIR=str(self.base))
        self.mock = self.base / "mock-curl"
        self.mock.write_text("""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
if os.environ.get('ARGS_FILE'):
    Path(os.environ['ARGS_FILE']).write_text(json.dumps(sys.argv[1:]))
if os.environ.get('PID_FILE'):
    Path(os.environ['PID_FILE']).write_text(str(os.getpid()))
time.sleep(float(os.environ.get('MOCK_SLEEP', '0')))
default = '204\\t0.01\\t0.02\\t0.03\\t0.04\\t0.05\\t0\\t0' if sys.argv[-1].endswith('/generate_204') else '200\\t0.01\\t0.02\\t0.03\\t0.04\\t0.05\\t12\\t0'
print(os.environ.get('METRICS', default))
sys.exit(int(os.environ.get('MOCK_RC', '0')))
""")
        self.mock.chmod(0o755)

    def row(self, path="/ok", code="200", body="nonempty", name="local"):
        return f"{name}\ttest\t{self.origin}{path}\t{code}\t{body}\n"

    def command(self, rows=None, extra=()):
        target = self.base / "targets.tsv"
        target.write_text(self.row() if rows is None else rows)
        return [PROBE_SHELL, str(PROBE), "--targets", str(target), "--path", "native",
                "--family", "4", "--jobs", "1", "--timeout", "3", *extra]

    def run_probe(self, rows=None, extra=(), env=None):
        result = subprocess.run(self.command(rows, extra), env=self.env if env is None else env,
                                text=True, capture_output=True, timeout=20)
        self.assertFalse(list(self.base.glob("magicnet-web.*")), "temporary files leaked")
        return result

    def records(self, result):
        lines = [line for line in result.stdout.splitlines() if line and not line.startswith("#")]
        return list(csv.DictReader(io.StringIO("\n".join(lines)), delimiter="\t"))

    def check_result(self, path, expected, code="200", body="nonempty", extra=()):
        result = self.run_probe(self.row(path, code, body), extra)
        rows = self.records(result)
        self.assertEqual(len(rows), 1, result.stderr + result.stdout)
        self.assertEqual(rows[0]["result"], expected, result.stdout)
        self.assertEqual(result.returncode, 0 if expected == "PASS" else 1, result.stderr)
        return result

    def test_real_https_get(self):
        result = self.check_result("/ok", "PASS")
        row = self.records(result)[0]
        self.assertGreater(float(row["tls_s"]), 0)
        self.assertGreater(int(row["bytes"]), 0)
        self.assertNotIn(self.origin, result.stdout)
        self.assertIn("transparent=NOT_VERIFIED udp=NOT_TESTED", result.stdout)

    def test_204_exact_empty_body(self):
        self.check_result("/204", "PASS", "204", "empty")

    def test_200_cannot_pass_a_204_connectivity_check(self):
        self.check_result("/ok", "HTTP_ERROR", "204", "empty")

    def test_empty_200_fails(self):
        self.check_result("/empty", "EMPTY_BODY")

    def test_unexpected_body_fails(self):
        self.check_result("/ok", "UNEXPECTED_BODY", body="empty")

    def test_restricted_is_not_success(self):
        for status in (401, 403):
            with self.subTest(status=status):
                self.check_result(f"/{status}", "RESTRICTED")

    def test_rate_limit_is_not_success(self):
        self.check_result("/429", "RATE_LIMITED")

    def test_changed_endpoints_are_not_dns_failures(self):
        for status in (404, 410):
            with self.subTest(status=status):
                self.check_result(f"/{status}", "ENDPOINT_CHANGED")

    def test_server_error(self):
        self.check_result("/500", "HTTP_ERROR")

    def test_https_redirect(self):
        result = self.check_result("/redirect", "PASS")
        self.assertEqual(self.records(result)[0]["redirects"], "1")

    def test_redirect_loop(self):
        self.check_result("/loop", "REDIRECT_LOOP")

    def test_https_downgrade_is_rejected(self):
        self.check_result("/downgrade", "PROTOCOL_OR_TOOL_ERROR")

    def test_timeout_after_http_200_does_not_pass(self):
        result = self.check_result("/slow", "TIMEOUT", extra=("--timeout", "1"))
        self.assertEqual(self.records(result)[0]["http_code"], "200")

    def test_truncated_body_does_not_pass(self):
        result = self.check_result("/truncated", "CURL_ERROR")
        self.assertNotEqual(self.records(result)[0]["curl_exit"], "0")

    def test_response_size_limit(self):
        self.check_result("/large", "DATA_LIMIT")

    def test_real_certificate_trust_verification(self):
        env = dict(self.env)
        for key in ("CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR"):
            env.pop(key, None)
        result = self.run_probe(env=env)
        self.assertEqual(self.records(result)[0]["result"], "TLS_CERT_ERROR")
        self.assertEqual(result.returncode, 1)

    def test_real_hostname_verification(self):
        result = self.run_probe(self.row().replace("localhost", "127.0.0.1"))
        self.assertEqual(self.records(result)[0]["result"], "TLS_CERT_ERROR")
        self.assertEqual(result.returncode, 1)

    def test_native_ignores_inherited_proxies(self):
        env = dict(self.env)
        for key in ("http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
            env[key] = "http://127.0.0.1:1"
        env["NO_PROXY"] = ""
        result = self.run_probe(env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_curlrc_cannot_inject_a_proxy_or_extra_url(self):
        (self.base / ".curlrc").write_text(f'proxy = "http://127.0.0.1:1"\nurl = "{self.origin}/403"\n')
        result = self.run_probe(env=dict(self.env, CURL_HOME=str(self.base)))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.records(result)), 1)

    def test_dns_and_connect_errors(self):
        for rc, expected in ((5, "DNS_ERROR"), (6, "DNS_ERROR"), (7, "CONNECT_ERROR"), (35, "TLS_ERROR")):
            with self.subTest(rc=rc):
                result = self.run_probe(env=dict(self.env, MAGICNET_CURL=str(self.mock), MOCK_RC=str(rc)))
                self.assertEqual(self.records(result)[0]["result"], expected)
                self.assertEqual(result.returncode, 1)

    def test_bad_metrics_never_pass(self):
        for metrics in ("", "200", "200\t0\t0\t0\t0\t0\t12\t0\nINJECTED", "200\t0\t0\t0\t0\t0\tNaN\t0"):
            with self.subTest(metrics=metrics):
                result = self.run_probe(env=dict(self.env, MAGICNET_CURL=str(self.mock), METRICS=metrics))
                self.assertEqual(self.records(result)[0]["result"], "BAD_METRICS")
                self.assertEqual(result.returncode, 1)

    def test_missing_curl_fails_instead_of_skipping(self):
        result = self.run_probe(env=dict(self.env, MAGICNET_CURL=str(self.base / "absent")))
        self.assertEqual(result.returncode, 2)

    def test_catalog_is_validated_before_any_network(self):
        args_file = self.base / "args.json"
        invalid = ["", "# empty\n", self.row() * 2, self.row().replace("https://", "http://"),
                   self.row().replace("localhost", "user:password@localhost"),
                   self.row().replace("\t200\t", "\t403\t"),
                   self.row().replace("\tnonempty", "\tmaybe"), self.row().replace("local\t", "bad name\t", 1),
                   self.row() + "malformed\n",
                   "".join(self.row(name=f"entry{i}") for i in range(101))]
        for rows in invalid:
            with self.subTest(rows=rows[:80]):
                result = self.run_probe(rows, env=dict(self.env, MAGICNET_CURL=str(self.mock), ARGS_FILE=str(args_file)))
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertFalse(args_file.exists(), "network started before validation finished")

    def test_invalid_cli_arguments(self):
        for extra in (("--jobs", "0"), ("--jobs", "9"), ("--repeat", "4"), ("--timeout", "0"),
                      ("--timeout", "99999999999999999"), ("--timeout", "01"), ("--path", "tun"),
                      ("--proxy-port", "65536"), ("--family", "7"), ("--unknown",), ("--jobs",)):
            with self.subTest(extra=extra):
                self.assertEqual(self.run_probe(extra=extra).returncode, 64)

    def test_no_final_newline_is_supported(self):
        self.assertEqual(self.run_probe(self.row().rstrip("\n")).returncode, 0)

    def test_socks5h_uses_remote_dns_and_cannot_be_bypassed_by_no_proxy(self):
        args_file = self.base / "args.json"
        result = self.run_probe(extra=("--path", "mixed", "--family", "auto"),
                                env=dict(self.env, MAGICNET_CURL=str(self.mock), ARGS_FILE=str(args_file), NO_PROXY="*"))
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(args_file.read_text())
        self.assertEqual(args[0], "-q")
        self.assertEqual(args[args.index("--proxy") + 1], "socks5h://127.0.0.1:7892")
        self.assertEqual(args[args.index("--noproxy") + 1], "")
        for forbidden in ("-k", "--insecure", "-I", "--head", "--retry-all-errors"):
            self.assertNotIn(forbidden, args)
        self.assertEqual(args[args.index("--retry") + 1], "0")

    def test_real_socks5h_delegates_dns_and_transports_tls(self):
        # .invalid cannot resolve locally; only the SOCKS server knows this name.
        result = self.run_probe(self.row().replace("localhost", "probe.invalid"),
                                extra=("--path", "mixed", "--family", "auto",
                                       "--proxy-port", str(self.socks.server_address[1])),
                                env=dict(self.env, NO_PROXY="*", ALL_PROXY="http://127.0.0.1:1"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.socks.seen_hostname, "probe.invalid")
        self.assertEqual(self.records(result)[0]["result"], "PASS")
        self.assertGreater(float(self.records(result)[0]["tls_s"]), 0)

    def test_socks5h_cannot_claim_destination_ipv4_or_ipv6(self):
        for family in ("4", "6"):
            self.assertEqual(self.run_probe(extra=("--path", "mixed", "--family", family)).returncode, 64)

    def test_native_family_flags(self):
        args_file = self.base / "args.json"
        for family in ("4", "6"):
            result = self.run_probe(extra=("--family", family),
                                    env=dict(self.env, MAGICNET_CURL=str(self.mock), ARGS_FILE=str(args_file)))
            self.assertEqual(result.returncode, 0)
            args = json.loads(args_file.read_text())
            self.assertIn("-" + family, args)
            self.assertEqual(args[args.index("--proxy") + 1], "")

    def test_root_native_result_is_explicitly_not_an_app_verdict(self):
        fake_id = self.base / "id"
        fake_id.write_text("#!/bin/sh\nprintf '0\\n'\n")
        fake_id.chmod(0o755)
        result = self.run_probe(env=dict(self.env, PATH=str(self.base) + os.pathsep + self.env["PATH"]))
        self.assertEqual(result.returncode, 0)
        self.assertIn("uid=0", result.stdout)
        self.assertIn("not an app verdict", result.stdout)

    def test_repeated_rounds_do_not_hide_transient_failures(self):
        Handler.flaky = 0
        result = self.run_probe(self.row("/flaky"), extra=("--repeat", "3"))
        rows = self.records(result)
        self.assertEqual([r["result"] for r in rows], ["PASS", "HTTP_ERROR", "PASS"])
        self.assertEqual([r["round"] for r in rows], ["1", "2", "3"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("total=3 passed=2 failed=1", result.stdout)

    def test_concurrent_real_tls_requests_are_bounded_and_all_reported(self):
        Handler.peak = 0
        rows = "".join(self.row("/delay", name=f"site{i}") for i in range(6))
        result = self.run_probe(rows, extra=("--jobs", "2"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.records(result)), 6)
        self.assertEqual(Handler.peak, 2)
        self.assertEqual([r["id"] for r in self.records(result)], [f"site{i}" for i in range(6)])

    def test_cancellation_kills_workers_and_removes_temporary_files(self):
        pid_file = self.base / "curl.pid"
        env = dict(self.env, MAGICNET_CURL=str(self.mock), PID_FILE=str(pid_file), MOCK_SLEEP="20")
        process = subprocess.Popen(self.command(), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pid_file.exists(), "curl worker never started")
            worker_pid = int(pid_file.read_text())
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143)
            with self.assertRaises(ProcessLookupError):
                os.kill(worker_pid, 0)
            self.assertFalse(list(self.base.glob("magicnet-web.*")))
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_shipped_catalog_covers_common_services_and_is_parseable(self):
        result = self.run_probe(CATALOG.read_text(), env=dict(self.env, MAGICNET_CURL=str(self.mock)))
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        rows = self.records(result)
        self.assertGreaterEqual(len(rows), 25)
        names = {r["id"] for r in rows}
        self.assertTrue({"wechat", "baidu", "bilibili", "google-play", "google-login", "gstatic-204",
                         "youtube", "github", "chatgpt", "claude", "discord", "telegram"} <= names)


if __name__ == "__main__":
    unittest.main(verbosity=2)
