#!/usr/bin/env python3
"""The smoke curl fixture must model the production direct-fetch contract."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'scripts/fake-magisk-smoke.sh').read_text()
CURL = SOURCE.split("write_mock curl '\n", 1)[1].split("\n'", 1)[0]


class CurlFixtureTests(unittest.TestCase):
    def test_direct_subscription_returns_separate_body_headers_and_metrics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body, headers = root / 'body', root / 'headers'
            cp = subprocess.run(['bash', '-c', CURL, 'curl', '-q', '-fs', '--globoff',
                '--noproxy', '*', '--max-redirs', '0', '--proto', '=https',
                '--proto-redir', '=https', '--max-filesize', '1048576',
                '--dump-header', str(headers), '--resolve', 'example.invalid:443:1.1.1.1',
                '--write-out', '%{http_code}\n%{redirect_url}\n', '-o', str(body),
                'https://example.invalid/subscription.yaml'], capture_output=True, text=True, timeout=5)
            self.assertEqual(cp.returncode, 0, cp.stderr)
            self.assertEqual(cp.stdout, '200\n\n')
            self.assertIn('proxies:', body.read_text())
            self.assertTrue(headers.read_bytes().startswith(b'HTTP/1.1 200 OK'))

    def test_connection_error_still_fails(self):
        url = 'https://example.invalid/unavailable'
        cp = subprocess.run(['bash', '-c', CURL, 'curl', '-w', '%{http_code}', url],
            env=dict(os.environ, MAGICNET_FAKE_CURL_FAIL_URL=url),
            capture_output=True, text=True, timeout=5)
        self.assertEqual(cp.returncode, 7)
        self.assertEqual(cp.stdout, '000')


if __name__ == '__main__':
    unittest.main()
