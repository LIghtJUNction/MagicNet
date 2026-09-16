#!/usr/bin/env python3
"""Execute the APK's exact Java request engine against local TLS/error fixtures."""
from __future__ import annotations

import http.server
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / 'tests/android-probe/src/best/lmm/magicnet/probe/ProbeClient.java'


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        try:
            if self.path == '/slow':
                time.sleep(3)
            if self.path in ('/redirect204', '/unsafe'):
                self.send_response(302)
                scheme = 'http' if self.path == '/unsafe' else 'https'
                self.send_header('Location', f'{scheme}://localhost:{self.server.server_port}/204')
                self.end_headers()
                return
            if self.path == '/204':
                self.send_response(204)
                self.end_headers()
                return
            if self.path == '/403':
                self.send_response(403)
                self.end_headers()
                return
            self.send_response(200)
            if self.path == '/short':
                self.send_header('Content-Length', '1000')
                body = b'short'
            elif self.path == '/large':
                self.send_header('Content-Length', str(16 * 1024 * 1024))
                body = b'x' * 16384
            elif self.path == '/unknown':
                body = b'x' * 16384
            else:
                body = b'hello'
                self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            count = 1024 if self.path == '/large' else (130 if self.path == '/unknown' else 1)
            for _ in range(count):
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class AndroidJavaProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ('javac', 'java', 'keytool', 'openssl'):
            if not shutil.which(tool):
                raise RuntimeError(f'{tool} is required; do not silently skip the request-engine tests')
        cls.tmp = tempfile.TemporaryDirectory(prefix='magicnet-java-probe-')
        cls.root = Path(cls.tmp.name)
        runner = cls.root / 'Runner.java'
        runner.write_text('''import best.lmm.magicnet.probe.ProbeClient;
public class Runner {
    public static void main(String[] args) {
        ProbeClient.Result result = new ProbeClient().https(args[0], Integer.parseInt(args[1]),
            Integer.parseInt(args[2]), Integer.parseInt(args[3]));
        System.out.println(result.ok + "|" + result.complete + "|" + result.reason + "|" + result.http
            + "|" + result.bytes + "|" + result.elapsedMs);
    }
}
''')
        subprocess.run(['javac', '-d', str(cls.root), str(CLIENT), str(runner)],
                       check=True, capture_output=True, timeout=30)
        cert, key = cls.root / 'cert.pem', cls.root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
                        '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True, timeout=10)
        cls.trust = cls.root / 'trust.p12'
        subprocess.run(['keytool', '-importcert', '-noprompt', '-storetype', 'PKCS12',
                        '-alias', 'fixture', '-file', str(cert), '-keystore', str(cls.trust),
                        '-storepass', 'fixture-only'], check=True, capture_output=True, timeout=10)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)
        cls.tmp.cleanup()

    def probe(self, path, expected=200, prefix=0, timeout=3000, trusted=True):
        args = ['java']
        if trusted:
            args += [f'-Djavax.net.ssl.trustStore={self.trust}', '-Djavax.net.ssl.trustStorePassword=fixture-only']
        args += ['-cp', str(self.root), 'Runner',
                 f'https://localhost:{self.server.server_port}{path}', str(expected), str(prefix), str(timeout)]
        cp = subprocess.run(args, check=True, capture_output=True, text=True, timeout=8)
        ok, complete, reason, status, size, elapsed = cp.stdout.strip().split('|')
        return dict(ok=ok == 'true', complete=complete == 'true', reason=reason,
                    status=int(status), size=int(size), elapsed=int(elapsed))

    def test_exact_200_and_empty_204(self):
        self.assertTrue(self.probe('/200')['ok'])
        self.assertTrue(self.probe('/204', expected=204)['ok'])
        self.assertFalse(self.probe('/200', expected=204)['ok'])
        self.assertFalse(self.probe('/204', expected=200)['ok'])

    def test_errors_redirected_204_and_downgrade_never_pass(self):
        for path, status in (('/403', 200), ('/redirect204', 204), ('/unsafe', 200)):
            with self.subTest(path=path):
                self.assertFalse(self.probe(path, expected=status)['ok'])

    def test_untrusted_certificate_is_not_bypassed(self):
        result = self.probe('/200', trusted=False)
        self.assertFalse(result['ok'])
        self.assertEqual(result['reason'], 'tls')

    def test_premature_eof_fails_even_after_http_200(self):
        result = self.probe('/short')
        self.assertFalse(result['ok'])
        self.assertEqual(result['reason'], 'short_body')

    def test_known_and_unknown_length_body_limits(self):
        for path in ('/large', '/unknown'):
            with self.subTest(path=path):
                result = self.probe(path)
                self.assertFalse(result['ok'])
                self.assertFalse(result['complete'])
                self.assertLessEqual(result['size'], 2 * 1024 * 1024 + 1)

    def test_speed_requires_exact_bounded_prefix(self):
        result = self.probe('/large', prefix=8 * 1024 * 1024, timeout=5000)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['size'], 8 * 1024 * 1024)
        self.assertFalse(self.probe('/200', prefix=100)['ok'])
        self.assertFalse(self.probe('/403', prefix=100)['ok'])

    def test_outer_deadline_covers_response_stalls(self):
        started = time.monotonic()
        result = self.probe('/slow', timeout=300)
        self.assertFalse(result['ok'])
        self.assertEqual(result['reason'], 'timeout')
        self.assertLess(time.monotonic() - started, 2.5)


if __name__ == '__main__':
    unittest.main()
