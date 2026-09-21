#!/usr/bin/env python3
"""Regressions for modern sing-box routing and stateful DNS evaluation."""

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "routing_optimizer_modern", ROOT / "scripts/optimize-sing-box-routing.py"
)
assert SPEC is not None and SPEC.loader is not None
OPTIMIZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OPTIMIZER)

FOREIGN = "metacubex-geosite-geolocation-not-cn"
CN_IP = "lyc-geoip-cn"


def fixture(route=(), dns=()):
    return {
        "route": {"rules": list(route), "final": "final"},
        "dns": {"rules": list(dns), "final": "bootstrap-local-dns"},
        "outbounds": [{"type": "selector", "tag": "final", "outbounds": ["my-node"]}],
    }


def dispatch(tag, target="proxy-rule", **extra):
    return {"rule_set": [tag], "outbound": target, **extra}


class ModernRoutingTests(unittest.TestCase):
    def optimize(self, config):
        original = copy.deepcopy(config)
        result = OPTIMIZER.optimize_config(config)
        self.assertEqual(config, original, "must not mutate input")
        self.assertEqual(result, OPTIMIZER.optimize_config(result), "must be idempotent")
        self.assertEqual(result["outbounds"], original["outbounds"])
        self.assertEqual(result["dns"]["final"], original["dns"]["final"])
        self.assertEqual(result["route"]["final"], original["route"]["final"])
        return result

    def test_foreign_domain_precedes_cn_ip_but_not_domestic_exceptions(self):
        rules = [
            {"clash_mode": "Direct", "outbound": "direct"},
            {"clash_mode": "Global", "outbound": "select"},
            {"ip_is_private": True, "outbound": "lan"},
            dispatch("lyc-geosite-cn", "cn-direct"),
            dispatch("lyc-geoip-telegram", "telegram-proxy"),
            dispatch(CN_IP, "cn-direct"),
            dispatch(FOREIGN),
        ]
        result = self.optimize(fixture(route=rules))["route"]["rules"]
        self.assertEqual(result, rules[:5] + [rules[6], rules[5]])
        # Synthetic overlap: membership in both classifiers must choose proxy.
        def first_match(candidates, memberships):
            for rule in candidates:
                if memberships.intersection(rule.get("rule_set", [])):
                    return rule["outbound"]
        self.assertEqual(first_match(result, {FOREIGN, CN_IP}), "proxy-rule")
        self.assertEqual(first_match(result, {CN_IP}), "cn-direct")
        self.assertEqual(first_match(result, {FOREIGN, "lyc-geosite-cn"}), "cn-direct")

    def test_foreign_scalar_tag_and_explicit_action_are_supported(self):
        rules = [dispatch(CN_IP, "cn-direct", action="route"),
                 {"rule_set": FOREIGN, "outbound": "proxy-rule", "action": "route"}]
        result = self.optimize(fixture(route=rules))["route"]["rules"]
        self.assertEqual(result[0], dispatch(FOREIGN, action="route"))

    def test_foreign_promotion_does_not_drag_merged_siblings(self):
        rules = [dispatch(CN_IP, "cn-direct"),
                 {"rule_set": [FOREIGN, "custom"], "outbound": "proxy-rule"}]
        self.assertEqual(self.optimize(fixture(route=rules))["route"]["rules"],
                         [dispatch(FOREIGN), rules[0], dispatch("custom")])

    def test_custom_scoped_or_mixed_cn_rules_are_not_reordered(self):
        for anchor in (
            dispatch(CN_IP, "custom"),
            dispatch(CN_IP, "cn-direct", network="tcp"),
            {"rule_set": [CN_IP, "lyc-geosite-cn"], "outbound": "cn-direct"},
        ):
            with self.subTest(anchor=anchor):
                rules = [anchor, dispatch(FOREIGN)]
                self.assertEqual(self.optimize(fixture(route=rules))["route"]["rules"], rules)
        for extra in ({"invert": True}, {"network": "tcp"}, {"outbound": "custom"}):
            rules = [dispatch(CN_IP, "cn-direct"), {**dispatch(FOREIGN), **extra}]
            self.assertEqual(self.optimize(fixture(route=rules))["route"]["rules"], rules)

    def test_port_53_fast_path_preserves_sniff_fallback_and_prior_rules(self):
        prefix = {"inbound": ["custom"], "action": "reject"}
        sniff = {"inbound": ["mixed-in", "tun-in"], "action": "sniff"}
        hijack = {"protocol": "dns", "action": "hijack-dns"}
        rules = [prefix, sniff, hijack]
        result = self.optimize(fixture(route=rules))["route"]["rules"]
        self.assertEqual(result, [prefix, {"inbound": sniff["inbound"], "port": 53,
                                          "action": "hijack-dns"}, sniff, hijack])

    def test_scalar_inbound_fast_path(self):
        rules = [{"inbound": "tun-in", "action": "sniff"},
                 {"protocol": "dns", "action": "hijack-dns"}]
        result = self.optimize(fixture(route=rules))["route"]["rules"]
        self.assertEqual(result[0], {"inbound": "tun-in", "port": 53, "action": "hijack-dns"})

    def test_custom_sniff_or_missing_hijack_does_not_gain_fast_path(self):
        hijack = {"protocol": "dns", "action": "hijack-dns"}
        for sniff in (
            {"inbound": ["custom"], "action": "sniff"},
            {"inbound": ["tun-in"], "network": "tcp", "action": "sniff"},
            {"action": "sniff"},
            {"inbound": [], "action": "sniff"},
        ):
            rules = [sniff, hijack]
            self.assertEqual(self.optimize(fixture(route=rules))["route"]["rules"], rules)
        rules = [{"inbound": ["tun-in"], "action": "sniff"}]
        self.assertEqual(self.optimize(fixture(route=rules))["route"]["rules"], rules)

    def test_repeated_evaluate_preserves_latest_response(self):
        local = {"action": "evaluate", "server": "local"}
        remote = {"action": "evaluate", "server": "remote"}
        rules = [local, remote, local, {"action": "respond"}]
        result = self.optimize(fixture(dns=rules))["dns"]["rules"]
        self.assertEqual(result, rules)
        self.assertEqual([r["server"] for r in result if r["action"] == "evaluate"][-1], "local")

    def test_repeated_nonterminal_route_actions_are_preserved(self):
        for action in ("sniff", "resolve", "route-options"):
            rules = [{"action": action}, {"action": action}]
            self.assertEqual(self.optimize(fixture(route=rules))["route"]["rules"], rules)

    def test_terminal_duplicates_on_either_side_of_resolve_are_preserved(self):
        rule = dispatch(CN_IP, "cn-direct")
        rules = [rule, {"action": "resolve", "server": "local"}, rule]
        self.assertEqual(self.optimize(fixture(route=rules))["route"]["rules"], rules)

    def test_response_matches_and_logical_subrules_are_barriers(self):
        response = {"match_response": True, "ip_is_private": True, "action": "respond"}
        logical = {"type": "logical", "mode": "or", "rules": [
            {"match_response": "remote", "ip_is_private": True}],
            "action": "route", "server": "local"}
        for barrier in (response, logical):
            rules = [{"action": "evaluate", "server": "remote"}, barrier, barrier]
            self.assertEqual(self.optimize(fixture(dns=rules))["dns"]["rules"], rules)

    def test_priorities_do_not_cross_evaluation_or_mode_barriers(self):
        for section, key, target in (("dns", "server", "doh-google"),
                                     ("route", "outbound", "google-proxy")):
            for barrier in ({"action": "evaluate", "server": "local"},
                            {"action": "route-options"},
                            {"clash_mode": "Global", key: target}):
                rules = [{"rule_set": ["meta-google-gemini"], key: target},
                         barrier, {"domain": ["android.clients.google.com"], key: target}]
                config = fixture(**{section: rules})
                self.assertEqual(self.optimize(config)[section]["rules"], rules)
        rules = [dispatch(CN_IP, "cn-direct"), {"action": "resolve"}, dispatch(FOREIGN)]
        self.assertEqual(self.optimize(fixture(route=rules))["route"]["rules"], rules)

    def test_wechat_priority_does_not_cross_evaluate(self):
        rules = [{"rule_set": ["lyc-geosite-ads"], "server": "doh-cloudflare"},
                 {"action": "evaluate", "server": "local"},
                 {"rule_set": ["service-wechat-dns"], "server": "bootstrap-local-dns"}]
        self.assertEqual(self.optimize(fixture(dns=rules))["dns"]["rules"], rules)

    def test_explicit_route_compaction_keeps_scoped_rules_separate(self):
        for section, key in (("dns", "server"), ("route", "outbound")):
            rules = [{"rule_set": ["a"], key: "target", "action": "route"},
                     {"rule_set": ["b"], key: "target"},
                     {"rule_set": ["c"], key: "target", "network": "tcp"}]
            result = self.optimize(fixture(**{section: rules}))[section]["rules"]
            self.assertEqual(result, [{"rule_set": ["a", "b"], key: "target", "action": "route"}, rules[2]])

    def test_explicit_wechat_priority_keeps_tencent_behind_ads(self):
        rules = [{"rule_set": ["lyc-geosite-ads"], "server": "doh-cloudflare"},
                 {"rule_set": ["meta-tencent", "service-wechat-dns"],
                  "server": "bootstrap-local-dns", "action": "route"}]
        result = self.optimize(fixture(dns=rules))["dns"]["rules"]
        self.assertEqual(result[0]["rule_set"], ["service-wechat-dns"])
        self.assertEqual(result[0]["action"], "route")
        self.assertEqual(result[1], rules[0])
        self.assertEqual(result[2]["rule_set"], ["meta-tencent"])

    def test_scoped_google_rule_is_not_promoted(self):
        rules = [{"rule_set": ["meta-google-gemini"], "server": "doh-google"},
                 {"domain": ["android.clients.google.com"], "server": "doh-google",
                  "query_type": ["A"]}]
        self.assertEqual(self.optimize(fixture(dns=rules))["dns"]["rules"], rules)

    def test_file_rewrite_is_atomic_idempotent_and_preserves_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            config = fixture(route=[dispatch(CN_IP, "cn-direct"), dispatch(FOREIGN)])
            path.write_text(json.dumps(config), encoding="utf-8")
            path.chmod(0o600)
            self.assertTrue(OPTIMIZER.optimize_file(path))
            text = path.read_bytes()
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertFalse(OPTIMIZER.optimize_file(path, check=True))
            self.assertFalse(OPTIMIZER.optimize_file(path))
            self.assertEqual(path.read_bytes(), text)
            self.assertEqual(list(Path(directory).glob("*.tmp")), [])

    def test_invalid_json_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text('{"route":', encoding="utf-8")
            with self.assertRaises(ValueError):
                OPTIMIZER.optimize_file(path)
            self.assertEqual(path.read_text(), '{"route":')


if __name__ == "__main__":
    unittest.main()
