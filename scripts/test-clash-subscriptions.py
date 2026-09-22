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
        self.prefix = f'''set -eu
MODDIR={shlex.quote(str(ROOT / 'src/MagicNet'))}
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
