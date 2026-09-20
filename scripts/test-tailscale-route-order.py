#!/usr/bin/env python3
"""Run the real Tailscale and app-policy materializers together (#327).

Only Android package-to-UID lookup is stubbed. This proves configuration
ordering/idempotence, not live tailnet connectivity or Android acceptance.
"""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "src/MagicNet/lib/magicnet"
TAILNETS = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]
SHELLS = [("sh", [shutil.which("sh")])]
if shutil.which("busybox"):
    SHELLS.append(("ash", [shutil.which("busybox"), "ash"]))
T = "magicnet_tailscale_apply_unlocked"
A = "magicnet_singbox_apply_app_policy"


class TailscaleRouteOrder(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="magicnet-tailnet-")
        self.addCleanup(self.temp.cleanup)
        self.module = Path(self.temp.name) / "module with spaces"
        (self.module / "bin").mkdir(parents=True)
        jq = shutil.which("jq")
        if jq is None:
            self.fail("missing required test tool: jq")
        (self.module / "bin/jq").symlink_to(jq)
        self.config = self.module / ".config/sing-box/config.json"
        self.config.parent.mkdir(parents=True)
        self.policy = self.module / ".config/magicnet"
        self.policy.mkdir()
        self.base = {
            "inbounds": [{"type": "tun", "tag": "tun-in",
                          "route_exclude_address": [*TAILNETS, "192.168.0.0/16"]}],
            "outbounds": [{"type": "direct", "tag": "direct"},
                          {"type": "selector", "tag": "lan", "outbounds": ["direct"]},
                          {"type": "selector", "tag": "proxy", "outbounds": ["direct"]}],
            "dns": {"servers": [{"type": "local", "tag": "local"}], "rules": []},
            "route": {"rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_cidr": ["10.0.0.0/8", *TAILNETS], "outbound": "lan"},
                {"domain_suffix": ["example.com"], "outbound": "proxy"},
            ]},
        }

    def reset(self, tag=None, apps=True):
        config = copy.deepcopy(self.base)
        if tag is not None:
            config["endpoints"] = [{"type": "tailscale", "tag": tag, "system_interface": False}]
        self.config.write_text(json.dumps(config), encoding="utf-8")
        for kind in ("proxy", "direct", "bypass"):
            text = f"org.example.{kind}\n" if apps and kind != "bypass" else ""
            (self.policy / f"app-{kind}.list").write_text(text, encoding="utf-8")
        return config

    def apply(self, shell, operations, mode="blacklist"):
        script = '''. "$1/runtime_config.sh"
. "$1/apps.sh"
magicnet_conf_value() { return 1; }
magicnet_package_uids() { if [ -s "$1" ]; then printf '10123\\n'; fi; }
'''
        script += "\n".join(f"{operation} || exit $?" for operation in operations)
        result = subprocess.run(
            [*shell, "-c", script, "tailnet-test", str(LIB)],
            env={**os.environ, "MODDIR": str(self.module), "MAGICNET_APP_MODE": mode},
            capture_output=True, text=True, timeout=15, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.config.read_text())

    def assert_routes(self, config, tag):
        rules = config["route"]["rules"]
        lan = next(i for i, rule in enumerate(rules) if rule.get("outbound") == "lan")
        mesh = [(i, rule) for i, rule in enumerate(rules) if rule.get("outbound") == tag]
        self.assertEqual(len(mesh), 2)
        self.assertTrue(all(i < lan for i, _ in mesh), rules)
        self.assertTrue(all(rule.get("action") == "route" for _, rule in mesh))
        ip_rule = next(rule for _, rule in mesh if "ip_cidr" in rule)
        self.assertEqual(ip_rule["ip_cidr"], TAILNETS)
        self.assertEqual(ip_rule["preferred_by"], [tag])
        self.assertEqual(rules[lan], self.base["route"]["rules"][2])
        self.assertEqual(rules[:2], self.base["route"]["rules"][:2])
        self.assertEqual(config["inbounds"][0]["route_exclude_address"], ["192.168.0.0/16"])
        for i, rule in enumerate(rules):
            if "package_name" in rule:
                self.assertGreater(i, lan)
        dns = [server for server in config["dns"]["servers"] if server["type"] == "tailscale"]
        self.assertEqual(len(dns), 1)
        self.assertEqual(dns[0]["endpoint"], tag)

    def test_default_and_custom_tags_survive_app_reordering(self):
        for name, shell in SHELLS:
            for tag in ("tailscale", "office-mesh"):
                for mode in ("blacklist", "whitelist"):
                    with self.subTest(shell=name, tag=tag, mode=mode):
                        self.reset(tag)
                        self.assert_routes(self.apply(shell, [T, A], mode), tag)

    def test_both_materialization_orders_are_idempotent(self):
        for name, shell in SHELLS:
            for operations in ([T, A], [A, T]):
                with self.subTest(shell=name, order=operations):
                    self.reset("office-mesh")
                    first = self.apply(shell, operations)
                    second = self.apply(shell, operations)
                    self.assertEqual(first, second)
                    self.assert_routes(second, "office-mesh")
                    self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_no_endpoint_keeps_carrier_and_lan_policy(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                original = self.reset()
                result = self.apply(shell, [T])
                self.assertEqual(result, original)

    def test_no_app_overrides(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                self.reset("office-mesh", apps=False)
                self.assert_routes(self.apply(shell, [T, A]), "office-mesh")

    def test_legacy_managed_rules_are_upgraded_without_duplicates(self):
        for name, shell in SHELLS:
            with self.subTest(shell=name):
                config = self.reset("office-mesh")
                config["route"]["rules"] += [
                    {"ip_cidr": TAILNETS, "preferred_by": ["tailscale"], "outbound": "office-mesh"},
                    {"domain_suffix": ["ts.net"], "outbound": "office-mesh"},
                ]
                self.config.write_text(json.dumps(config), encoding="utf-8")
                self.assert_routes(self.apply(shell, [T, A, T, A]), "office-mesh")


if __name__ == "__main__":
    unittest.main(verbosity=2)
