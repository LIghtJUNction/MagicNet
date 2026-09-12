#!/usr/bin/env python3
"""Exercise the production kamfw browser adapter with recorded Android commands.

The original HTTP/CGI suite continues to exercise the old-launcher fallback.
These tests cover the bundled extension, numeric foreground user, browser-role
resolution, failure propagation, and the single production installer entry.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'src/MagicNet'
HELPER = MODULE / 'lib/magicnet/install_onboarding.sh'
BUSYBOX = shutil.which('busybox')
RECORDER = r'''#!/bin/sh
printf '%s\n' '---' "$@" >>"$TEST_CALLS"
case "$3 $4" in
    '/system/bin/am get-current-user') printf '%s\n' "${TEST_USER:-10}" ;;
    '/system/bin/cmd role')
        [ "${TEST_ROLE_FAIL:-0}" = 0 ] || exit 9
        printf '%s' "${TEST_ROLE-}" ;;
    '/system/bin/cmd activity') exit "${TEST_CMD_RC:-7}" ;;
    '/system/bin/am start')
        if [ "${TEST_ERROR_OUTPUT:-0}" = 1 ]; then echo 'Error: Activity not started'; exit 0; fi
        [ "${TEST_ALL_FAIL:-0}" = 0 ] || exit 7
        for arg in "$@"; do
            if [ "$arg" = -p ] && [ "${TEST_BOUND_FAIL:-0}" = 1 ]; then exit 8; fi
        done ;;
    *) exit 99 ;;
esac
'''

@unittest.skipUnless(BUSYBOX, 'BusyBox required')
class BrowserTests(unittest.TestCase):
    def launch(self, **overrides):
        with tempfile.TemporaryDirectory(prefix='magicnet-browser-') as tmp:
            module = Path(tmp)
            (module / 'lib/kamfw-web').mkdir(parents=True)
            shutil.copy(MODULE / 'lib/kamfw-web/launcher.sh', module / 'lib/kamfw-web/launcher.sh')
            binaries = module / 'bin'
            binaries.mkdir()
            for name in ('am', 'cmd'):
                fake = binaries / name
                fake.write_text('#!/bin/sh\nexit 99\n')
                fake.chmod(0o700)
            recorder = module / 'record-busybox'
            recorder.write_text(RECORDER)
            recorder.chmod(0o700)
            calls = module / 'calls'
            env = dict(os.environ, MODPATH=tmp, MN_SETUP_RUN=tmp,
                       MN_SETUP_BB=str(recorder), TEST_CALLS=str(calls),
                       KAMFW_TEST_DIR=str(MODULE / 'lib/kamfw'),
                       PATH=str(binaries) + ':' + os.environ.get('PATH', ''))
            env.update(overrides)
            script = '. "$1"; import() { . "$KAMFW_TEST_DIR/$1.sh"; }; magicnet_onboarding_open "$2"'
            result = subprocess.run([BUSYBOX, 'ash', '-c', script, 'test', str(HELPER),
                                     'http://127.0.0.1:33333/?lang=zh#fixture'], env=env,
                                    capture_output=True, text=True, timeout=10)
            recorded = [entry.strip().splitlines() for entry in calls.read_text().split('---\n') if entry.strip()]
            for call in recorded:
                self.assertEqual(call[:2], ['timeout', '5'])
                self.assertIn(call[2], ['/system/bin/am', '/system/bin/cmd'])
            return result.returncode, recorded

    def test_numeric_current_user_and_default_browser(self):
        rc, calls = self.launch(TEST_ROLE='org.example.browser')
        self.assertEqual(rc, 0)
        self.assertEqual(calls[0][2:], ['/system/bin/am', 'get-current-user'])
        self.assertEqual(calls[1][2:], ['/system/bin/cmd', 'role', 'get-role-holders', '--user', '10', 'android.app.role.BROWSER'])
        self.assertEqual(calls[2][2:12], ['/system/bin/am', 'start', '--user', 'current', '-a', 'android.intent.action.VIEW', '-f', '0x10000000', '-c', 'android.intent.category.BROWSABLE'])
        self.assertEqual(calls[2][12:14], ['-p', 'org.example.browser'])

    def test_no_browser_role_uses_action_view(self):
        rc, calls = self.launch(TEST_ROLE='')
        self.assertEqual(rc, 0)
        self.assertNotIn('-p', calls[-1])
        self.assertIn('android.intent.category.BROWSABLE', calls[-1])

    def test_old_android_role_service_failure_falls_back(self):
        rc, calls = self.launch(TEST_ROLE_FAIL='1')
        self.assertEqual(rc, 0)
        self.assertNotIn('-p', calls[-1])

    def test_invalid_role_output_is_not_a_package_or_command(self):
        rc, calls = self.launch(TEST_ROLE='org.example.browser;unexpected')
        self.assertEqual(rc, 0)
        self.assertNotIn('-p', calls[-1])

    def test_bound_browser_failure_tries_generic_view(self):
        rc, calls = self.launch(TEST_ROLE='org.example.browser', TEST_BOUND_FAIL='1')
        self.assertEqual(rc, 0)
        self.assertIn('-p', calls[-2])
        self.assertNotIn('-p', calls[-1])

    def test_launch_failure_is_not_reported_as_success(self):
        rc, _ = self.launch(TEST_ALL_FAIL='1')
        self.assertEqual(rc, 7)

    def test_direct_activity_fallback(self):
        rc, calls = self.launch(TEST_ALL_FAIL='1', TEST_CMD_RC='0')
        self.assertEqual(rc, 0)
        self.assertEqual(calls[-1][2:5], ['/system/bin/cmd', 'activity', 'start-activity'])

    def test_zero_exit_with_error_uses_fallback(self):
        rc, calls = self.launch(TEST_ERROR_OUTPUT='1', TEST_CMD_RC='0')
        self.assertEqual(rc, 0)
        self.assertEqual(calls[-1][3], 'activity')

    def test_invalid_user_does_not_reach_role_service(self):
        rc, calls = self.launch(TEST_USER='not-a-user')
        self.assertEqual(rc, 0)
        self.assertEqual(len(calls), 2)
        self.assertNotIn('-p', calls[-1])

    def test_only_one_installer_entry_is_registered(self):
        source = (MODULE / 'customize.sh').read_text()
        self.assertEqual(source.count('magicnet_install_onboarding ||'), 1)
        self.assertNotIn('magicnet_install_setup', source)
        self.assertNotIn('magicnet_install_web', source)
        self.assertGreater(source.index('magicnet_install_onboarding ||'), source.index('magicnet_cleanup_install_backup ||'))
        self.assertFalse((MODULE / 'lib/magicnet/install_setup.sh').exists())
        self.assertFalse((MODULE / 'lib/magicnet/install_web.sh').exists())
        self.assertFalse((MODULE / 'lib/kamfw-overlay').exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
