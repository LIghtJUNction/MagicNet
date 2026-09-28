#!/usr/bin/env python3
"""Exercise the exact generated smoke-test curl, not a second implementation."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
URL = 'https://example.invalid/subscription.yaml'
METRICS = r'%{http_code}\n%{redirect_url}\n'


class FakeCurlContract(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='mn-curl-contract-')
        self.root = Path(self.directory.name)
        source = (ROOT / 'scripts/fake-magisk-smoke.sh').read_text()
        start = source.index("write_mock curl '\n") + len("write_mock curl '\n")
        end = source.index("\n'\n# shellcheck disable=SC2016\nwrite_mock getent", start)
        self.script = self.root / 'curl'
        self.script.write_text('#!/usr/bin/env bash\nset -euo pipefail\n' + source[start:end] + '\n')
        self.script.chmod(0o700)

    def tearDown(self):
        self.directory.cleanup()

    def run_curl(self, *args, env=None):
        return subprocess.run([str(self.script), *map(str, args)], capture_output=True,
                              timeout=3, env={**os.environ, **(env or {})})

    def test_current_subscription_fetch_separates_body_headers_and_metrics(self):
        out, headers = self.root / 'body', self.root / 'headers'
        result = self.run_curl('-q', '-fs', '--globoff', '--path-as-is', '--noproxy', '*',
                               '--max-redirs', '0', '--proto', '=https', '--proto-redir', '=https',
                               '--compressed', '--max-filesize', '8388608', '--dump-header', headers,
                               '--resolve', 'example.invalid:443:1.1.1.1', '--connect-timeout', '10',
                               '--max-time', '45', '--write-out', METRICS, '-o', out, URL)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'200\n\n')
        self.assertIn(b'fresh-sub-node', out.read_bytes())
        self.assertEqual(headers.read_bytes(), b'HTTP/1.1 200 Fixture\r\nContent-Type: application/yaml\r\n\r\n')

    def test_body_on_stdout_precedes_metrics(self):
        result = self.run_curl(URL, '--output', '-', '--write-out', METRICS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith(b'proxies:\n'))
        self.assertTrue(result.stdout.endswith(b'200\n\n'))

    def test_option_values_after_url_are_not_mistaken_for_urls(self):
        env = {'MAGICNET_FAKE_CURL_FAIL_URL': URL}
        result = self.run_curl(URL, '--noproxy', '*', '--resolve', 'example.invalid:443:1.1.1.1',
                               '--user-agent', 'fixture UA', '--write-out', METRICS, env=env)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, b'000\n\n')

    def test_http_status_override_is_not_an_unconditional_200(self):
        result = self.run_curl(URL, '--write-out', METRICS,
                               env={'MAGICNET_FAKE_CURL_HTTP_CODE_URL': URL,
                                    'MAGICNET_FAKE_CURL_HTTP_CODE': '429'})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'429\n\n')

    def test_website_timing_contract_remains_compatible(self):
        result = self.run_curl('https://www.google.com', '-w',
                               r'%{http_code}|%{time_connect}|%{time_starttransfer}|%{time_total}\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'200|0.010|0.020|0.030\n')

    def test_extended_metrics_from_concurrent_remote_fix_remain_supported(self):
        result = self.run_curl('https://www.google.com', '-w',
                               r'%{time_namelookup}|%{time_appconnect}|%{size_download}|%{num_redirects}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'0.001|0.015|128|0\n')

    def test_unknown_write_out_is_reported_as_fixture_drift(self):
        result = self.run_curl(URL, '-o', '/dev/null', '-w', '%{unsupported_fixture_variable}')
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(b'%{', result.stdout)

    def test_fifo_streams_both_close_and_metrics_do_not_leak_into_body(self):
        body, headers = self.root / 'body.fifo', self.root / 'headers.fifo'
        os.mkfifo(body); os.mkfifo(headers)
        # RDWR guards prevent deadlock even if a regressed fixture never opens
        # one FIFO. They are closed before readers join so EOF is observable.
        guards = [os.open(path, os.O_RDWR | os.O_NONBLOCK) for path in (body, headers)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            readers = [pool.submit(path.read_bytes) for path in (body, headers)]
            try:
                result = self.run_curl(URL, '-D', headers, '-o', body, '-w', METRICS)
            finally:
                for fd in guards: os.close(fd)
            data, head = [reader.result(timeout=3) for reader in readers]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'200\n\n')
        self.assertIn(b'fresh-sub-node', data)
        self.assertNotIn(b'200\n\n', data)
        self.assertTrue(head.endswith(b'\r\n\r\n'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
