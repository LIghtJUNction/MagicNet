#!/usr/bin/env python3
"""Check packaged routing policy and default-template references without a device."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "src/MagicNet/.config/sing-box"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load test helper: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RoutingTemplateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (TEMPLATE / "config.json").is_file():
            raise RuntimeError("Initialize src/MagicNet/.config/sing-box before running these tests")
        cls.config = json.loads((TEMPLATE / "config.json").read_text(encoding="utf-8"))
        cls.defaults = dict(
            line.split("=", 1)
            for line in (ROOT / "src/MagicNet/.config/magicnet/singbox-config-repo.conf")
            .read_text(encoding="utf-8").splitlines()
            if line and not line.startswith("#")
        )
        cls.optimizer = load_module("routing_optimizer", ROOT / "scripts/optimize-sing-box-routing.py")
        cls.matcher = load_module("routing_matcher", TEMPLATE / "tests/test_dns_routing_priority.py")

    def test_template_pin_and_digest_match_checkout(self):
        expected = self.defaults["MAGICNET_SINGBOX_CONFIG_REPO_REF"]
        self.assertRegex(expected, r"^[0-9a-f]{40}$")
        actual = subprocess.check_output(["git", "-C", str(TEMPLATE), "rev-parse", "HEAD"], text=True).strip()
        self.assertEqual(actual, expected)
        staged = subprocess.check_output(
            ["git", "-C", str(ROOT), "ls-files", "--stage", "--", "src/MagicNet/.config/sing-box"], text=True
        ).split()
        self.assertEqual(staged[:2], ["160000", expected])
        digest = hashlib.sha256((TEMPLATE / "config.json").read_bytes()).hexdigest()
        self.assertEqual(digest, self.defaults["MAGICNET_SINGBOX_CONFIG_REPO_SHA256"])

    def test_all_default_template_entry_points_agree(self):
        for filename in ("src/MagicNet/customize.sh", "crates/magicnet-cli/src/config_editor.rs",
                         "webui/src/components/pages/ConfigPage.vue"):
            text = (ROOT / filename).read_text(encoding="utf-8")
            for key in ("MAGICNET_SINGBOX_CONFIG_REPO_REF", "MAGICNET_SINGBOX_CONFIG_REPO_SHA256"):
                with self.subTest(filename=filename, key=key):
                    self.assertIn(self.defaults[key], text)

    def test_generated_template_is_current(self):
        subprocess.run(["python3", "generate.py", "--check"], cwd=TEMPLATE, check=True)

    def test_normalizer_preserves_lmm_route_and_dns(self):
        normalized = self.optimizer.optimize_config(self.config)
        self.assertEqual(self.optimizer.optimize_config(normalized), normalized)
        for config in (self.config, normalized):
            for domain in ("lmm.best", "api.lmm.best", "msg.lmm.best", "donate.lmm.best", "nested.api.lmm.best"):
                for mode in ("Rule", "Direct", "Global"):
                    for network in ("tcp", "udp"):
                        with self.subTest(domain=domain, mode=mode, network=network):
                            self.assertEqual(self.matcher.first_action(config, domain=domain, mode=mode,
                                network=network, tags=("lyc-geosite-cn", "lyc-geoip-cn", "lyc-geosite-ads")), "proxy")
            self.assertEqual(config["dns"]["rules"][0],
                             {"domain_suffix": ["lmm.best"], "server": "doh-cloudflare"})
            dns = next(server for server in config["dns"]["servers"] if server["tag"] == "doh-cloudflare")
            self.assertEqual(dns["detour"], "proxy")
            self.assertEqual(config["route"]["default_domain_resolver"], "bootstrap-local-dns")
            self.assertEqual(self.matcher.first_action(config, domain="api.lmm.best", port=53), "hijack-dns")
            for domain in ("notlmm.best", "lmm.best.example.invalid"):
                self.assertEqual(self.matcher.first_action(config, domain=domain, mode="Direct"), "direct")


if __name__ == "__main__":
    unittest.main()
