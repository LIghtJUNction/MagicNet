#!/usr/bin/env python3
"""Offline curl proof regressions. Real host TLS exercises logic, NOT Android.

Every device operation is a strict local adapter; no SIM.Device is created.
The host curl has no pinned embedded CA, so only that identity query is mocked
for end-to-end controls. Its real verifier and loopback TLS are exercised.
"""
from __future__ import annotations

from contextlib import ExitStack
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlsplit

PATH = Path(__file__).with_name('android-public-curl-proof.py')
SPEC = importlib.util.spec_from_file_location('public_curl_proof', PATH)
PROOF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROOF)
REAL_RUN = subprocess.run
HOST_CURL = shutil.which('curl')
HOST_OPENSSL = shutil.which('openssl')


def cp(text='', rc=0, stderr=''):
    return subprocess.CompletedProcess(['local-fixture'], rc, text, stderr)


class LocalDevice:
    """Only fixed inspection, unique public CA staging and local reverse controls."""
    def __init__(self, root):
        self.verified = True
        self.root = root
        self.calls = []
        self.mapping = None
        self.mapping_target = None
        self.ca_remote = None
        self.ca_host = root / 'device-public-ca.pem'
        self.overrides = {}
        self.curl_mutator = None
        self.timeouts = []
        self.create_unknown = False
        self.create_failure = None
        self.cleanup_reverse_fail = False
        self.cleanup_ca_fail = False
        self.after_curl = None
        self.curled = 0

    def kshell(self, command, *, timeout, check):
        assert check is False
        assert 0 < timeout <= 9
        self.calls.append(('kshell', command))
        self.timeouts.append(timeout)
        if command in self.overrides:
            return self.overrides[command]
        if command == 'id -Z':
            return cp(PROOF.KSU_DOMAIN + '\n')
        selector = ('MODDIR=' + shlex.quote(PROOF.MOD) + '; . '
                    + shlex.quote(PROOF.MOD + '/lib/magicnet/primitives.sh') + '; magicnet_trusted_curl')
        if command == selector:
            return cp(PROOF.CURL + '\n')
        if command == 'mkdir -p ' + PROOF.REMOTE:
            return cp()
        if self.ca_remote and command == 'rm -f ' + self.ca_remote + ' && test ! -e ' + self.ca_remote:
            if self.cleanup_ca_fail:
                return cp(rc=1)
            self.ca_host.unlink(missing_ok=True)
            return cp()
        prefix = 'unset ' + ' '.join(PROOF.UNSET) + '; exec '
        if not command.startswith(prefix):
            raise AssertionError('unexpected device command')
        args = shlex.split(command[len(prefix):])
        if len(args) < 3 or args[:2] != [PROOF.CURL, '-q']:
            raise AssertionError('untrusted fixture executable')
        args = args[2:]
        if args not in (['--version'], ['--help', 'all']):
            self.curled += 1
            arity = {'--silent': 0, '--show-error': 0, '--fail': 0, '--proxy': 1, '--noproxy': 1,
                     '--connect-timeout': 1, '--max-time': 1, '--max-filesize': 1, '--proto': 1,
                     '--proto-redir': 1, '--compressed': 0, '--resolve': 1, '--cacert': 1, '--url': 1}
            options, index = {}, 0
            while index < len(args):
                token = args[index]
                if token not in arity or token in options or index + arity[token] >= len(args):
                    raise AssertionError('unknown, duplicate or incomplete curl option')
                options[token] = args[index + 1] if arity[token] else None
                index += 1 + arity[token]
            if set(options) - {'--cacert'} != set(arity) - {'--cacert'}:
                raise AssertionError('missing controlled curl option')
            parsed = urlsplit(options['--url'])
            if (parsed.scheme != 'https' or parsed.hostname not in (PROOF.HOSTNAME, PROOF.WRONG_HOSTNAME)
                    or parsed.path != '/proof' or parsed.query or parsed.username is not None
                    or parsed.port != self.mapping or parsed.fragment):
                raise AssertionError('external or unowned curl target')
            if options['--resolve'] != f'{parsed.hostname}:{self.mapping}:127.0.0.1':
                raise AssertionError('resolve must reach our loopback server')
            if options['--proxy'] != '' or options['--noproxy'] != '*':
                raise AssertionError('proxy not disabled')
            if options['--proto'] != '=https' or options['--proto-redir'] != '=https':
                raise AssertionError('unsafe protocol')
            if any(options[key] != value for key, value in
                   (('--connect-timeout', '3'), ('--max-time', '6'), ('--max-filesize', '4096'))):
                raise AssertionError('unbounded fixture request')
            if '--cacert' in args:
                index = args.index('--cacert') + 1
                if args[index] != self.ca_remote or not self.ca_host.is_file():
                    raise AssertionError('unowned CA path')
                args[index] = str(self.ca_host)
        if self.curl_mutator:
            snapshot = tuple(args)
            replacement = self.curl_mutator(list(snapshot))
            if isinstance(replacement, subprocess.CompletedProcess):
                return replacement
            if not isinstance(replacement, list) or tuple(replacement) != snapshot:
                raise AssertionError('fixture mutator cannot change host subprocess arguments')
            args = list(snapshot)
        environment = {key: value for key, value in os.environ.items() if key not in PROOF.UNSET}
        result = REAL_RUN([HOST_CURL, '-q', *args], capture_output=True, text=True,
                          timeout=timeout, env=environment)
        if self.after_curl:
            self.after_curl(args, result)
        return result

    def run(self, *args, timeout, check):
        assert check is False
        assert 0 < timeout <= 5
        self.calls.append(('run', args))
        self.timeouts.append(timeout)
        if args[0] == 'push' and len(args) == 3:
            source, remote = Path(args[1]), args[2]
            if not re.fullmatch(re.escape(PROOF.REMOTE) + r'/curl-proof-[a-f0-9]{32}\.pem', remote):
                raise AssertionError('unowned stage path')
            if not source.name == 'public-test-ca.pem' or source.suffix != '.pem':
                raise AssertionError('only the public certificate may be staged')
            data = source.read_bytes()
            if b'PRIVATE KEY' in data or not data.startswith(b'-----BEGIN CERTIFICATE-----'):
                raise AssertionError('private key or invalid CA staged')
            self.ca_remote = remote
            self.ca_host.write_bytes(data)
            return cp()
        if args == ('reverse', '--list'):
            return cp(f'fixture tcp:{self.mapping} tcp:{self.mapping_target}\n' if self.mapping else '')
        if len(args) == 4 and args[:2] == ('reverse', '--no-rebind'):
            if not args[2].startswith('tcp:') or args[2] != args[3] or self.mapping is not None:
                raise AssertionError('unexpected reverse mutation')
            port = int(args[2][4:])
            if not 1024 <= port <= 65535:
                raise AssertionError('invalid local port')
            self.mapping = port
            self.mapping_target = port
            if self.create_failure is not None:
                return self.create_failure
            return cp(rc=124 if self.create_unknown else 0)
        if len(args) == 3 and args[:2] == ('reverse', '--remove'):
            if args[2] != f'tcp:{self.mapping}':
                raise AssertionError('removing unowned reverse')
            if self.cleanup_reverse_fail:
                return cp(rc=1)
            self.mapping = None
            self.mapping_target = None
            return cp()
        raise AssertionError('unexpected device operation')


class CurlProofTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.device = LocalDevice(Path(self.temp.name))
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(PROOF, 'inspect_embedded_ca', return_value=None))
        # Guard proof's only host subprocess. Device curl is run through a
        # separate strict argv adapter; neither path can execute ADB.
        def host_run(args, **kwargs):
            if not isinstance(args, list) or args[:2] != [HOST_OPENSSL, 'req']:
                raise AssertionError('unexpected host subprocess')
            key = Path(args[args.index('-keyout') + 1])
            cert = Path(args[args.index('-out') + 1])
            self.assertEqual(key.parent, cert.parent)
            self.assertTrue(key.parent.name.startswith('magicnet-curl-proof-'))
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            return REAL_RUN(args, **kwargs)
        self.stack.enter_context(patch.object(PROOF.subprocess, 'run', side_effect=host_run))

    def require_host_tools(self):
        if not HOST_CURL or not HOST_OPENSSL:
            self.skipTest('host-only TLS logic needs host curl and openssl')

    def assert_clean(self):
        self.assertIsNone(self.device.mapping)
        self.assertFalse(self.device.ca_host.exists())
        self.assertTrue(all(0 < value <= 9 for value in self.device.timeouts))

    def test_real_host_tls_three_controls_and_deterministic_private_report(self):
        self.require_host_tools()
        with patch.dict(os.environ, {'https_proxy': 'http://127.0.0.1:1', 'CURL_CA_BUNDLE': '/missing/ca.pem',
                                    'SSL_CERT_FILE': '/missing/file', 'SSL_CERT_DIR': '/missing/dir'}):
            before = dict(os.environ)
            result = PROOF.verify(self.device)
            self.assertEqual(dict(os.environ), before, 'host environment must remain untouched')
        self.assertEqual(result, {'schema': 1, 'status': 'verified', 'https': True, 'ssl': True,
                                'resolve': True, 'gzip': True, 'tls_positive': True,
                                'hostname_reject': True, 'default_trust_reject': True, 'cleanup': True,
                                'embedded_ca_identity': True, 'embedded_ca_bytes': 188900,
                                'positive_gets': 1, 'hostname_reject_gets': 0, 'default_reject_gets': 0})
        self.assertEqual(self.device.curled, 3)
        self.assert_clean()

    def test_unverified_device_makes_no_calls_or_host_subprocesses(self):
        self.device.verified = False
        with self.assertRaisesRegex(RuntimeError, '^curl_device_unverified$'):
            PROOF.verify(self.device)
        self.assertEqual(self.device.calls, [])

    def test_unknown_domain_or_wrong_selector_cannot_stage_anything(self):
        selector = ('MODDIR=' + shlex.quote(PROOF.MOD) + '; . '
                    + shlex.quote(PROOF.MOD + '/lib/magicnet/primitives.sh') + '; magicnet_trusted_curl')
        for command, response in (('id -Z', cp('u:r:shell:s0\n')), (selector, cp('/system/bin/curl\n')),
                                  ('id -Z', cp(PROOF.KSU_DOMAIN + '\n', rc=1))):
            with self.subTest(command=command):
                self.device.overrides = {command: response}
                with self.assertRaises(RuntimeError):
                    PROOF.verify(self.device)
                self.assertFalse(any(channel == 'run' for channel, _ in self.device.calls))
                self.device.calls.clear()

    def test_missing_tls_or_options_is_not_a_capability_pass(self):
        for command, text in (
            (PROOF.clean_command(['--version']), 'curl 8.22.0\nProtocols: http\nFeatures: libz\n'),
            (PROOF.clean_command(['--version']), 'curl 8.22.0\nProtocols: https\nFeatures: SSL\n'),
            (PROOF.clean_command(['--help', 'all']), '--resolve --compressed --proto --proto-redir\n'),
        ):
            with self.subTest(command=command):
                self.device.overrides = {command: cp(text)}
                with self.assertRaises(RuntimeError):
                    PROOF.verify(self.device)
                self.assertFalse(any(channel == 'run' for channel, _ in self.device.calls))
                self.device.calls.clear()

    def test_negative_ca_file_error_77_cannot_masquerade_as_trust_rejection(self):
        self.require_host_tools()
        def mutate(args):
            if '--url' in args and '--cacert' not in args:
                return cp(rc=77, stderr='raw diagnostic must never be reported')
            return args
        self.device.curl_mutator = mutate
        with self.assertRaisesRegex(RuntimeError, '^curl_default_trust_reject_failed$'):
            PROOF.verify(self.device)
        self.assert_clean()

    def test_negative_partial_body_with_60_is_not_rejection(self):
        self.require_host_tools()
        def mutate(args):
            if '--url' in args and PROOF.WRONG_HOSTNAME in args[args.index('--url') + 1]:
                return cp('partial-body', 60)
            return args
        self.device.curl_mutator = mutate
        with self.assertRaisesRegex(RuntimeError, '^curl_hostname_reject_failed$'):
            PROOF.verify(self.device)
        self.assert_clean()

    def test_fake_positive_body_without_server_get_is_rejected(self):
        self.require_host_tools()
        def mutate(args):
            return cp('invented-success', 0) if '--url' in args else args
        self.device.curl_mutator = mutate
        with self.assertRaisesRegex(RuntimeError, '^curl_tls_positive_failed$'):
            PROOF.verify(self.device)
        self.assert_clean()

    def test_cleanup_failure_prevents_pass(self):
        self.require_host_tools()
        for flag in ('cleanup_reverse_fail', 'cleanup_ca_fail'):
            with self.subTest(flag=flag):
                self.device = LocalDevice(Path(self.temp.name))
                setattr(self.device, flag, True)
                with self.assertRaisesRegex(RuntimeError, '^curl_cleanup_failed$'):
                    PROOF.verify(self.device)
                self.assertEqual(self.device.curled, 3)
                self.device.ca_host.unlink(missing_ok=True)

    def test_unknown_reverse_creation_is_reconciled_and_cleaned(self):
        self.require_host_tools()
        self.device.create_unknown = True
        with self.assertRaisesRegex(RuntimeError, '^curl_reverse_failed$'):
            PROOF.verify(self.device)
        self.assertEqual(self.device.curled, 0)
        self.assert_clean()

    def test_exit_one_after_creation_is_reconciled_and_cleaned(self):
        self.require_host_tools()
        for diagnostic in ('error: closed', 'unexpected EOF', '',
                           'cannot rebind existing socket\nerror: closed'):
            with self.subTest(diagnostic=diagnostic):
                self.device = LocalDevice(Path(self.temp.name))
                self.device.create_failure = cp(rc=1, stderr=diagnostic)
                with self.assertRaisesRegex(RuntimeError, '^curl_reverse_failed$'):
                    PROOF.verify(self.device)
                self.assertEqual(self.device.curled, 0)
                self.assertTrue(any(channel == 'run' and args[:2] == ('reverse', '--remove')
                                    for channel, args in self.device.calls))
                self.assert_clean()

    def test_only_isolated_no_rebind_diagnostic_proves_creation_refusal(self):
        for value in (cp(rc=1, stderr='cannot rebind existing socket'),
                      cp(rc=1, stderr='adb: error: cannot rebind existing socket\n'),
                      cp('error: cannot rebind existing socket\n', rc=1)):
            with self.subTest(stdout=value.stdout, stderr=value.stderr):
                self.assertTrue(PROOF.no_rebind_rejected(value))
        for value in (cp(rc=1, stderr='error: closed'), cp(rc=1, stderr='unexpected EOF'),
                      cp(rc=1, stderr='cannot rebind existing socket\nerror: closed'),
                      cp('transport closed', rc=1, stderr='cannot rebind existing socket'),
                      cp(rc=124, stderr='cannot rebind existing socket')):
            with self.subTest(stdout=value.stdout, stderr=value.stderr):
                self.assertFalse(PROOF.no_rebind_rejected(value))

    def test_thread_start_failure_is_bounded_and_never_claims_cleanup_success(self):
        self.require_host_tools()
        with patch.object(PROOF.threading.Thread, 'start', side_effect=RuntimeError('raw startup error')):
            with self.assertRaisesRegex(RuntimeError, '^curl_proof_unknown$'):
                PROOF.verify(self.device)
        self.assertFalse(any(channel == 'run' for channel, _ in self.device.calls))

    def test_partially_started_thread_is_observed_and_stopped_after_interruption(self):
        self.require_host_tools()
        original_start = PROOF.threading.Thread.start
        spawned = []
        def start(thread):
            spawned.append(thread)
            original_start(thread)
            if len(spawned) == 1:
                raise KeyboardInterrupt
        with patch.object(PROOF.threading.Thread, 'start', side_effect=start, autospec=True):
            with self.assertRaisesRegex(RuntimeError, '^curl_proof_unknown$'):
                PROOF.verify(self.device)
        self.assertGreaterEqual(len(spawned), 2)
        self.assertTrue(all(not thread.is_alive() for thread in spawned))
        self.assertFalse(any(channel == 'run' for channel, _ in self.device.calls))

    def test_retargeted_reverse_is_not_deleted_and_cannot_pass(self):
        self.require_host_tools()
        def retarget(_args, _result):
            if self.device.curled == 3:
                self.device.mapping_target = self.device.mapping - 1
        self.device.after_curl = retarget
        with self.assertRaisesRegex(RuntimeError, '^curl_cleanup_failed$'):
            PROOF.verify(self.device)
        self.assertFalse(any(channel == 'run' and args[:2] == ('reverse', '--remove')
                             for channel, args in self.device.calls))
        self.assertIsNotNone(self.device.mapping)
        self.assertFalse(self.device.ca_host.exists())

    def test_existing_mapping_is_not_rebound_or_deleted(self):
        self.require_host_tools()
        original_server = PROOF.LocalServer
        def server(context, body):
            instance = original_server(context, body)
            self.device.mapping = instance.server_address[1]
            self.device.mapping_target = self.device.mapping - 1
            return instance
        with patch.object(PROOF, 'LocalServer', side_effect=server):
            with self.assertRaisesRegex(RuntimeError, '^curl_reverse_collision$'):
                PROOF.verify(self.device)
        self.assertEqual(self.device.curled, 0)
        self.assertFalse(any(channel == 'run' and args[:2] in (('reverse', '--no-rebind'), ('reverse', '--remove'))
                             for channel, args in self.device.calls))
        self.assertFalse(self.device.ca_host.exists())

    def test_explicit_creation_rejection_does_not_delete_a_concurrent_mapping(self):
        self.require_host_tools()
        original_run = self.device.run
        def run(*args, **kwargs):
            if args[:2] == ('reverse', '--no-rebind'):
                self.device.mapping = int(args[2][4:])
                self.device.mapping_target = self.device.mapping
                self.device.calls.append(('run', args))
                return cp(rc=1, stderr='cannot rebind existing socket')
            return original_run(*args, **kwargs)
        self.device.run = run
        with self.assertRaisesRegex(RuntimeError, '^curl_reverse_failed$'):
            PROOF.verify(self.device)
        self.assertFalse(any(channel == 'run' and args[:2] == ('reverse', '--remove')
                             for channel, args in self.device.calls))
        self.assertFalse(self.device.ca_host.exists())

    def test_deadline_is_shared_and_reserves_cleanup_before_any_operation(self):
        with patch.object(PROOF.time, 'monotonic', side_effect=[0, 61, 61]):
            with self.assertRaisesRegex(RuntimeError, '^curl_deadline$'):
                PROOF.verify(self.device)
        self.assertEqual(self.device.calls, [])

    def test_expired_operation_budget_still_leaves_time_to_clean_owned_resources(self):
        self.require_host_tools()
        clock = [0]
        def after_positive(_args, _result):
            if self.device.curled == 1:
                clock[0] = 53  # Ordinary admission ended; seven cleanup seconds remain.
        self.device.after_curl = after_positive
        with patch.object(PROOF.time, 'monotonic', side_effect=lambda: clock[0]):
            with self.assertRaisesRegex(RuntimeError, '^curl_deadline$'):
                PROOF.verify(self.device)
        self.assertEqual(self.device.curled, 1, 'no negative request may start after ordinary admission ends')
        self.assert_clean()

    def test_adapter_unknown_writes_and_external_targets_are_refused(self):
        with self.assertRaises(AssertionError):
            self.device.run('shell', 'rm -rf /', timeout=1, check=False)
        with self.assertRaises(AssertionError):
            self.device.kshell('service.sh', timeout=1, check=False)
        with self.assertRaises(AssertionError):
            self.device.kshell(PROOF.clean_command(['--url', 'https://example.com/']), timeout=1, check=False)

    def test_adapter_rejects_extra_urls_short_options_and_positional_arguments(self):
        self.device.mapping = self.device.mapping_target = 12345
        args = ['--silent', '--show-error', '--fail', '--proxy', '', '--noproxy', '*',
                '--connect-timeout', '3', '--max-time', '6', '--max-filesize', '4096',
                '--proto', '=https', '--proto-redir', '=https', '--compressed',
                '--resolve', PROOF.HOSTNAME + ':12345:127.0.0.1',
                '--url', 'https://' + PROOF.HOSTNAME + ':12345/proof']
        for extra in (['--url', 'https://external.invalid/'], ['-o', '/tmp/unexpected-write'],
                      ['-K', '/tmp/unknown-config'], ['https://external.invalid/'], ['--insecure']):
            with self.subTest(extra=extra), patch.dict(globals(), {'REAL_RUN': Mock()}) as _:
                executor = REAL_RUN
                with self.assertRaises(AssertionError):
                    self.device.kshell(PROOF.clean_command(args + extra), timeout=1, check=False)
                executor.assert_not_called()
        def mutate_in_place(values):
            values.extend(['--url', 'https://external.invalid/'])
            return values
        self.device.curl_mutator = mutate_in_place
        with patch.dict(globals(), {'REAL_RUN': Mock()}):
            executor = REAL_RUN
            with self.assertRaises(AssertionError):
                self.device.kshell(PROOF.clean_command(args), timeout=1, check=False)
            executor.assert_not_called()


class EmbeddedCaTests(unittest.TestCase):
    def test_unknown_wrong_or_oversized_dump_is_rejected(self):
        for value in (cp('', 1), cp(''), cp('x' * PROOF.EMBEDDED_CA_SIZE), cp('x' * (1024 * 1024 + 1))):
            with self.subTest(length=len(value.stdout), rc=value.returncode):
                device = Mock()
                device.kshell.return_value = value
                with self.assertRaises(RuntimeError):
                    PROOF.inspect_embedded_ca(device, PROOF.Budget())

    def test_explicit_local_pinned_fixture_when_supplied(self):
        path = os.environ.get('MAGICNET_TEST_PUBLIC_CURL_CA')
        if not path:
            self.skipTest('optional local public CA fixture not supplied; never download in this suite')
        data = Path(path).read_bytes()
        self.assertEqual(len(data), PROOF.EMBEDDED_CA_SIZE)
        self.assertEqual(hashlib.sha256(data).hexdigest(), PROOF.EMBEDDED_CA_SHA256)
        device = Mock()
        device.kshell.return_value = cp(data.decode('utf-8'))
        PROOF.inspect_embedded_ca(device, PROOF.Budget())


if __name__ == '__main__':
    unittest.main()
