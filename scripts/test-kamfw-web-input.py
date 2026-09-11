"""Exercise real BusyBox httpd/CGI on loopback; no device/network access needed."""
import http.client
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from urllib.parse import urlsplit

FRAMEWORK = Path(__file__).resolve().parents[1] / 'src/MagicNet/lib/kamfw-web'
BUSYBOX = shutil.which('busybox')

class Session:
    def __init__(self, root, *, timeout=12, initial=None, validator=''):
        self.root = Path(root)
        self.public = self.root / 'public'
        self.public.mkdir(exist_ok=True)
        (self.public / 'index.html').write_text('<!doctype html><form id="form"></form>')
        self.output = self.root / 'subscription.url'
        if initial is not None:
            self.output.write_bytes(initial)
        env = dict(os.environ, KAMFW_DIR=str(FRAMEWORK), KAMFW_WEB_INPUT_BUSYBOX=BUSYBOX,
                   KAMFW_WEB_INPUT_NO_OPEN='1')
        script = '''print() { printf '%s\\n' "$*"; }
import() { . "$KAMFW_DIR/$1.sh"; }
. "$KAMFW_DIR/web_input.sh"
web_input_collect "$1" "$2" "$3" "$4"
'''
        self.process = subprocess.Popen([BUSYBOX, 'ash', '-c', script, 'test',
                                         str(self.public), str(self.output), str(timeout), validator],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.log = b''
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.process.stdout], [], [], .1)
            if ready:
                line = self.process.stdout.readline()
                self.log += line
                if line.startswith(b'http://127.0.0.1:'):
                    self.url = line.decode().strip()
                    self.parts = urlsplit(self.url)
                    self.origin = 'http://' + self.parts.netloc
                    self.token = self.parts.fragment
                    return
            if self.process.poll() is not None:
                err = self.process.stderr.read()
                self.close()
                raise AssertionError((self.log, err))
        self.close()
        raise AssertionError('server did not become ready')

    def request(self, body=b'', *, path='/cgi-bin/api/save', method='POST', headers=None):
        hdr = {'X-Setup-Token': self.token, 'Content-Type': 'text/plain;charset=UTF-8', 'Origin': self.origin}
        hdr.update(headers or {})
        connection = http.client.HTTPConnection('127.0.0.1', self.parts.port, timeout=10)
        try:
            connection.request(method, path, body, headers=hdr)
            response = connection.getresponse()
            return response.status, response.read().strip(), dict(response.getheaders())
        finally:
            connection.close()

    def finish(self, expected=0):
        out, err = self.process.communicate(timeout=7)
        self.log += out
        if self.process.returncode != expected:
            raise AssertionError((self.process.returncode, expected, self.log, err))
        if list(self.root.glob('.web-input.*')):
            raise AssertionError('temporary directory was not removed')
        connection = http.client.HTTPConnection('127.0.0.1', self.parts.port, timeout=.5)
        try:
            connection.connect()
        except OSError:
            return
        finally:
            connection.close()
        raise AssertionError('listener survived cleanup')

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
        try:
            self.process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.communicate()

@unittest.skipUnless(BUSYBOX, 'requires BusyBox with httpd/CGI')
class WebInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def session(self, **kwargs):
        session = Session(self.temp.name, **kwargs)
        self.addCleanup(session.close)
        return session

    def test_save_preserves_special_characters_and_permissions(self):
        s = self.session()
        value = b'''https://example.com/a?plus=+&pct=%2B&quote='"&cmd=$(id)&semi=;'''
        code, body, headers = s.request(value)
        self.assertEqual((code, body), (200, b'saved'))
        self.assertEqual(headers['Cache-Control'], 'no-store')
        s.finish()
        self.assertEqual(s.output.read_bytes(), value + b'\n')
        self.assertEqual(s.output.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(value, s.log)

    def test_skip_preserves_existing_file(self):
        s = self.session(initial=b'original\n')
        self.assertEqual(s.request(path='/cgi-bin/api/skip')[:2], (200, b'skipped'))
        s.finish(2)
        self.assertEqual(s.output.read_bytes(), b'original\n')

    def test_changed_file_is_not_overwritten(self):
        s = self.session()
        s.output.write_bytes(b'changed elsewhere\n')
        self.assertEqual(s.request(b'https://example.com/new')[:2], (409, b'changed'))
        self.assertEqual(s.output.read_bytes(), b'changed elsewhere\n')

    def test_authorization_host_origin_and_cross_site(self):
        s = self.session()
        for headers in ({'X-Setup-Token': ''}, {'X-Setup-Token': '0' * 48},
                        {'Host': 'attacker.example'}, {'Origin': 'https://attacker.example'},
                        {'Sec-Fetch-Site': 'cross-site'}):
            with self.subTest(headers=headers):
                self.assertEqual(s.request(b'https://example.com/', headers=headers)[0], 403)
        self.assertFalse(s.output.exists())

    def test_body_limits_methods_and_control_characters(self):
        s = self.session()
        for value in (b'', b'https://example.com/ a', b'https://example.com/\x00',
                      b'https://example.com/\n', b'https://example.com/\x7f'):
            with self.subTest(value=value):
                self.assertEqual(s.request(value)[0], 400)
        self.assertEqual(s.request(b'x' * 8193)[0], 413)
        self.assertEqual(s.request(b'x', headers={'Content-Type': 'application/json'})[0], 415)
        self.assertEqual(s.request(method='GET')[0], 405)
        self.assertEqual(s.request(path='/cgi-bin/api/unknown')[0], 404)
        self.assertFalse(s.output.exists())

    def test_validator_rejects_without_persisting(self):
        validator = Path(self.temp.name) / 'validate.sh'
        validator.write_text('exit 1\n')
        s = self.session(validator=str(validator))
        self.assertEqual(s.request(b'https://example.com/')[0], 422)
        self.assertFalse(s.output.exists())

    def test_private_files_not_served(self):
        s = self.session()
        for path in ('/handler.sh', '/httpd.conf', '/request', '/subscription.url', '/../handler.sh'):
            with self.subTest(path=path):
                code, body, _ = s.request(path=path, method='GET')
                self.assertNotEqual(code, 200)
                self.assertNotIn(s.token.encode(), body)
        code, body, _ = s.request(path='/', method='GET')
        self.assertEqual(code, 200)
        self.assertNotIn(s.token.encode(), body)

    def test_timeout_closes_port_and_preserves_file(self):
        s = self.session(timeout=5, initial=b'old\n')
        time.sleep(5.2)
        s.finish(3)
        self.assertEqual(s.output.read_bytes(), b'old\n')

    def test_symlink_destination_rejected(self):
        target = Path(self.temp.name) / 'target'
        target.write_bytes(b'keep\n')
        (Path(self.temp.name) / 'subscription.url').symlink_to(target)
        with self.assertRaises(AssertionError):
            self.session()
        self.assertEqual(target.read_bytes(), b'keep\n')

    def test_launcher_preserves_error_and_current_user(self):
        root = Path(self.temp.name)
        am = root / 'am'
        am.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >"$AM_TRACE"\nexit 7\n')
        am.chmod(0o700)
        trace = root / 'trace'
        env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], AM_TRACE=str(trace))
        result = subprocess.run([BUSYBOX, 'ash', '-c', '. "$1"; launch browser "$2"', 'test',
                                 str(FRAMEWORK / 'launcher.sh'), 'http://127.0.0.1:12345/#example'], env=env)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(trace.read_text().splitlines(), ['start', '--user', 'current', '-a',
                         'android.intent.action.VIEW', '-c', 'android.intent.category.BROWSABLE',
                         '-d', 'http://127.0.0.1:12345/#example'])

    def test_installer_exit_trap_is_preserved(self):
        marker = Path(self.temp.name) / 'parent-exit'
        script = '''print() { :; }; import() { . "$KAMFW_DIR/$1.sh"; }
. "$KAMFW_DIR/web_input.sh"
trap 'printf parent >"$MARKER"' 0
web_input_collect /missing /missing 0 || :
'''
        result = subprocess.run([BUSYBOX, 'ash', '-c', script], env=dict(os.environ,
                                KAMFW_DIR=str(FRAMEWORK), MARKER=str(marker)), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(marker.read_text(), 'parent')

if __name__ == '__main__':
    unittest.main(verbosity=2)
