"""Process-level contract tests against the compiled CLI, not mocked output."""
import base64
import json
from pathlib import Path
import secrets
import subprocess
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[1]
BINARY = BASE / 'target/debug/magicnet-cli'


class CliContract(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='magicnet-cli-test-')
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def run_cli(self, *args, stdin=b''):
        result = subprocess.run([str(BINARY), '--root', str(self.root), *args], input=stdin, capture_output=True, timeout=5)
        self.assertEqual(result.stderr, b'')
        value = json.loads(result.stdout)
        self.assertEqual(value['schema'], 1)
        self.assertEqual(result.returncode == 0, value['ok'])
        return value

    def initialize(self):
        self.assertTrue(self.run_cli('--initialize-candidate')['ok'])

    def request(self, method, params=None, revision=0):
        return {'schema': 1, 'id': secrets.token_hex(16), 'method': method, 'expected_revision': revision, 'params': params}

    def rpc(self, request):
        return self.run_cli('--request-stdin', stdin=json.dumps(request).encode())

    def test_read_only_queries_create_no_files(self):
        for method in ('status','settings','capabilities','operation','diagnostics'):
            self.assertTrue(self.run_cli(method, '--json')['ok'])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_writes_require_isolated_marker(self):
        reply = self.rpc(self.request('sources.replace', {'text': ''}))
        self.assertEqual(reply['error']['code'], 'migration_required')
        self.assertEqual(list(self.root.iterdir()), [])

    def test_initialize_refuses_existing_module_data(self):
        (self.root / 'module.prop').write_text('id=MagicNet\n')
        self.assertEqual(self.run_cli('--initialize-candidate')['error']['code'], 'root_not_empty')
        self.assertEqual((self.root / 'module.prop').read_text(), 'id=MagicNet\n')

    def test_unknown_json_command_has_no_mutating_fallback(self):
        self.initialize()
        self.assertEqual(self.rpc(self.request('service.start.now'))['error']['code'], 'unsupported_command')
        self.assertFalse((self.root / '.state').exists())

    def test_base64_transports_unicode_and_shell_metacharacters(self):
        self.initialize()
        body = json.dumps({'proxies': [{'type': 'trojan', 'name': '日本😀', 'server': 'example.test', 'port': 443, 'password': '$(touch /tmp/no);"\\'}]})
        request = self.request('sources.import', {'body': body})
        encoded = base64.b64encode(json.dumps(request).encode())
        reply = self.run_cli('--request-base64-stdin', stdin=encoded)
        self.assertTrue(reply['ok'])
        nodes = json.loads((self.root / '.config/nodes/local.json').read_text())
        self.assertEqual(nodes[0]['password'], '$(touch /tmp/no);"\\')

    def test_default_native_activation_is_gated(self):
        self.initialize()
        self.assertEqual(self.rpc(self.request('service.start'))['error']['code'], 'acceptance_required')
        self.assertFalse(self.run_cli('status')['data']['configured'])
        self.assertFalse((self.root / '.state/runtime.json').exists())

    def test_malformed_transport_is_structured_and_bounded(self):
        self.assertEqual(self.run_cli('--request-base64-stdin', stdin=b'not@base64')['error']['code'], 'invalid_request')
        self.assertEqual(self.run_cli('--request-stdin', stdin=b'x' * (8*1024*1024+1))['error']['code'], 'too_large')
        self.assertEqual(list(self.root.iterdir()), [])

    def test_gate_does_not_report_production_ready(self):
        result = subprocess.run(['python3', str(BASE / 'tools/verify_scope.py')], capture_output=True, text=True, check=True)
        self.assertFalse(json.loads(result.stdout)['production_ready'])
        result = subprocess.run(['python3', str(BASE / 'tools/verify_scope.py'), '--require-cutover'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('blocked', result.stderr)


if __name__ == '__main__':
    unittest.main()
