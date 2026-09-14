#!/usr/bin/env python3
"""Stateful firewall regressions; runs production shell, never the host firewall."""
import json
import os
from pathlib import Path
import sys


def xtables():
    """Persist chain order/membership across the installer's shell subprocesses."""
    family, *args = sys.argv[2:]
    path = Path(os.environ["XT_STATE"])
    state = json.loads(path.read_text())
    with open(os.environ["XT_CALLS"], "a", encoding="utf-8") as output:
        output.write(json.dumps([family] + args) + "\n")
    fail = json.loads(os.environ.get("XT_FAIL", "[]"))
    if fail and [family] + args == fail:
        print("injected permission/lock failure", file=sys.stderr)
        return int(os.environ.get("XT_FAIL_RC", "3"))
    if family == "ip6tables" and os.environ.get("NAT6") == "absent":
        print("Table does not exist", file=sys.stderr)
        return 3
    if args[:2] != ["-t", "nat"]:
        raise AssertionError(f"unexpected table: {args}")
    op, *args = args[2:]
    chains = state[family]
    chain = args[0] if args and args[0] != "-n" else None
    if op == "-L":
        assert "-n" in args, "never resolve names while diagnosing DNS"
        return 0 if chain is None or chain in chains else 1
    if op == "-S":
        if chain not in chains:
            return 1
        print(f"-P {chain} ACCEPT" if chain == "OUTPUT" else f"-N {chain}")
        for rule in chains[chain]:
            print(" ".join(["-A", chain] + rule))
        return 0
    if op == "-N":
        if chain in chains:
            return 1
        chains[chain] = []
    else:
        if chain not in chains:
            return 1
        rule = args[1:]
        if op == "-C":
            return 0 if rule in chains[chain] else 1
        if op == "-D":
            if rule not in chains[chain]:
                return 1
            chains[chain].remove(rule)
        elif op == "-A":
            chains[chain].append(rule)
        elif op == "-I":
            assert not rule[0].isdigit(), "fixture expects implicit position one"
            chains[chain].insert(0, rule)
        elif op == "-F":
            chains[chain] = []
        elif op == "-X":
            if chains[chain] or any(
                    "-j" in r and r[r.index("-j") + 1] == chain
                    for rules in chains.values() for r in rules):
                return 1
            del chains[chain]
        else:
            raise AssertionError(f"unsupported operation: {op}")
    path.write_text(json.dumps(state))
    return 0


if __name__ == "__main__" and sys.argv[1:2] == ["--xtables"]:
    sys.exit(xtables())

import copy
import itertools
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
NETWORK = os.environ.get("NETWORK_SOURCE", str(ROOT / "src/MagicNet/lib/magicnet/network.sh"))
CORE = str(ROOT / "src/MagicNet/lib/magicnet/core.sh")
SHELLS = [["sh"], ["bash"]] + ([["busybox", "ash"]] if shutil.which("busybox") else [])
JUMP = ["-j", "magicnet-dns-output"]
SING = ["-j", "sing-box-output"]
VENDOR = ["-j", "vendor-output"]
FIXTURE = r'''
set -eu
. "$NETWORK_SOURCE"
. "$CORE_SOURCE"
magicnet_cmd_exists() { return 0; }
magicnet_transparent_mode() { printf '%s\n' "${MODE:-tun}"; }
magicnet_ipv6_mode() { printf '%s\n' "${IPV6_MODE:-prefer_ipv4}"; }
magicnet_dns_profile() { printf '%s\n' "${PROFILE:-default}"; }
magicnet_dns_capture_singbox_mark() { printf '128\n'; }
magicnet_dns_capture_singbox_udp_marked() { [ "${MARKED:-1}" = 1 ]; }
magicnet_kernel_running() {
    if [ "${LOCKED:-0}" = 1 ]; then return "${AFTER_LOCK_RC:-0}"; fi
    return "${RUNNING_RC:-0}"
}
magicnet_kernel_start_preamble() { :; }
magicnet_with_sub_config_lock() {
    printf 'lock\n' >> "$EVENTS"
    LOCKED=1
    "$@"
}
magicnet_start_kernel() { printf 'restart\n' >> "$EVENTS"; return 91; }
magicnet_require_subscription_or_stop() { return 0; }
magicnet_hotspot_reconcile() { :; }
magicnet_enable_dns_leak_guard() { :; }
magicnet_disable_dns_leak_guard() { :; }
magicnet_warn() { printf '%s\n' "$*" >&2; }
magicnet_log() { :; }
magicnet_iptables_cmd() { "$PYTHON" -S "$MOCK" --xtables iptables "$@"; }
magicnet_ip6tables_cmd() { "$PYTHON" -S "$MOCK" --xtables ip6tables "$@"; }
case "$ACTION" in
install) magicnet_enable_dns_capture ;;
ensure) magicnet_ensure_kernel ;;
stop) magicnet_disable_dns_capture ;;
post-start) magicnet_after_kernel_start_deferred_unlocked ;;
*) exit 92 ;;
esac
'''


def verdict(chains, chain, proto, port, uid, mark=0):
    """Model terminating nat targets and RETURN to the caller (not ACCEPT)."""
    for rule in chains[chain]:
        if "-p" in rule and rule[rule.index("-p") + 1] != proto:
            continue
        if "--dport" in rule:
            at = rule.index("--dport")
            matches = port == int(rule[at + 1])
            if rule[at - 1] == "!":
                matches = not matches
            if not matches:
                continue
        if "--uid-owner" in rule and uid != int(rule[rule.index("--uid-owner") + 1]):
            continue
        if "--mark" in rule:
            value, mask = map(int, rule[rule.index("--mark") + 1].split("/"))
            if mark & mask != value:
                continue
        target = rule[rule.index("-j") + 1]
        if target in chains:
            result = verdict(chains, target, proto, port, uid, mark)
            if result == "RETURN":
                continue
            return result
        if target == "REDIRECT":
            return target + ":" + rule[rule.index("--to-ports") + 1]
        return target
    return "RETURN"


class DNSCaptureOrder(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        policy = root / ".state/app-policy"
        policy.mkdir(parents=True)
        (policy / "exclude-uids.list").write_text("0\n12000\n")
        self.statefile, self.callsfile = root / "state.json", root / "calls.jsonl"
        self.events = root / "events"
        self.env = dict(os.environ, NETWORK_SOURCE=NETWORK, CORE_SOURCE=CORE,
                        MODDIR=str(root), XT_STATE=str(self.statefile),
                        XT_CALLS=str(self.callsfile), EVENTS=str(self.events),
                        MOCK=str(Path(__file__).resolve()), PYTHON=sys.executable,
                        MAGIC_DNS_CAPTURE="1", MAGIC_DNS_CAPTURE_PORT="1053",
                        MAGICNET_START_NETWORK_DELAY="0", MAGICNET_START_NETWORK_ATTEMPTS="2")
        self.reset()

    def reset(self):
        chains = {"OUTPUT": [SING, VENDOR], "vendor-output": [["-j", "RETURN"]],
                  "sing-box-output": [["-p", "udp", "--dport", "53", "-j", "DNAT"],
                                      ["-p", "tcp", "-j", "REDIRECT", "--to-ports", "42791"]]}
        self.statefile.write_text(json.dumps({f: copy.deepcopy(chains) for f in ("iptables", "ip6tables")}))
        self.callsfile.write_text("")
        self.events.write_text("")

    def state(self):
        return json.loads(self.statefile.read_text())

    def mutate(self, change):
        state = self.state()
        for chains in state.values():
            change(chains)
        self.statefile.write_text(json.dumps(state))

    def run_action(self, action="install", shell=None, **env):
        result = subprocess.run((shell or ["sh"]) + ["-c", FIXTURE],
                                env=dict(self.env, ACTION=action, **env),
                                capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in self.callsfile.read_text().splitlines()]
        self.callsfile.write_text("")
        return result, calls

    def assert_dns(self):
        for family, chains in self.state().items():
            self.assertEqual(chains["OUTPUT"][0], JUMP, family)
            self.assertEqual(chains["OUTPUT"].count(JUMP), 1)
            for proto, uid in itertools.product(("udp", "tcp"), (0, 1000, 1051, 10093, 10109, 10335, 11000)):
                self.assertEqual(verdict(chains, "OUTPUT", proto, 53, uid), "REDIRECT:1053", (family, proto, uid))
            for port in (80, 443, 853, 5228):
                self.assertEqual(verdict(chains, "OUTPUT", "tcp", port, 10109), "REDIRECT:42791")
            for uid, mark in ((12000, 0), (0, 128)):
                self.assertEqual(verdict(chains, "magicnet-dns-output", "udp", 53, uid, mark), "RETURN")
            self.assertEqual(chains["OUTPUT"][1:], [SING, VENDOR])

    def test_fresh_and_reapply_after_singbox_restart(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.reset()
                result, calls = self.run_action(shell=shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_dns()
                self.mutate(lambda c: c["OUTPUT"].insert(0, c["OUTPUT"].pop(1)))
                self.assertEqual(verdict(self.state()["iptables"], "OUTPUT", "udp", 53, 10109), "DNAT")
                result, calls = self.run_action(shell=shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_dns()
                for family in ("iptables", "ip6tables"):
                    attach = [family, "-t", "nat", "-I", "OUTPUT"] + JUMP
                    tcp = [family, "-t", "nat", "-A", "magicnet-dns-output", "-p", "tcp", "--dport", "53", "-j", "REDIRECT", "--to-ports", "1053"]
                    self.assertLess(calls.index(tcp), calls.index(attach))

    def test_watchdog_repairs_drift_without_rebuilding_or_restarting(self):
        self.assertEqual(self.run_action()[0].returncode, 0)
        self.mutate(lambda c: c["OUTPUT"].insert(0, c["OUTPUT"].pop(1)))
        result, calls = self.run_action("ensure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_dns()
        self.assertEqual(self.events.read_text(), "lock\n")
        self.assertFalse(any("-F" in c or "-N" in c or "-X" in c for c in calls))

    def test_healthy_watchdog_is_read_only(self):
        self.assertEqual(self.run_action()[0].returncode, 0)
        before = self.state()
        result, calls = self.run_action("ensure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state(), before)
        self.assertEqual(self.events.read_text(), "")
        self.assertTrue(all(c[3] in ("-L", "-C", "-S") for c in calls))

    def test_duplicates_and_emergency_rules_are_retired(self):
        self.assertEqual(self.run_action()[0].returncode, 0)
        def duplicates(c):
            c["OUTPUT"] += [JUMP, JUMP]
            for p in ("udp", "tcp"):
                c["OUTPUT"].insert(0, ["-p", p, "--dport", "53"] + JUMP)
        self.mutate(duplicates)
        self.assertEqual(self.run_action()[0].returncode, 0)
        self.assert_dns()
        self.mutate(duplicates)
        result, calls = self.run_action("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        for chains in self.state().values():
            self.assertNotIn("magicnet-dns-output", chains)
            self.assertEqual(chains["OUTPUT"], [SING, VENDOR])
        self.assertFalse(any(c[3:5] == ["-F", "OUTPUT"] for c in calls))

    def test_partial_rule_install_never_publishes_jump(self):
        for family in ("iptables", "ip6tables"):
            self.reset()
            fail = [family, "-t", "nat", "-A", "magicnet-dns-output", "-p", "tcp", "--dport", "53", "-j", "REDIRECT", "--to-ports", "1053"]
            result, calls = self.run_action(XT_FAIL=json.dumps(fail))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(c[3:5] == ["-I", "OUTPUT"] for c in calls))
            for chains in self.state().values():
                self.assertNotIn("magicnet-dns-output", chains)
                self.assertEqual(chains["OUTPUT"], [SING, VENDOR])

    def test_order_probe_and_write_errors_are_not_healthy(self):
        for op, tail, rc in (("-S", [], "3"), ("-S", [], "124"), ("-D", JUMP, "3"), ("-I", JUMP, "3")):
            with self.subTest(op=op, rc=rc):
                self.reset()
                self.assertEqual(self.run_action()[0].returncode, 0)
                self.mutate(lambda c: c["OUTPUT"].insert(0, c["OUTPUT"].pop(1)))
                fail = ["iptables", "-t", "nat", op, "OUTPUT"] + tail
                result, _ = self.run_action("ensure", XT_FAIL=json.dumps(fail), XT_FAIL_RC=rc)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("restart", self.events.read_text())

    def test_missing_rules_are_rebuilt(self):
        self.assertEqual(self.run_action("ensure")[0].returncode, 0)
        self.assert_dns()
        self.mutate(lambda c: c["magicnet-dns-output"].pop())
        self.assertEqual(self.run_action("ensure")[0].returncode, 0)
        self.assert_dns()

    def test_stop_race_does_not_reinstall(self):
        for rc in ("1", "2"):
            result, calls = self.run_action("ensure", AFTER_LOCK_RC=rc)
            self.assertEqual(result.returncode, int(rc), result.stderr)
            self.assertTrue(all(c[3] in ("-L", "-C", "-S") for c in calls))

    def test_disabled_ebpf_and_udp_profile_keep_their_dns_owner(self):
        for env in ({"MODE": "ebpf"}, {"MAGIC_DNS_CAPTURE": "0"}, {"PROFILE": "cloudflare-udp"}):
            result, calls = self.run_action("ensure", **env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, [])

    def test_ipv6_nat_absence_and_ipv4_only(self):
        for mode in ("prefer_ipv4", "ipv4_only"):
            self.reset()
            result, calls = self.run_action(IPV6_MODE=mode, NAT6="absent")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.state()["iptables"]["OUTPUT"][0], JUMP)
            if mode == "ipv4_only":
                self.assertFalse(any(c[0] == "ip6tables" for c in calls))
        self.reset()
        result, _ = self.run_action(IPV6_MODE="prefer_ipv6", NAT6="absent")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state()["iptables"]["OUTPUT"], [SING, VENDOR])

    def test_post_start_and_stop_start_lifecycle(self):
        self.assertEqual(self.run_action("post-start")[0].returncode, 0)
        self.assert_dns()
        self.assertEqual(self.run_action("stop")[0].returncode, 0)
        self.assertEqual(self.run_action("post-start")[0].returncode, 0)
        self.assert_dns()


if __name__ == "__main__":
    unittest.main()
