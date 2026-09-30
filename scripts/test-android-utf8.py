#!/usr/bin/env python3
"""Exercise production parsers with real shell tools and public UTF-8 input.

MAGICNET_KSU_BUSYBOX selects the unmodified KernelSU v3.2.0 x86_64 binary.
These host tests do not attest to Android networking or installation.
"""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('MAGICNET_UTF8_SOURCE', ROOT / 'src/MagicNet/lib/magicnet')).resolve()
KSU_SHA256 = '060844b0769f7a50262854af027c4d6076a212d160a51309b53057cfb7122900'


class Utf8ParserTests(unittest.TestCase):
    def test_actual_parsers_preserve_unicode_and_reject_invalid_config(self):
        shells = [['sh'], ['bash']]
        native = os.environ.get('MAGICNET_KSU_BUSYBOX')
        if native:
            binary = Path(native).resolve()
            self.assertEqual(hashlib.sha256(binary.read_bytes()).hexdigest(), KSU_SHA256)
        elif shutil.which('busybox'):
            shells.append(['busybox', 'ash'])
        jq = shutil.which('jq')
        self.assertIsNotNone(jq, 'jq is required; do not skip parser validation')
        with tempfile.TemporaryDirectory() as tmp:
            module = Path(tmp)
            if native:
                # This multicall binary dispatches argv[0]. A downloaded name
                # such as ksu-busybox is not an applet; preserve its bytes and
                # invoke it through the same busybox basename used on Android.
                (module / 'busybox').symlink_to(binary)
                shells.append([str(module / 'busybox'), 'sh'])
            (module / 'bin').mkdir()
            (module / 'bin/jq').symlink_to(jq)
            (module / 'lib').mkdir()
            (module / 'lib/magicnet').symlink_to(SOURCE)
            (module / '.config/sing-box').mkdir(parents=True)
            (module / 'values').write_text(' \n# 注释\n  # 中文\n 测试 \n测试\n 测试 \n')
            (module / 'escape-input').write_text('测"试\\🌍\n\r\t\x01\x7f' + '长' * 3000)
            (module / 'escape-expected').write_text('测\\"试\\\\🌍   ' + '长' * 3000)
            (module / 'source.yaml').write_bytes(('\ufeffproxies: # 中文\r\n'
                '  # 注释\r\n  - name: "测试🌍"\r\n    type: trojan\r\n'
                '    server: example.invalid\r\n    port: 443\r\n'
                '    password: fixture\r\nproxy-groups:\r\n'
                '  - name: 不是节点\r\n').encode())
            (module / 'share-links').write_text('  trojan://fixture@example.invalid:443#测试🌍\n')
            (module / '.config/sing-box/standalone-config').touch()
            script = r'''
set -eu
import() { :; }
. "$MODDIR/lib/magicnet/common.sh"
. "$MODDIR/lib/magicnet/apps.sh"
for attempt in 1 2 3 4 5; do
    test "$(magicnet_json_escape "$(cat "$MODDIR/escape-input")")" = "$(cat "$MODDIR/escape-expected")"
done
. "$MODDIR/lib/magicnet/singbox_subscribe/common.sh"
. "$MODDIR/lib/magicnet/singbox_subscribe/parse.sh"
magicnet_singbox_source_is_clash "$MODDIR/source.yaml"
test "$(magicnet_singbox_extract_clash_nodes "$MODDIR/source.yaml" "$MODDIR/yaml-nodes")" = 1
magicnet_singbox_emit_node_json "$MODDIR/yaml-nodes/node-1.yaml" >"$MODDIR/yaml-node.json"
"$MODDIR/bin/jq" -e '.tag == "测试🌍" and .server_port == 443 and .password == "fixture"' "$MODDIR/yaml-node.json" >/dev/null
test "$(magicnet_singbox_extract_share_links "$MODDIR/share-links" "$MODDIR/link-nodes")" = 1
magicnet_singbox_emit_share_link_json "$MODDIR/link-nodes/node-1.link" >"$MODDIR/link-node.json"
"$MODDIR/bin/jq" -e '.tag == "测试🌍" and .server_port == 443' "$MODDIR/link-node.json" >/dev/null
test "$(magicnet_app_proxy_packages "$MODDIR/values")" = '测试'
test "$(magicnet_list_file_values "$MODDIR/values")" = ' 测试 
测试'
cmd() { printf 'Users:\nUserInfo{0:测试:13}\nUserInfo{10:工作:30}\n'; }
test "$(magicnet_android_user_ids)" = '0
10'
cfg="$MODDIR/.config/sing-box/config.json"
"$MODDIR/bin/jq" -cn '{inbounds:[{type:"mixed"}],outbounds:[{type:"direct",tag:("测试🌍"*3000)}]}' >"$cfg"
magicnet_singbox_standalone_config_ready
for invalid in '{}' '{"inbounds":[],"outbounds":[]}' '{"inbounds":"fake","outbounds":[]}' '{"inbounds":[],"outbounds":{}}' '{"inbounds":[]}{"outbounds":[]}'; do
    printf '%s\n' "$invalid" >"$cfg"
    if magicnet_singbox_standalone_config_ready; then exit 91; fi
done
magicnet_singbox_ai_selectors_canonical() { return 0; }
printf '%s\n' '{"inbounds":[],"outbounds":[],"metadata":{"type":"socks"}}' >"$cfg"
if magicnet_singbox_config_has_nodes; then exit 92; fi
printf '%s\n' '{"outbounds":[{"type":"socks","tag":"测试🌍"}]}' >"$cfg"
magicnet_singbox_config_has_nodes
'''
            for shell in shells:
                with self.subTest(shell=shlex.join(shell)):
                    # Every interpreter must generate its own outputs.
                    for directory in ('yaml-nodes', 'link-nodes'):
                        shutil.rmtree(module / directory, ignore_errors=True)
                    env = dict(os.environ, MODDIR=str(module), ASH_STANDALONE='1')
                    result = subprocess.run([*shell, '-c', script], env=env,
                                            text=True, capture_output=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
