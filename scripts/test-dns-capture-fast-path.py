#!/usr/bin/env python3
"""Exercise the production DNS installer without touching the host firewall."""
import itertools
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SHELLS = [["sh"], ["bash"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "ash"])
FIXTURE = r'''
set -eu
. "$NETWORK_SOURCE"
magicnet_cmd_exists() { return 0; }
magicnet_transparent_mode() { printf '%s\n' "${MODE:-tun}"; }
magicnet_ipv6_mode() { printf '%s\n' "${IPV6_MODE:-prefer_ipv4}"; }
magicnet_dns_profile() { printf '%s\n' "${PROFILE:-default}"; }
magicnet_dns_capture_singbox_mark() { printf '128\n'; }
magicnet_dns_capture_singbox_udp_marked() { [ "${MARKED:-1}" = 1 ]; }
magicnet_warn() { printf '%s\n' "$*" >&2; }
magicnet_log() { :; }
mock_xtables() (
    family=$1; shift
    printf '%s\n' "$family $*" >> "$CALLS"
    case " $* " in
    *' -C '* | *' -D '*) return 1 ;;
    *' -N '*) [ "${EXISTING:-0}" = 0 ] || return 1 ;;
    *' -L '*) case " $* " in *' -n '*) ;; *) return 3 ;; esac ;;
    esac
    [ "${FAIL:-}" != "$family $*" ]
)
magicnet_iptables_cmd() { mock_xtables iptables "$@"; }
magicnet_ip6tables_cmd() { mock_xtables ip6tables "$@"; }
magicnet_enable_dns_capture
'''


def evaluate(rules, proto, port, uid, mark):
    """Small model of only the match/RETURN/REDIRECT subset emitted here."""
    owners = 0
    for visited, rule in enumerate(rules, 1):
        if "-p" in rule and rule[rule.index("-p") + 1] != proto:
            continue
        if "--dport" in rule:
            at = rule.index("--dport")
            matches = port == int(rule[at + 1])
            if rule[at - 1] == "!":
                matches = not matches
            if not matches:
                continue
        if "--mark" in rule:
            value, mask = map(int, rule[rule.index("--mark") + 1].split("/"))
            if mark & mask != value:
                continue
        if "--uid-owner" in rule:
            owners += 1
            if uid != int(rule[rule.index("--uid-owner") + 1]):
                continue
        target = rule[rule.index("-j") + 1]
        if target == "REDIRECT":
            target += ":" + rule[rule.index("--to-ports") + 1]
        return target, visited, owners
    return "RETURN", len(rules), owners


class DNSCaptureFastPath(unittest.TestCase):
    def run_installer(self, shell, count=32, **overrides):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            policy = directory / ".state/app-policy"
            policy.mkdir(parents=True)
            (policy / "exclude-uids.list").write_text(
                "0\n" + "".join(f"{10001 + i}\n" for i in range(count)))
            calls = directory / "calls"
            calls.touch()
            env = dict(os.environ, MODDIR=tmp, CALLS=str(calls),
                       NETWORK_SOURCE=str(ROOT / "src/MagicNet/lib/magicnet/network.sh"),
                       MAGIC_DNS_CAPTURE="1", MAGIC_DNS_CAPTURE_PORT="1053")
            env.update(overrides)
            result = subprocess.run(shell + ["-c", FIXTURE], env=env,
                                    capture_output=True, text=True, timeout=30)
            return result, [shlex.split(line) for line in calls.read_text().splitlines()]

    def test_rules_preserve_dns_and_bound_non_dns_work(self):
        for shell, count, marked in itertools.product(SHELLS, (0, 32, 256), ("0", "1")):
            with self.subTest(shell=shell, uids=count, marked=marked):
                result, calls = self.run_installer(shell, count, MARKED=marked)
                self.assertEqual(result.returncode, 0, result.stderr)
                for family in ("iptables", "ip6tables"):
                    rules = [c[5:] for c in calls if c[:5] ==
                             [family, "-t", "nat", "-A", "magicnet-dns-output"]]
                    expected = [["-p", p, "!", "--dport", "53", "-j", "RETURN"]
                                for p in ("tcp", "udp")]
                    self.assertEqual(rules[:2], expected)
                    for proto, port, uid, mark in itertools.product(
                            ("tcp", "udp", "icmp"), (53, 80, 443, 853),
                            (0, 10001, 10032, 65534), (0, 128, 129)):
                        verdict, visited, owners = evaluate(rules, proto, port, uid, mark)
                        self.assertEqual(verdict, evaluate(rules[2:], proto, port, uid, mark)[0])
                        if proto in ("tcp", "udp") and port != 53:
                            self.assertLessEqual(visited, 2)
                            self.assertEqual(owners, 0)
                        if proto in ("tcp", "udp") and port == 53 and uid == 0 and mark == 0:
                            self.assertEqual(verdict, "REDIRECT:1053")

    def test_install_failure_attempts_cleanup_for_both_families(self):
        for shell, family, proto in itertools.product(SHELLS, ("iptables", "ip6tables"), ("tcp", "udp")):
            with self.subTest(shell=shell, family=family, proto=proto):
                failed = f"{family} -t nat -A magicnet-dns-output -p {proto} ! --dport 53 -j RETURN"
                result, calls = self.run_installer(shell, FAIL=failed)
                self.assertNotEqual(result.returncode, 0)
                for cleanup_family in ("iptables", "ip6tables"):
                    self.assertIn([cleanup_family, "-t", "nat", "-X", "magicnet-dns-output"], calls)

    def test_ebpf_disabled_and_udp_profile_do_not_install_capture(self):
        for shell, options in itertools.product(SHELLS, (
                {"MODE": "ebpf"}, {"MAGIC_DNS_CAPTURE": "0"}, {"PROFILE": "cloudflare-udp"})):
            result, calls = self.run_installer(shell, **options)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(any("-A" in call or "-I" in call for call in calls))

    def test_ipv4_only_does_not_install_ipv6_capture(self):
        for shell in SHELLS:
            result, calls = self.run_installer(shell, IPV6_MODE="ipv4_only")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(any(call[0] == "ip6tables" for call in calls))

    def test_existing_chains_are_inspected_numerically(self):
        for shell in SHELLS:
            result, calls = self.run_installer(shell, EXISTING="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(any("-L" in call and "magicnet-dns-output" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
