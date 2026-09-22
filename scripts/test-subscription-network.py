#!/usr/bin/env python3
"""Real curl against an isolated HTTPS fault server, never a user subscription.

Only DNS in the fixture is overridden to reach loopback; production private-IP
rejection is covered by test-subscription-fetch-policy.sh. No TLS bypass is used.
"""
import collections
import gzip
import http.server
import os
from pathlib import Path
import shlex
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOST = "subscription.example.invalid"
BODY = b"proxies:\n  - {name: fixture, type: trojan, server: node.invalid, port: 443, password: fixture}\n"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    counts = collections.Counter()

    def log_message(self, *_):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        self.counts[path] += 1
        status, body, headers = 200, BODY, {}
        if path == "/gzip":
            body = gzip.compress(BODY)
            headers["Content-Encoding"] = "gzip"
        elif path.startswith("/redirect"):
            status, body = 302, b""
            headers["Location"] = {
                "/redirect": "/gzip",
                "/redirect-cross": f"https://other.example.invalid:{self.server.server_port}/gzip",
                "/redirect-private": "https://127.0.0.1/private",
                "/redirect-http": "http://subscription.example.invalid/plain",
                "/redirect-userinfo": "https://user:fixture@subscription.example.invalid/private",
                "/redirect-loop": "/redirect-loop",
            }[path]
        elif path.startswith("/status-"):
            status = int(path.removeprefix("/status-"))
            body = b"error body must not become nodes"
        elif path == "/retry" and self.counts[path] < 3:
            status, body = 503, b"temporarily unavailable"
        elif path == "/rate-limit" and self.counts[path] < 2:
            status, body = 429, b"rate limited"
        elif path == "/empty":
            body = b""
        elif path == "/truncated":
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.end_headers()
            self.wfile.write(b"partial")
            self.close_connection = True
            return
        elif path == "/slow":
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.end_headers()
            time.sleep(3)
            self.close_connection = True
            return
        elif path == "/overflow":
            body = gzip.compress(b"x" * (8388608 + 1))
            headers["Content-Encoding"] = "gzip"
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Subscription-Userinfo", "upload=1; download=2; total=100")
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class QuietServer(http.server.ThreadingHTTPServer):
    def handle_error(self, _request, _client_address):
        # Oversize and timeout tests deliberately close TLS streams early.
        pass


class NetworkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for command in ("curl", "openssl", "bash"):
            if not shutil.which(command):
                raise RuntimeError(f"required test dependency missing: {command}")
        cls.tmp = tempfile.TemporaryDirectory(prefix="magicnet-https-")
        cls.root = Path(cls.tmp.name)
        cls.cert = cls.root / "cert.pem"
        key = cls.root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", str(key), "-out", str(cls.cert), "-subj", f"/CN={HOST}", "-addext", f"subjectAltName=DNS:{HOST},DNS:other.example.invalid"], check=True, capture_output=True)
        cls.server = QuietServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cls.cert, key)
        cls.server.socket = tls.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        # A malicious default curl config must not add a URL or disable TLS.
        (cls.root / ".curlrc").write_text('insecure\nurl = "http://127.0.0.1:1/UNEXPECTED"\n')

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.tmp.cleanup()

    def fetch(self, path, *, success=True, budget=12, trust=True):
        Handler.counts.clear()
        target = self.root / "download"
        resolution_log = self.root / "resolutions"
        resolution_log.write_text("")
        code = f'''set -eu
. {shlex.quote(str(ROOT / "src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh"))}
warn() {{ printf '%s\\n' "$*" >&2; }}
magicnet_singbox_subscription_resolve_public() {{
    magicnet_singbox_subscription_parse_authority "$1" || return 1
    printf '%s\\n' "$_subscription_host" >>{shlex.quote(str(resolution_log))}
    case "$_subscription_host" in
      {HOST}|other.example.invalid) printf '%s|%s|127.0.0.1\\n' "$_subscription_host" "$_subscription_port" ;;
      *) return 1 ;;
    esac
}}
magicnet_singbox_try_fetch_subscription {shlex.quote(f'https://{HOST}:{self.server.server_port}{path}?token=PRIVATE_FIXTURE')} {shlex.quote(str(target))} 2 {budget}
'''
        env = {**os.environ, "HOME": str(self.root), "CURL_HOME": str(self.root), "http_proxy": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1", "ALL_PROXY": "http://127.0.0.1:1"}
        if trust:
            env["CURL_CA_BUNDLE"] = str(self.cert)
        else:
            env.pop("CURL_CA_BUNDLE", None)
        started = time.monotonic()
        cp = subprocess.run(["bash", "-c", code], capture_output=True, text=True, env=env, timeout=budget + 5)
        self.assertEqual(cp.returncode == 0, success, cp.stderr)
        self.assertNotIn("PRIVATE_FIXTURE", cp.stdout + cp.stderr)
        self.assertEqual(list(self.root.glob("download.*")), [self.root / "download.usage.json"] if success else [])
        self.assertEqual(target.exists(), success)
        return target.read_bytes() if success else b"", time.monotonic() - started, resolution_log.read_text()

    def test_gzip_https_ignores_env_proxies_and_curlrc(self):
        body, _, _ = self.fetch("/gzip")
        self.assertEqual(body, BODY)
        self.assertEqual(sum(Handler.counts.values()), 1)

    def test_relative_and_cross_host_redirects_are_revalidated(self):
        for path in ("/redirect", "/redirect-cross"):
            with self.subTest(path=path):
                body, _, resolutions = self.fetch(path)
                self.assertEqual(body, BODY)
                self.assertEqual(len(resolutions.splitlines()), 2)
                if path.endswith("cross"):
                    self.assertIn("other.example.invalid", resolutions)

    def test_unsafe_redirects_and_redirect_loops_fail_closed(self):
        for path in ("/redirect-private", "/redirect-http", "/redirect-userinfo", "/redirect-loop"):
            with self.subTest(path=path):
                self.fetch(path, success=False)
                self.assertEqual(sum(Handler.counts.values()), 6 if path.endswith("loop") else 1)

    def test_transient_http_errors_retry_without_appending_bodies(self):
        for path, attempts in (("/retry", 3), ("/rate-limit", 2)):
            with self.subTest(path=path):
                body, _, _ = self.fetch(path)
                self.assertEqual(body, BODY)
                self.assertEqual(Handler.counts[path], attempts)

    def test_permanent_http_errors_are_not_retried(self):
        for status in (401, 403, 404, 410):
            with self.subTest(status=status):
                self.fetch(f"/status-{status}", success=False)
                self.assertEqual(sum(Handler.counts.values()), 1)

    def test_tls_validation_cannot_be_disabled_by_curlrc(self):
        self.fetch("/gzip", trust=False, success=False)
        self.assertEqual(sum(Handler.counts.values()), 0)

    def test_partial_empty_and_decompressed_oversize_bodies_are_discarded(self):
        for path in ("/truncated", "/empty", "/overflow"):
            with self.subTest(path=path):
                self.fetch(path, success=False)

    def test_source_set_never_succeeds_with_a_missing_provider(self):
        # Exercise the real multi-source collector with controlled transport
        # outcomes; failed candidate manifests are discarded by update.sh.
        for urls, failed, success in [
            (["a", "b"], "b", False),
            (["b", "a"], "b", False),
            (["b"], "b", False),
            (["a"], "b", True),
            (["b", "a"], "", True),
        ]:
            with self.subTest(urls=urls, failed=failed):
                source_root = self.root / "sources-case"
                source_root.mkdir(exist_ok=True)
                url_file = source_root / "urls"
                url_file.write_text("".join(f"https://{name}.invalid/sub\n" for name in urls))
                code = f'''set -eu
. {shlex.quote(str(ROOT / "src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh"))}
warn() {{ :; }}
error() {{ :; }}
magicnet_singbox_subscription_url_file() {{ printf '%s\\n' {url_file}; }}
magicnet_singbox_subscription_cache_dir() {{ printf '%s\\n' {source_root / "cache"}; }}
magicnet_singbox_subscription_fingerprint() {{ printf '%s' "$1" | sha256sum | cut -d ' ' -f1; }}
magicnet_singbox_fetch_one_subscription() {{
  [ "$1" != "https://{failed}.invalid/sub" ] || return 1
  printf 'fixture-node\\n' >"$2"
}}
magicnet_singbox_fetch_subscription {source_root / "manifest"}
[ "$MAGICNET_SUB_CONFIGURED_COUNT" = "$MAGICNET_SUB_SOURCE_COUNT" ]
'''
                cp = subprocess.run(["bash", "-c", code], text=True, capture_output=True, timeout=10)
                self.assertEqual(cp.returncode == 0, success, cp.stderr)

    def test_timeout_bounds_body_and_fifo_cleanup(self):
        _, elapsed, _ = self.fetch("/slow", budget=1, success=False)
        self.assertLess(elapsed, 3)


if __name__ == "__main__":
    unittest.main()
