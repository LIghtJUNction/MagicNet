#!/usr/bin/env python3
"""Execute backend/registration tri-state handling without touching any host table."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / 'src/MagicNet/lib/magicnet/network.sh'
SHELLS = [['sh'], ['bash']]
if shutil.which('busybox'):
    SHELLS.append(['busybox', 'ash'])


class RegistrationTests(unittest.TestCase):
    def run_shell(self, shell, body, **env):
        return subprocess.run(shell + ['-c', '. "$NETWORK"\n' + body],
                              env=dict(os.environ, NETWORK=str(NETWORK), **env),
                              text=True, capture_output=True, timeout=5)

    def test_registry_missing_empty_unregistered_and_registered_are_distinct(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'registry'
            for shell in SHELLS:
                for text, expected in ((None, 2), ('', 2), ('filter\n', 2), ('notnat\n', 2),
                                       ('filter\nnat\n', 0)):
                    path.unlink(missing_ok=True)
                    if text is not None:
                        path.write_text(text)
                    with self.subTest(shell=shell, text=text):
                        cp = self.run_shell(shell, 'magicnet_legacy_table_registered "$REGISTRY" nat',
                                            REGISTRY=str(path))
                        self.assertEqual(cp.returncode, expected, cp.stderr)

    def test_incomplete_or_failed_observation_is_never_absence(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'registry'
            for shell in SHELLS:
                for content in ('x' * 4097, '\n' * 4097, 'nat\n' + 'x' * 4096):
                    path.write_text(content)
                    cp = self.run_shell(shell, 'magicnet_legacy_table_registered "$REGISTRY" nat',
                                        REGISTRY=str(path))
                    self.assertEqual(cp.returncode, 1)
                path.write_text('nat\n')
                cp = self.run_shell(shell, 'head() { return 13; }; magicnet_legacy_table_registered "$REGISTRY" nat',
                                    REGISTRY=str(path))
                self.assertEqual(cp.returncode, 1)
                for invalid in (Path(td), Path(td) / 'missing-parent' / 'registry'):
                    cp = self.run_shell(shell, 'magicnet_legacy_table_registered "$REGISTRY" nat',
                                        REGISTRY=str(invalid))
                    self.assertEqual(cp.returncode, 1)
                link = Path(td) / 'link'
                if not link.is_symlink():
                    link.symlink_to(Path(td) / 'missing')
                cp = self.run_shell(shell, 'magicnet_legacy_table_registered "$REGISTRY" nat', REGISTRY=str(link))
                self.assertEqual(cp.returncode, 1)

    def probe(self, shell, backend='legacy', registry_rc=0, table_rc=0, error=''):
        with tempfile.TemporaryDirectory() as td:
            calls = Path(td) / 'calls'
            calls.touch()
            cp = self.run_shell(shell, r'''
magicnet_cmd_exists() { return 0; }
magicnet_xtables_function_defined() { return 1; }
magicnet_legacy_table_registered() {
    [ "$1" = /proc/net/ip6_tables_names ] && [ "$2" = nat ] || return 99
    return "$REGISTRY_RC"
}
magicnet_warn() { printf '%s\n' "$*" >&2; }
magicnet_ip6tables_cmd() {
    printf '%s\n' "$*" >> "$CALLS"
    if [ "$1" = --version ]; then printf 'ip6tables v1.8.11 (%s)\n' "$BACKEND"; return 0; fi
    printf '%s\n' "$TABLE_ERROR" >&2
    return "$TABLE_RC"
}
magicnet_xtables_table_probe ip6tables nat
''', CALLS=str(calls), BACKEND=backend, REGISTRY_RC=str(registry_rc),
                                  TABLE_RC=str(table_rc), TABLE_ERROR=error)
            return cp, calls.read_text().splitlines()

    def test_absent_legacy_table_is_not_queried_or_loaded(self):
        for shell in SHELLS:
            for _ in range(2):
                cp, calls = self.probe(shell, registry_rc=2)
                self.assertEqual(cp.returncode, 2, cp.stderr)
                self.assertEqual(calls, ['--version'])
                self.assertEqual(cp.stderr, '')

    def test_failed_registration_does_not_query_or_claim_table_absent(self):
        for shell in SHELLS:
            cp, calls = self.probe(shell, registry_rc=1)
            self.assertEqual(cp.returncode, 1)
            self.assertEqual(calls, ['--version'])
            self.assertIn('registration unavailable', cp.stderr)

    def test_registered_legacy_and_nft_backends_are_actually_checked(self):
        for shell in SHELLS:
            for backend, rc in (('legacy', 0), ('nf_tables', 2)):
                cp, calls = self.probe(shell, backend=backend, registry_rc=rc)
                self.assertEqual(cp.returncode, 0, cp.stderr)
                self.assertEqual(calls, ['--version', '-t nat -L -n'])

    def test_permission_and_deadline_failures_are_not_downgraded(self):
        for shell in SHELLS:
            for rc, error, expected in ((3, 'Table does not exist', 2),
                                        (4, 'Permission denied', 1),
                                        (124, 'Table does not exist', 1)):
                cp, _ = self.probe(shell, table_rc=rc, error=error)
                self.assertEqual(cp.returncode, expected, cp.stderr)


if __name__ == '__main__':
    unittest.main()
