#!/usr/bin/env python3
"""Subscription conversion contracts; --converter executes the packaged revision.

Fixtures use reserved .invalid hosts and fake credentials. No provider is contacted.
The optional converter binary is built by the network evidence workflow, not mocked.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--converter', type=Path)
args, remaining = parser.parse_known_args()
CONVERTER = args.converter.resolve() if args.converter else None
if CONVERTER and not os.access(CONVERTER, os.X_OK):
    parser.error('converter must be an executable file')

NESTED = '''defaults: &defaults
  type: trojan
  port: 443
  password: fixture-password
proxies: # exported by a provider
  - <<: *defaults
    name: nested-tls
    server: tls.example.invalid
    sni: example.invalid
    alpn:
      - h2
      - http/1.1
  - name: websocket
    type: vmess
    server: ws.example.invalid
    port: 443
    uuid: 00000000-0000-4000-8000-000000000111
    alterId: 0
    cipher: auto
    tls: true
    network: ws
    ws-opts:
      path: /tunnel
      headers:
        Host: ws.example.invalid
proxy-groups:
  - name: not-a-node
    type: select
    proxies:
      - nested-tls
      - websocket
'''
FLOW = 'proxies: [{name: flow, type: trojan, server: flow.example.invalid, port: 443, password: fixture}]\n'
LINK = 'trojan://fixture-password@link.example.invalid:443#sharing\n'


class SubscriptionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='magicnet-clash-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # Release checks run after Android tools have populated the source bin
        # directory. Keep host conversion checks on host jq and real libraries.
        module = self.root / 'module'
        module.mkdir()
        (module / 'lib').symlink_to(ROOT / 'src/MagicNet/lib', target_is_directory=True)
        shutil.copytree(ROOT / 'src/MagicNet/.config', module / '.config')
        self.prefix = f'''set -eu
MODDIR={shlex.quote(str(module))}
. "$MODDIR/lib/magicnet_singbox_subscribe.sh"
magicnet_singbox_subscription_filter_file() {{ printf '/dev/null\\n'; }}
'''

    def file(self, name, text):
        path = self.root / name
        path.write_text(text)
        return path

    def shell(self, code, success=True):
        cp = subprocess.run(['bash', '-c', self.prefix + code], text=True, capture_output=True, timeout=45)
        if success:
            self.assertEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        else:
            self.assertNotEqual(cp.returncode, 0)
        return cp

    def test_nested_lists_anchors_comments_and_bom_are_two_nodes(self):
        for name, text in [('plain', NESTED), ('bom', '\ufeff' + NESTED.replace('\n', '\r\n'))]:
            source = self.file(name, text)
            nodes = self.root / (name + '-nodes')
            cp = self.shell(f'magicnet_singbox_source_is_clash {source}\nmagicnet_singbox_extract_clash_nodes {source} {nodes}')
            self.assertEqual(cp.stdout.strip(), '2')
            self.assertEqual(len(list(nodes.glob('node-*.yaml'))), 2)
            self.assertIn('alpn:\n  - h2\n  - http/1.1', (nodes / 'node-1.yaml').read_text())
            self.assertNotIn('not-a-node', (nodes / 'node-2.yaml').read_text())

    def test_flow_style_is_identified_without_pretending_native_support(self):
        source = self.file('flow.yaml', FLOW)
        cp = self.shell(f'magicnet_singbox_source_is_clash {source}\nmagicnet_singbox_extract_clash_nodes {source} {self.root / "nodes"}')
        self.assertEqual(cp.stdout.strip(), '0')

    def test_multiple_json_sources_do_not_stop_at_the_second_source(self):
        # Only replace the external executable; run the real merge/validation.
        converter = self.file('converter', '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do case "$1" in -singbox) src="$2"; shift;; -o) out="$2"; shift;; esac; shift; done\ncp "$src" "$out"\n')
        converter.chmod(0o700)
        files = [self.file(str(i) + '.json', json.dumps({'outbounds': [{'type': 'trojan', 'tag': f'node-{i}', 'server': f'{i}.invalid', 'server_port': 443, 'password': 'fixture'}]})) for i in range(3)]
        self.convert(files, converter, expected=3)

    def test_empty_or_invalid_source_cannot_be_hidden_by_another_provider(self):
        converter = self.file('converter', '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do case "$1" in -singbox) src="$2"; shift;; -o) out="$2"; shift;; esac; shift; done\ncp "$src" "$out"\n')
        converter.chmod(0o700)
        valid = self.file('valid.json', json.dumps({'outbounds': [{'type': 'trojan', 'tag': 'valid', 'server': 'ok.invalid', 'server_port': 443, 'password': 'fixture'}]}))
        invalid = self.file('invalid.json', '{"outbounds":[{"type":"direct","tag":"direct"}]}')
        self.convert([valid, invalid], converter, success=False)

    def native_update(self, content, converter=False):
        source = self.file('native-source', content)
        captured = self.root / 'candidate-outbounds.json'
        status = self.root / 'native-status'
        active = self.root / 'module/.config/sing-box/config.json'
        active.parent.mkdir(parents=True, exist_ok=True)
        if not active.exists():
            active.write_text('{"outbounds":[]}\n')
        captured.unlink(missing_ok=True)
        status.unlink(missing_ok=True)
        previous = active.read_bytes()
        converter_control = """
magicnet_singbox_proxylink_bin() { printf '/fixture-converter\\n'; }
magicnet_singbox_build_outbounds_with_proxylink() {
  printf '%s\\n' '[{"type":"trojan","tag":"converted","server":"192.0.2.10","server_port":443,"password":"fixture","tls":{"enabled":true,"server_name":"tls.example.invalid","alpn":["h2"]},"transport":{"type":"ws","path":"/fixture"}}]' >"$2"
  printf '1 0\\n'
}
""" if converter else ''
        if converter == 'failed':
            converter_control = '''
magicnet_singbox_proxylink_bin() { printf '/fixture-converter\\n'; }
magicnet_singbox_build_outbounds_with_proxylink() { return 1; }
'''
        self.shell(f"""
info() {{ :; }}; warn() {{ :; }}; error() {{ :; }}; success() {{ :; }}
magicnet_singbox_status_value() {{ printf '0\\n'; }}
magicnet_singbox_is_running() {{ return 1; }}
magicnet_singbox_transaction_begin() {{ return 0; }}
magicnet_singbox_update_cleanup_stage() {{ :; }}
magicnet_singbox_update_status() {{ printf '%s %s %s\\n' "$@" >>{shlex.quote(str(status))}; }}
magicnet_singbox_fetch_subscription() {{
  mkdir -p "${{1%/*}}/sources"
  cp {shlex.quote(str(source))} "${{1%/*}}/sources/offline"
  printf '%s\\n' "${{1%/*}}/sources/offline" >"$1"
}}
# Capture the real native result before any config install or core restart.
magicnet_singbox_update_config_with_nodes() {{
  cp "$1" {shlex.quote(str(captured))}
  return 1
}}
MAGICNET_PROXYLINK_ENABLED={int(bool(converter))}
MAGICNET_SUB_SOURCE_FILE={shlex.quote(str(source))}
{converter_control}
magicnet_singbox_update_subscription_unlocked
""", success=False)
        self.assertEqual(active.read_bytes(), previous)
        nodes = json.loads(captured.read_text()) if captured.exists() else None
        return nodes, status.read_text()

    def test_native_literal_quoted_keys_preserve_tls_server_name(self):
        for sni_key in ('sni', '"sni"', "'sni'", 'servername', '"servername"', "'servername'"):
            for flow in (False, True):
                with self.subTest(key=sni_key, flow=flow):
                    fields = [('name', 'tls-fixture'), ('type', 'trojan'),
                              ('server', '192.0.2.10'), ('port', '443'),
                              ('password', 'fixture'), (sni_key, 'tls.example.invalid')]
                    if flow:
                        content = 'proxies:\n  - {' + ', '.join(k + ': ' + v for k, v in fields) + '}\n'
                    else:
                        content = 'proxies:\n  - ' + '\n    '.join(k + ': ' + v for k, v in fields) + '\n'
                    nodes, _ = self.native_update(content)
                    self.assertIsNotNone(nodes)
                    node = next(n for n in nodes if n.get('server'))
                    self.assertEqual(node['tls']['server_name'], 'tls.example.invalid')
                    self.assertNotIn('insecure', node['tls'])

    def test_native_literal_quoted_mapping_keys_and_spaced_colons(self):
        content = """proxies:
  - "name" : tls-fixture
    'type' : trojan
    "server" : 192.0.2.10
    'port' : 443
    "password" : fixture
    'sni' : tls.example.invalid
"""
        nodes, _ = self.native_update(content)
        self.assertIsNotNone(nodes)
        node = next(n for n in nodes if n.get('server'))
        self.assertEqual(node['tls']['server_name'], 'tls.example.invalid')
        self.assertNotIn('insecure', node['tls'])

    def test_native_quoted_password_preserves_mapping_punctuation(self):
        values = [
            ('"fixture, alpn: h2"', 'fixture, alpn: h2'),
            ('"fixture#literal, sni: decoy.invalid"', 'fixture#literal, sni: decoy.invalid'),
            ('fixture#literal', 'fixture#literal'),
            (r"'fixture\path'", r'fixture\path'),
            ("'can''t, alpn: h2'", "can't, alpn: h2"),
            ("'fixture { alpn: h2 }, sni: decoy.invalid'", 'fixture { alpn: h2 }, sni: decoy.invalid'),
        ]
        for password, expected in values:
            for flow in (False, True):
                with self.subTest(password=password, flow=flow):
                    fields = [('name', 'tls-fixture'), ('type', 'trojan'),
                              ('server', '192.0.2.10'), ('port', '443'),
                              ('password', password), ('sni', 'tls.example.invalid')]
                    if flow:
                        content = 'proxies:\n  - {' + ', '.join(k + ': ' + v for k, v in fields) + '}\n'
                    else:
                        content = 'proxies:\n  - ' + '\n    '.join(k + ': ' + v for k, v in fields) + '\n'
                    nodes, _ = self.native_update(content)
                    self.assertIsNotNone(nodes)
                    node = next(n for n in nodes if n.get('server'))
                    self.assertEqual(node['password'], expected)
                    self.assertEqual(node['tls']['server_name'], 'tls.example.invalid')
                    self.assertNotIn('insecure', node['tls'])

    def test_native_complex_yaml_scalars_require_converter(self):
        ordinary = '  - name: ordinary\n    type: trojan\n    server: 192.0.2.10\n    port: 443\n    password: fixture\n    sni: tls.example.invalid\n'
        cases = [
            ('sni', '|\n      tls.example.invalid'),
            ('sni', '>-\n      tls.example.invalid'),
            ('sni', '*tls_name'),
            ('sni', '[tls.example.invalid]'),
            ('sni', '{host: tls.example.invalid}'),
            ('sni', r'"tls.example.\u0069nvalid"'),
            ('sni', '!!str tls.example.invalid'),
            ('servername', '&tls_name tls.example.invalid'),
        ]
        for value in ('!!bool true', '*tls_flag', '[true]', '|\n      true', 'unknown'):
            cases.append(('tls', value))
        for key in ('name', 'type', 'server', 'port', 'password', 'uuid', 'network',
                    'tls', 'insecure', 'skip-cert-verify'):
            cases.append((key, r'"tr\u0075e"'))
        for key, value in cases:
            for flow in (False, True):
                if flow and '\n' in value:
                    continue
                with self.subTest(key=key, value=value, flow=flow):
                    fields = {'name': 'advanced', 'type': 'vmess' if key == 'tls' else 'trojan',
                              'server': '192.0.2.10', 'port': '443', 'password': 'fixture',
                              'uuid': '00000000-0000-4000-8000-000000000001'}
                    fields[key] = value
                    if flow:
                        content = 'proxies:\n  - {' + ', '.join('"' + k + '": ' + v for k, v in fields.items()) + '}\n' + ordinary
                    else:
                        content = 'proxies:\n  - ' + '\n    '.join('"' + k + '": ' + v for k, v in fields.items()) + '\n' + ordinary
                    nodes, status = self.native_update(content)
                    self.assertIsNone(nodes)
                    self.assertIn('convert failed incomplete_conversion', status)

    def test_native_literal_boolean_tls_values_keep_their_intent(self):
        for value, enabled in (('true', True), ('True', True), ('"true"', True),
                               ("'true'", True), ('false', False), ('"false"', False)):
            with self.subTest(value=value):
                content = 'proxies:\n  - {name: fixture, type: vmess, server: 192.0.2.10, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: ' + value + ', sni: tls.example.invalid}\n'
                nodes, _ = self.native_update(content)
                self.assertIsNotNone(nodes)
                node = next(n for n in nodes if n.get('server'))
                if enabled:
                    self.assertEqual(node['tls']['server_name'], 'tls.example.invalid')
                    self.assertNotIn('insecure', node['tls'])
                else:
                    self.assertNotIn('tls', node)

    def test_converter_success_remains_available_for_complex_scalars(self):
        content = 'proxies:\n  - {name: fixture, type: trojan, server: 192.0.2.10, port: 443, password: fixture, "sni": "tls.example.\\u0069nvalid"}\n'
        nodes, _ = self.native_update(content, converter=True)
        self.assertIsNotNone(nodes)
        self.assertEqual(nodes[0]['tls']['server_name'], 'tls.example.invalid')
        self.assertNotIn('insecure', nodes[0]['tls'])

    def test_native_yaml_tls_and_transport_options_require_converter(self):
        ordinary = '  - name: ordinary\n    type: trojan\n    server: 192.0.2.10\n    port: 443\n    password: fixture\n    sni: tls.example.invalid\n'
        for field in ('network: ws', 'network: grpc', 'skip-cert-verify: true', 'insecure: true',
                      'type: wireguard', 'alpn: [h2, http/1.1]',
                      '"alpn": [h2]', "'ws-opts': {path: /fixture}",
                      r'"\u0073ni": tls.example.invalid'):
            with self.subTest(field=field):
                content = 'proxies:\n' + ordinary.replace('ordinary', 'advanced') + '    ' + field + '\n' + ordinary
                nodes, status = self.native_update(content)
                self.assertIsNone(nodes)
                self.assertIn('convert failed incomplete_conversion', status)
        for key in ('alpn', '"alpn"', "'alpn'"):
            with self.subTest(flow_key=key):
                content = 'proxies:\n  - {name: advanced, type: trojan, server: 192.0.2.10, port: 443, password: fixture, sni: tls.example.invalid, ' + key + ': [h2, http/1.1]}\n' + ordinary
                nodes, status = self.native_update(content)
                self.assertIsNone(nodes)
                self.assertIn('convert failed incomplete_conversion', status)

    def test_native_share_transport_cannot_be_silently_dropped(self):
        valid = 'trojan://fixture@192.0.2.10:443?sni=tls.example.invalid#ordinary\n'
        cases = [
            'trojan://fixture@192.0.2.10:443?sni=tls.example.invalid&type=ws&path=%2Ffixture#advanced',
            'trojan://fixture@192.0.2.10:443?sni=tls.example.invalid&type=grpc&serviceName=fixture#advanced',
            'vless://00000000-0000-4000-8000-000000000001@192.0.2.10:443?security=tls&sni=tls.example.invalid&type=ws#advanced',
            'vless://00000000-0000-4000-8000-000000000001@192.0.2.10:443?security=tls&sni=tls.example.invalid&alpn=h2#advanced',
        ]
        vmess = {'ps': 'advanced', 'add': '192.0.2.10', 'port': '443',
                 'id': '00000000-0000-4000-8000-000000000001', 'aid': '0',
                 'net': 'grpc', 'path': 'fixture-service', 'tls': 'tls', 'sni': 'tls.example.invalid'}
        cases.append('vmess://' + base64.b64encode(json.dumps(vmess).encode()).decode())
        for advanced in cases:
            with self.subTest(scheme=advanced.split(':')[0], index=cases.index(advanced)):
                nodes, status = self.native_update(advanced + '\n' + valid)
                self.assertIsNone(nodes)
                self.assertIn('convert failed incomplete_conversion', status)

    def test_failed_converter_cannot_fall_back_to_incomplete_tls_config(self):
        content = 'proxies:\n  - {name: fixture, type: trojan, server: 192.0.2.10, port: 443, password: fixture, "alpn": [h2]}\n'
        nodes, status = self.native_update(content, converter='failed')
        self.assertIsNone(nodes)
        self.assertIn('convert failed incomplete_conversion', status)

    def test_converter_success_preserves_advanced_options_without_native_rejection(self):
        content = 'proxies:\n  - {name: fixture, type: trojan, server: 192.0.2.10, port: 443, password: fixture, "alpn": [h2], network: ws}\n'
        nodes, _ = self.native_update(content, converter=True)
        self.assertIsNotNone(nodes)
        self.assertEqual(nodes[0]['tls']['alpn'], ['h2'])
        self.assertEqual(nodes[0]['transport']['path'], '/fixture')
        self.assertNotIn('insecure', nodes[0]['tls'])

    def convert(self, files, converter, expected=0, success=True):
        sources = self.file('sources.txt', ''.join(str(p) + '\n' for p in files))
        out = self.root / 'out.json'
        self.shell(f'''magicnet_singbox_proxylink_bin() {{ printf '%s\\n' {shlex.quote(str(converter))}; }}
magicnet_singbox_build_outbounds_with_proxylink {sources} {out} {expected}
''', success=success)
        if success:
            nodes = [n for n in json.loads(out.read_text()) if 'server' in n]
            self.assertEqual(len(nodes), expected)
            return {n['tag']: n for n in nodes}
        return None

    @unittest.skipUnless(CONVERTER, 'real converter is exercised by the evidence job')
    def test_real_mixed_yaml_flow_share_links_and_singbox_json(self):
        json_source = self.file('nodes.json', json.dumps({'outbounds': [{'type': 'trojan', 'tag': 'json-node', 'server': 'json.invalid', 'server_port': 443, 'password': 'fixture'}]}))
        nodes = self.convert([self.file('nested.yaml', NESTED), self.file('flow.yaml', FLOW), self.file('links.txt', LINK), json_source], CONVERTER, 5)
        self.assertEqual(nodes['nested-tls']['tls']['alpn'], ['h2', 'http/1.1'])
        self.assertEqual(nodes['nested-tls']['tls']['server_name'], 'example.invalid')
        self.assertEqual(nodes['websocket']['transport'], {'type': 'ws', 'path': '/tunnel', 'headers': {'Host': 'ws.example.invalid'}})
        self.assertIn('sharing', nodes)
        self.assertIn('json-node', nodes)

    @unittest.skipUnless(CONVERTER, 'real converter is exercised by the evidence job')
    def test_real_bom_crlf_and_base64_yaml(self):
        bom = self.file('bom.yaml', '\ufeff' + NESTED.replace('\n', '\r\n'))
        self.convert([bom], CONVERTER, 2)
        encoded = self.file('encoded.txt', base64.b64encode(NESTED.encode()).decode())
        self.convert([encoded], CONVERTER, 2)


if __name__ == '__main__':
    unittest.main(argv=[__file__, *remaining])
