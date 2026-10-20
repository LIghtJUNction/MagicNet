#!/usr/bin/env python3
"""Exercise the shipped menu and KAM selector with terminal/volume input."""
import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELLS = [['sh'], ['bash']]
if busybox := shutil.which('busybox'):
    SHELLS.append([busybox, 'ash'])

SCRIPT = r'''
set -eu
set_i18n() { :; }
i18n() { printf '%s\n' "$1"; }
. "$ROOT/src/MagicNet/lib/kamfw/rich_rendering/interactive_prompts.sh"
. "$ROOT/src/MagicNet/lib/magicnet/action_menu.sh"
print() { printf '%s\n' "$*"; }
newline() { :; }
guide() { :; }
__rich_cyan() { printf '%s' "$*"; }
__rich_green() { printf '%s' "$*"; }
panel() { print "$*"; }
panel_row() { print "$*"; }
panel_error() { print "$*"; }
panel_warn() { print "$*"; }
panel_note() { print "$*"; }
magicnet_show_dashboard() { print dashboard; }
magicnet_cmd_exists() { return 0; }
magicnet_refresh_status() { return "${REFRESH_STATUS:-0}"; }
magicnet_action_diagnose() { print diagnose; }
magicnet_action_network_acceptance() { print acceptance; }
wait_key_up_down() {
    IFS= read -r key < "$KEY_FILE" || exit 88
    sed '1d' "$KEY_FILE" > "$KEY_FILE.next"
    mv "$KEY_FILE.next" "$KEY_FILE"
    printf '%s\n' "$key"
}
magicnet_action
'''

class ActionMenu(unittest.TestCase):
    def run_menu(self, *, text=None, keys='', status=0, refresh=0,
                 noninteractive=False, keytool=True, cli=True):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            module = root / 'module'
            module.mkdir()
            log = root / 'calls'
            binary = module / 'cli'
            if cli:
                binary.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\nexit "$CLI_STATUS"\n')
                binary.chmod(0o755)
            tools = root / 'tools'
            tools.mkdir()
            if keytool:
                (tools / 'getevent').write_text('#!/bin/sh\nexit 0\n')
                (tools / 'getevent').chmod(0o755)
            keyfile = root / 'keys'
            keyfile.write_text(keys)
            results = []
            for shell in SHELLS:
                keyfile.write_text(keys)
                if log.exists():
                    log.unlink()
                env = {**os.environ, 'ROOT': str(ROOT), 'MODDIR': str(module),
                       'CALLS': str(log), 'CLI_STATUS': str(status),
                       'REFRESH_STATUS': str(refresh), 'KEY_FILE': str(keyfile),
                       'MAGICNET_NONINTERACTIVE': '1' if noninteractive else '0',
                       'PATH': str(tools) + ':/usr/bin:/bin',
                       'COL_CYN': '', 'COL_RST': ''}
                master = slave = None
                try:
                    if text is not None:
                        master, slave = pty.openpty()
                        os.write(master, text.encode())
                    result = subprocess.run(shell + ['-c', SCRIPT], env=env,
                                            stdin=slave if slave is not None else subprocess.DEVNULL,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                finally:
                    if master is not None:
                        os.close(master)
                        os.close(slave)
                results.append((result, log.read_text() if log.exists() else ''))
            return results

    def test_terminal_empty_and_invalid_input_never_write(self):
        for text in ('\n', 'invalid\n0\n'):
            for result, calls in self.run_menu(text=text):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, '')

    def test_terminal_start_preserves_failure_despite_refresh_failure(self):
        for result, calls in self.run_menu(text='2\n', status=7, refresh=9):
            self.assertEqual(calls, 'service start sing-box\n')
            self.assertEqual(result.returncode, 7, result.stderr)

    def test_terminal_stop_and_update_cancel_by_default(self):
        for text in ('3\n\n', '4\nno\n'):
            for result, calls in self.run_menu(text=text):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, '')

    def test_terminal_confirmation_dispatches_explicit_action(self):
        for text, expected in (('3\ny\n', 'service stop sing-box\n'),
                               ('4\nY\n', 'sub update sing-box\n')):
            for result, calls in self.run_menu(text=text, status=7, refresh=9):
                self.assertEqual(calls, expected)
                self.assertEqual(result.returncode, 7, result.stderr)

    def test_volume_default_is_diagnostic(self):
        for result, calls in self.run_menu(keys='up\n'):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b'diagnose', result.stdout)
            self.assertEqual(calls, '')

    def test_volume_cancel_then_confirm_stop(self):
        for suffix, expected in (('up\n', ''), ('down\nup\n', 'service stop sing-box\n')):
            for result, calls in self.run_menu(keys='down\ndown\nup\n' + suffix):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, expected)

    def test_noninteractive_does_not_read_keys_or_write(self):
        for result, calls in self.run_menu(noninteractive=True, keytool=False):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, '')

    def test_missing_input_and_cli_fail_cleanly(self):
        for kwargs in ({'keytool': False}, {'text': '2\n', 'cli': False}):
            for result, calls in self.run_menu(**kwargs):
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(calls, '')

if __name__ == '__main__':
    unittest.main(verbosity=2)
