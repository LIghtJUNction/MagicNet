#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OPTIMIZER_PATH = ROOT / "scripts/optimize-sing-box-routing.py"
SPEC = importlib.util.spec_from_file_location("routing_optimizer", OPTIMIZER_PATH)
assert SPEC is not None and SPEC.loader is not None
OPTIMIZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OPTIMIZER)


def tag_index(rules, tag):
    return next(i for i, rule in enumerate(rules) if tag in rule.get("rule_set", []))


def domain_index(rules, domain):
    return next(i for i, rule in enumerate(rules) if domain in rule.get("domain", []))


def wechat_dns_index(rules):
    return next(
        i
        for i, rule in enumerate(rules)
        if rule.get("server") == "bootstrap-local-dns"
        and "wechat.com" in rule.get("domain_suffix", [])
        and "weixin.com" in rule.get("domain_suffix", [])
    )


class RoutingOptimizerTests(unittest.TestCase):
    def fixture(self):
        return {
            "route": {
                "rules": [
                    {"rule_set": ["meta-google-gemini"], "outbound": "ai-gemini"},
                    {"rule_set": ["meta-google-play"], "outbound": "google-proxy"},
                    {
                        "domain": ["android.clients.google.com", "android.clients.google.com"],
                        "outbound": "google-proxy",
                    },
                    {"rule_set": ["lyc-geosite-ads"], "outbound": "ad-block"},
                    {"rule_set": ["meta-tencent"], "outbound": "cn-direct"},
                    {"rule_set": ["karing-acl4ssr-wechat"], "outbound": "cn-direct"},
                    {"rule_set": ["r1"], "outbound": "proxy-rule"},
                    {"rule_set": ["r2", "r2"], "outbound": "proxy-rule"},
                    {
                        "network": "tcp",
                        "rule_set": ["scoped"],
                        "outbound": "proxy-rule",
                    },
                ]
            },
            "dns": {
                "rules": [
                    {"rule_set": ["meta-google-gemini"], "server": "doh-google"},
                    {
                        "domain": ["android.clients.google.com"],
                        "server": "doh-google",
                    },
                    {"rule_set": ["lyc-geosite-ads"], "server": "doh-cloudflare"},
                    {"rule_set": ["meta-tencent"], "server": "bootstrap-local-dns"},
                    {
                        "domain_suffix": ["wechat.com", "weixin.com"],
                        "server": "bootstrap-local-dns",
                    },
                    {"rule_set": ["r1"], "server": "doh-google"},
                    {"rule_set": ["r2"], "server": "doh-google"},
                ]
            },
        }

    def assert_priorities(self, config):
        route = config["route"]["rules"]
        dns = config["dns"]["rules"]
        self.assertLess(
            domain_index(route, "android.clients.google.com"),
            tag_index(route, "meta-google-gemini"),
        )
        self.assertLess(
            domain_index(dns, "android.clients.google.com"),
            tag_index(dns, "meta-google-gemini"),
        )
        self.assertLess(
            tag_index(route, "karing-acl4ssr-wechat"),
            tag_index(route, "lyc-geosite-ads"),
        )
        self.assertLess(
            tag_index(route, "lyc-geosite-ads"),
            tag_index(route, "meta-tencent"),
        )
        self.assertLess(
            wechat_dns_index(dns),
            tag_index(dns, "lyc-geosite-ads"),
        )
        self.assertLess(
            tag_index(dns, "lyc-geosite-ads"),
            tag_index(dns, "meta-tencent"),
        )

    def test_priorities_deduplication_and_compaction(self):
        optimized = OPTIMIZER.optimize_config(self.fixture())
        self.assert_priorities(optimized)

        google_rule = next(
            rule
            for rule in optimized["route"]["rules"]
            if "android.clients.google.com" in rule.get("domain", [])
        )
        self.assertEqual(google_rule["domain"], ["android.clients.google.com"])

        merged_route = next(
            rule
            for rule in optimized["route"]["rules"]
            if rule.get("rule_set") == ["r1", "r2"]
        )
        self.assertEqual(merged_route["outbound"], "proxy-rule")
        merged_dns = next(
            rule
            for rule in optimized["dns"]["rules"]
            if rule.get("rule_set") == ["r1", "r2"]
        )
        self.assertEqual(merged_dns["server"], "doh-google")

        self.assertTrue(
            any(
                rule.get("network") == "tcp"
                and rule.get("rule_set") == ["scoped"]
                and rule.get("outbound") == "proxy-rule"
                for rule in optimized["route"]["rules"]
            )
        )

    def test_legacy_mixed_wechat_dns_rule_set_stays_supported(self):
        config = self.fixture()
        config["dns"]["rules"] = [
            {"rule_set": ["meta-google-gemini"], "server": "doh-google"},
            {"domain": ["android.clients.google.com"], "server": "doh-google"},
            {"rule_set": ["lyc-geosite-ads"], "server": "doh-cloudflare"},
            {
                "rule_set": ["meta-tencent", "karing-acl4ssr-wechat"],
                "server": "bootstrap-local-dns",
            },
        ]
        optimized = OPTIMIZER.optimize_config(config)
        dns = optimized["dns"]["rules"]
        self.assertLess(
            tag_index(dns, "karing-acl4ssr-wechat"),
            tag_index(dns, "lyc-geosite-ads"),
        )
        self.assertLess(
            tag_index(dns, "lyc-geosite-ads"),
            tag_index(dns, "meta-tencent"),
        )

    def test_optimizer_is_idempotent(self):
        once = OPTIMIZER.optimize_config(self.fixture())
        twice = OPTIMIZER.optimize_config(once)
        self.assertEqual(once, twice)

    def test_checked_in_template_is_compatible(self):
        config = json.loads(
            (ROOT / "src/MagicNet/.config/sing-box/config.json").read_text(encoding="utf-8")
        )
        optimized = OPTIMIZER.optimize_config(config)
        self.assert_priorities(optimized)
        self.assertEqual(optimized, OPTIMIZER.optimize_config(optimized))

        self.assertEqual(config["route"]["final"], optimized["route"]["final"])
        self.assertEqual(config["dns"]["final"], optimized["dns"]["final"])
        self.assertEqual(config["outbounds"], optimized["outbounds"])
        self.assertEqual(config["route"]["rule_set"], optimized["route"]["rule_set"])


if __name__ == "__main__":
    unittest.main()
