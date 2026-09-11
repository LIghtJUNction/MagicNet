#!/usr/bin/env python3
"""Installation adapter + real kamfw/BusyBox loopback regressions (no root needed)."""
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

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/MagicNet'
FRAMEWORK = SOURCE / 'lib/kamfw-web'
BB = shutil.which('busybox')
SCRIPT = '''set_i18n() { :; }; i18n() { printf '%s' "$1"; }
print() { printf '%s\\n' "$*"; }
import() { . "$KAMFW_DIR/$1.sh"; }
. "$MODPATH/lib/magicnet/install_web.sh"
magicnet_install_collect_subscription
'''

@unittest.skipUnless(BB, 'requires BusyBox httpd/CGI')
class InstallWebTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.module = self.root / 'module'
        shutil.copytree(SOURCE / 'setup', self.module / 'setup')
        (self.module / 'lib/magicnet').mkdir(parents=True)
        for name in ('install_web.sh', 'install_subscription_validate.sh'):
            shutil.copyfile(SOURCE / 'lib/magicnet' / name, self.module / 'lib/magicnet' / name)
        shutil.copytree(FRAMEWORK, self.module / 'lib/kamfw-web')
        (self.module / 'lib/kamfw').mkdir()
        self.config = self.module / '.config/sing-box'
        self.config.mkdir(parents=True)
        self.output = self.config / 'subscription.url'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        am = self.bin / 'am'
        am.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >"$AM_TRACE"\nexit "${AM_EXIT:-0}"\n')
        am.chmod(0o700)
        self.trace = self.root / 'am.trace'
        self.env = dict(os.environ, MODPATH=str(self.module), KAMFW_DIR=str(self.module/'lib/kamfw'),
                        KAMFW_WEB_INPUT_BUSYBOX=BB, KAMFW_WEB_INPUT_NO_OPEN='0',
                        AM_TRACE=str(self.trace), PATH=str(self.bin)+':'+os.environ['PATH'],
                        BOOTMODE='true', MAGICNET_NONINTERACTIVE='0', MAGIC_SINGBOX='1',
                        MAGICNET_SETUP_TIMEOUT='12', IS_TTY='false')

    def start(self, **overrides):
        process = subprocess.Popen([BB, 'ash', '-c', SCRIPT], env=dict(self.env, **overrides),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        def close():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            try: process.communicate(timeout=4)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.communicate()
        self.addCleanup(close)
        return process

    def page(self, process):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if select.select([process.stdout], [], [], .1)[0]:
                line = process.stdout.readline()
                if line.startswith(b'http://127.0.0.1:'):
                    parts = urlsplit(line.decode().strip())
                    return parts
            if process.poll() is not None:
                self.fail(('no setup page', process.communicate()))
        self.fail('setup page timed out')

    def request(self, parts, value=b'', action='save'):
        conn = http.client.HTTPConnection('127.0.0.1', parts.port, timeout=10)
        try:
            conn.request('POST', '/cgi-bin/api/'+action, value,
                         {'X-Setup-Token':parts.fragment, 'Content-Type':'text/plain',
                          'Origin':'http://'+parts.netloc})
            result = conn.getresponse()
            return result.status, result.read().strip()
        finally: conn.close()

    def test_first_manager_install_opens_framework_browser_and_saves(self):
        process = self.start()
        parts = self.page(process)
        value = b"https://example.com/sub?token=a%2Bb&plus=+&data=$(id)"
        self.assertEqual(self.request(parts,value),(200,b'saved'))
        out, err = process.communicate(timeout=7)
        self.assertEqual(process.returncode,0,err)
        self.assertIn(b'INSTALL_WEB_SAVED',out)
        self.assertEqual(self.output.read_bytes(),value+b'\n')
        self.assertEqual(self.output.stat().st_mode & 0o777,0o600)
        args = self.trace.read_text().splitlines()
        self.assertEqual(args[:3],['start','--user','current'])
        self.assertIn('android.intent.category.BROWSABLE',args)
        self.assertEqual(args[-1],parts.geturl())
        self.assertNotIn(value,out+err)
        self.assertFalse(list(self.config.glob('.web-input.*')))

    def test_existing_remote_source_preserved_without_browser(self):
        value=b'# existing sources\nhttps://example.com/one\nhttps://example.org/two\n'
        self.output.write_bytes(value)
        process=self.start(); out,err=process.communicate(timeout=3)
        self.assertEqual(process.returncode,0,err)
        self.assertFalse(self.trace.exists())
        self.assertEqual(self.output.read_bytes(),value)
        self.assertEqual(out,b'')

    def test_local_and_standalone_sources_preserved(self):
        for source in ('local','standalone'):
            with self.subTest(source=source):
                local=self.config/'subscription.local'; marker=self.config/'standalone-config'
                if source=='local': local.write_text('private local import')
                else:
                    local.unlink(); marker.touch(); (self.config/'config.json').write_text('{"outbounds":[]}')
                process=self.start(); _,err=process.communicate(timeout=3)
                self.assertEqual(process.returncode,0,err)
                self.assertFalse(self.trace.exists())
                self.assertFalse(self.output.exists())

    def test_recovery_noninteractive_and_disabled_core_do_not_prompt(self):
        for overrides in ({'BOOTMODE':'false'},{'MAGICNET_NONINTERACTIVE':'1'},{'MAGIC_SINGBOX':'0'}):
            with self.subTest(overrides=overrides):
                process=self.start(**overrides); out,err=process.communicate(timeout=3)
                self.assertEqual(process.returncode,0,err)
                self.assertEqual(out,b'')
                self.assertFalse(self.trace.exists())

    def test_comment_only_file_prompts_and_skip_preserves_it(self):
        self.output.write_bytes(b'# not configured\n\n')
        process=self.start(); parts=self.page(process)
        self.assertEqual(self.request(parts,action='skip'),(200,b'skipped'))
        out,err=process.communicate(timeout=7)
        self.assertEqual(process.returncode,0,err)
        self.assertIn(b'INSTALL_WEB_LATER',out)
        self.assertEqual(self.output.read_bytes(),b'# not configured\n\n')

    def test_failed_browser_launch_keeps_manual_url_usable(self):
        process=self.start(AM_EXIT='9'); parts=self.page(process)
        self.assertEqual(self.request(parts,b'https://example.com/sub'),(200,b'saved'))
        _,err=process.communicate(timeout=7)
        self.assertEqual(process.returncode,0,err)
        self.assertTrue(self.output.exists())

    def test_timeout_is_nonfatal_and_does_not_create_subscription(self):
        process=self.start(MAGICNET_SETUP_TIMEOUT='5'); self.page(process)
        out,err=process.communicate(timeout=9)
        self.assertEqual(process.returncode,0,err)
        self.assertIn(b'INSTALL_WEB_LATER',out)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.config.glob('.web-input.*')))

    def test_offline_validator(self):
        accepted=['https://example.com/sub?x=+&encoded=%2B&cmd=$(id)',
                  'https://example.com:8443/sub','https://8.8.8.8/sub',
                  'https://[2606:4700:4700::1111]/sub', 'https://example.com./sub']
        rejected=['http://example.com/sub','https://localhost/sub','https://127.0.0.1/sub',
                  'https://127.0.0.1./sub','https://192.168.0.1/sub','https://10.0.0.1/sub',
                  'https://172.16.0.1/sub','https://100.64.0.1/sub','https://example.local/sub',
                  'https://user:pass@example.com/sub','https://example.com/sub#fragment',
                  'https://example.com:0/sub','https://example.com:65536/sub',
                  'https://example.com/\nhttps://example.org/','https://[::1]/sub',
                  'https://[2001:db8::1]/sub','https://[2001:0db8::1]/sub',
                  'https://[2606:::1]/sub','https://[2606:1]/sub','https://example.com/a b',
                  'https://example.com\\@127.0.0.1/sub','https://'+('a'*64)+'.com/sub']
        payload=self.root/'payload'
        for value,expected in [(x,0) for x in accepted]+[(x,1) for x in rejected]:
            with self.subTest(value=value):
                payload.write_text(value)
                result=subprocess.run([BB,'ash',str(self.module/'lib/magicnet/install_subscription_validate.sh'),str(payload)],capture_output=True)
                self.assertEqual(result.returncode,expected,result.stderr)
                self.assertEqual(result.stdout,b'')

    def test_install_hook_after_migration_and_template_before_no_external_launch(self):
        source=(SOURCE/'customize.sh').read_text()
        call=source.rindex('magicnet_install_collect_subscription')
        self.assertLess(source.index('magicnet_install_config_template ||'),call)
        self.assertLess(source.rindex('magicnet_cleanup_install_backup ||'),call)
        self.assertNotIn('launch url "https://github.com/',source)
        self.assertIn('MAGICNET_PREV_DIR',source)

if __name__=='__main__':
    unittest.main(verbosity=2)
