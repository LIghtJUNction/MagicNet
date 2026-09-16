#!/usr/bin/env python3
"""Stateful regressions for the real installer; never modify the host firewall."""
import copy
import itertools
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
NETWORK = ROOT / "src/MagicNet/lib/magicnet/network.sh"
CHAIN = "magicnet-dns-output"
JUMP = ["-j", CHAIN]
SHELLS = [["sh"], ["bash"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "ash"])
FIXTURE = r'''
set -eu
. "$NETWORK_SOURCE"
magicnet_cmd_exists() { return 0; }
magicnet_xtables_table_probe() {
    case "$1:${IPV6_NAT:-yes}" in
        ip6tables:no) return 2 ;;
        ip6tables:denied) return 1 ;;
    esac
    return 0
}
magicnet_transparent_mode() { printf '%s\n' "${MODE:-tun}"; }
magicnet_ipv6_mode() { printf '%s\n' "${IPV6_MODE:-prefer_ipv4}"; }
magicnet_dns_profile() { printf '%s\n' "${PROFILE:-default}"; }
magicnet_dns_capture_singbox_mark() { printf '128\n'; }
magicnet_dns_capture_singbox_udp_marked() { [ "${MARKED:-1}" = 1 ]; }
magicnet_warn() { printf '%s\n' "$*" >&2; }
magicnet_log() { printf '%s\n' "$*"; }
magicnet_iptables_cmd() { "$PYTHON" -S "$MOCK" --xtables iptables "$@"; }
magicnet_ip6tables_cmd() { "$PYTHON" -S "$MOCK" --xtables ip6tables "$@"; }
magicnet_hotspot_reconcile() { :; }
magicnet_enable_dns_leak_guard() { :; }
magicnet_disable_dns_leak_guard() { :; }
case "${ACTION:-enable}" in
    enable) magicnet_enable_dns_capture ;;
    disable) magicnet_disable_dns_capture ;;
    post-start) magicnet_after_kernel_start_deferred_unlocked ;;
esac
'''


def xtables(args):
    """Persist -C/-D/-I/-A semantics across shell command substitutions."""
    state_file = Path(os.environ["XTABLES_STATE"])
    state = json.loads(state_file.read_text())
    state["calls"].append(args)
    state_file.write_text(json.dumps(state))
    if shlex.join(args) == os.environ.get("FAIL", ""):
        print("injected xtables failure", file=sys.stderr)
        return int(os.environ.get("FAIL_RC", "4"))
    family, table_flag, table, action, *rest = args
    assert table_flag == "-t" and table == "nat", args
    chains = state[family]
    name = rest[0] if rest and rest[0] != "-n" else None
    if action == "-L":
        return 0 if name is None or name in chains else 1
    if action == "-S":
        if name not in chains:
            return 1
        print("-P OUTPUT ACCEPT")
        for rule in chains[name]:
            print(shlex.join(["-A", name] + rule))
        return 0
    if action == "-N":
        if name in chains:
            return 1
        chains[name] = []
    elif name not in chains:
        return 1
    elif action == "-F":
        chains[name] = []
    elif action == "-X":
        if chains[name] or any(name in rule for rules in chains.values() for rule in rules):
            return 1
        del chains[name]
    else:
        rule = rest[1:]
        if action == "-C":
            return 0 if rule in chains[name] else 1
        if action == "-D":
            if rule not in chains[name]:
                return 1
            chains[name].remove(rule)
        elif action == "-A":
            chains[name].append(rule)
        elif action == "-I":
            pos = int(rule.pop(0)) - 1 if rule and rule[0].isdigit() else 0
            chains[name].insert(pos, rule)
        else:
            raise AssertionError(args)
    state_file.write_text(json.dumps(state))
    return 0


def packet(chains, proto="udp", port=53, uid=0, mark=0, chain="OUTPUT"):
    """Follow jumps and RETURN; DNAT/REDIRECT terminate NAT traversal."""
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
            value, mask = (int(v, 0) for v in rule[rule.index("--mark") + 1].split("/"))
            if mark & mask != value:
                continue
        target = rule[rule.index("-j") + 1]
        if target in chains:
            result = packet(chains, proto, port, uid, mark, target)
            if result == "RETURN":
                continue
            return result
        if target == "REDIRECT":
            return "REDIRECT:" + rule[rule.index("--to-ports") + 1]
        if target == "DNAT":
            return "DNAT:" + rule[rule.index("--to-destination") + 1]
        return target
    return "RETURN"


def initial(stale=True, duplicates=1, temporary=False):
    chains = {
        "OUTPUT": [["-j", "sing-box-output"], ["-j", "vendor-output"]],
        "sing-box-output": [["-p", "udp", "--dport", "53", "-j", "DNAT",
                             "--to-destination", "172.19.0.2"]],
        "vendor-output": [],
    }
    if stale:
        chains[CHAIN] = [["-p", p, "--dport", "53", "-j", "REDIRECT", "--to-ports", "1053"]
                         for p in ("udp", "tcp")]
        chains["OUTPUT"].extend(copy.deepcopy(JUMP) for _ in range(duplicates))
        if temporary:
            chains["OUTPUT"].extend(["-p", p, "--dport", "53"] + JUMP for p in ("udp", "tcp"))
    return {"iptables": chains, "ip6tables": copy.deepcopy(chains), "calls": []}


class DNSOutputOrder(unittest.TestCase):
    def run_installer(self, state, shell, **overrides):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            policy = directory / ".state/app-policy"
            policy.mkdir(parents=True)
            (policy / "exclude-uids.list").write_text("0\n10328\n10328\ninvalid\n")
            state_file = directory / "xtables.json"
            state_file.write_text(json.dumps(state))
            env = dict(os.environ, MODDIR=tmp, PYTHON=sys.executable, MOCK=str(Path(__file__).resolve()),
                       XTABLES_STATE=str(state_file), NETWORK_SOURCE=os.environ.get("NETWORK_SOURCE", str(NETWORK)),
                       MAGIC_DNS_CAPTURE="1", MAGIC_DNS_CAPTURE_PORT="1053",
                       MAGICNET_START_NETWORK_ATTEMPTS="2", MAGICNET_START_NETWORK_DELAY="0")
            env.update(overrides)
            result = subprocess.run(shell + ["-c", FIXTURE], env=env,
                                    capture_output=True, text=True, timeout=30)
            return result, json.loads(state_file.read_text())

    def assert_captured(self, state, families=("iptables", "ip6tables"), port="1053"):
        for family in families:
            self.assertEqual(state[family]["OUTPUT"][0], JUMP)
            self.assertEqual(sum(CHAIN in r for r in state[family]["OUTPUT"]), 1)
            for proto, uid in itertools.product(("udp", "tcp"), (0, 10093, 10109, 10555)):
                self.assertEqual(packet(state[family], proto=proto, uid=uid), "REDIRECT:" + port)
            self.assertEqual([r for r in state[family]["OUTPUT"] if CHAIN not in r],
                             [["-j", "sing-box-output"], ["-j", "vendor-output"]])

    def test_fresh_and_existing_jump_precede_competing_dnat(self):
        for shell, stale in itertools.product(SHELLS, (False, True)):
            with self.subTest(shell=shell, stale=stale):
                state = initial(stale)
                self.assertEqual(packet(state["iptables"]), "DNAT:172.19.0.2")
                result, state = self.run_installer(state, shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_captured(state)

    def test_ipv4_only_removes_old_ipv6_capture_without_rewriting_ipv4(self):
        result, state = self.run_installer(initial(), ["sh"])
        self.assertEqual(result.returncode, 0, result.stderr)
        state["calls"] = []
        result, final = self.run_installer(state, ["sh"], IPV6_MODE="ipv4_only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(CHAIN, final["ip6tables"])
        for call in final["calls"]:
            if call[0] == "iptables":
                self.assertNotIn(call[3], ("-A", "-D", "-I", "-N", "-F", "-X"), call)
        self.assert_captured(final, families=("iptables",))

    def test_unchanged_recipe_makes_no_firewall_writes(self):
        result, state = self.run_installer(initial(), ["sh"])
        self.assertEqual(result.returncode, 0, result.stderr)
        state["calls"] = []
        result, final = self.run_installer(state, ["sh"])
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in final["calls"]:
            self.assertNotIn(call[3], ("-A", "-D", "-I", "-N", "-F", "-X"), call)
        self.assert_captured(final)

    def test_reapply_repairs_core_reordering_without_duplicates(self):
        for shell in SHELLS:
            result, state = self.run_installer(initial(duplicates=3), shell)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_captured(state)
            for family in ("iptables", "ip6tables"):
                state[family]["OUTPUT"].remove(["-j", "sing-box-output"])
                state[family]["OUTPUT"].insert(0, ["-j", "sing-box-output"])
            result, state = self.run_installer(state, shell, ACTION="post-start")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_captured(state)
            result, again = self.run_installer(state, shell)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(state["iptables"], again["iptables"])
            self.assertEqual(state["ip6tables"], again["ip6tables"])

    def test_cloudflare_udp_profile_repairs_core_reordering(self):
        for shell in SHELLS:
            result, state = self.run_installer(initial(), shell, PROFILE="cloudflare-udp", MARKED="0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_captured(state)
            for family in ("iptables", "ip6tables"):
                state[family]["OUTPUT"].remove(["-j", "sing-box-output"])
                state[family]["OUTPUT"].insert(0, ["-j", "sing-box-output"])
                self.assertEqual(packet(state[family]), "DNAT:172.19.0.2")
            result, state = self.run_installer(
                state, shell, ACTION="post-start", PROFILE="cloudflare-udp", MARKED="0"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_captured(state)

    def test_temporary_jumps_migrate_and_stop_removes_all_owned_rules(self):
        for shell in SHELLS:
            result, state = self.run_installer(initial(duplicates=3, temporary=True), shell)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_captured(state)
            result, state = self.run_installer(state, shell, ACTION="disable")
            self.assertEqual(result.returncode, 0, result.stderr)
            for family in ("iptables", "ip6tables"):
                self.assertNotIn(CHAIN, state[family])
                self.assertFalse(any(CHAIN in r for r in state[family]["OUTPUT"]))
                self.assertEqual(packet(state[family]), "DNAT:172.19.0.2")

    def test_bypass_marks_and_non_dns_keep_original_policy(self):
        for shell in SHELLS:
            result, state = self.run_installer(initial(), shell, MAGIC_DNS_CAPTURE_PORT="1153")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_captured(state, port="1153")
            for family in ("iptables", "ip6tables"):
                for proto in ("udp", "tcp"):
                    for port in (80, 443, 853):
                        self.assertEqual(packet(state[family], proto, port), "RETURN")
                    self.assertEqual(packet(state[family], proto, uid=10328, chain=CHAIN), "RETURN")
                    self.assertEqual(packet(state[family], proto, mark=128, chain=CHAIN), "RETURN")

    def test_disabled_modes_clean_existing_and_temporary_jumps(self):
        for shell, options in itertools.product(SHELLS, (
                {"MODE": "ebpf"}, {"MAGIC_DNS_CAPTURE": "0"})):
            result, state = self.run_installer(initial(temporary=True), shell, **options)
            self.assertEqual(result.returncode, 0, result.stderr)
            for family in ("iptables", "ip6tables"):
                self.assertNotIn(CHAIN, state[family])
                self.assertFalse(any(CHAIN in r for r in state[family]["OUTPUT"]))

    def test_missing_ipv6_nat_is_not_a_permission_error(self):
        for shell in SHELLS:
            result, state = self.run_installer(initial(False), shell, IPV6_NAT="no")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_captured(state, ("iptables",))
            self.assertNotIn(CHAIN, state["ip6tables"])
            for overrides in ({"IPV6_NAT": "denied"}, {"IPV6_NAT": "no", "IPV6_MODE": "prefer_ipv6"}):
                result, state = self.run_installer(initial(False), shell, **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(CHAIN in r for r in state["iptables"]["OUTPUT"]))

    def test_insertion_or_redirect_failure_cleans_up(self):
        for shell, family in itertools.product(SHELLS, ("iptables", "ip6tables")):
            for args in (["-I", "OUTPUT", "-j", CHAIN],
                         ["-A", CHAIN, "-p", "tcp", "--dport", "53", "-j", "REDIRECT", "--to-ports", "1053"]):
                fail = shlex.join([family, "-t", "nat"] + args)
                result, state = self.run_installer(initial(), shell, FAIL=fail)
                self.assertNotEqual(result.returncode, 0, (fail, result.stdout))
                for cleanup_family in ("iptables", "ip6tables"):
                    self.assertFalse(any(CHAIN in r for r in state[cleanup_family]["OUTPUT"]))
                self.assertNotIn("DNS capture redirected", result.stdout)

    def test_delete_timeout_never_reports_success(self):
        for shell in SHELLS:
            fail = shlex.join(["iptables", "-t", "nat", "-D", "OUTPUT"] + JUMP)
            result, state = self.run_installer(initial(), shell, FAIL=fail, FAIL_RC="124")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("DNS capture redirected", result.stdout)
            self.assertLess(len(state["calls"]), 100)

    def test_capture_jump_is_attached_only_after_both_redirects(self):
        for shell in SHELLS:
            result, state = self.run_installer(initial(False), shell)
            self.assertEqual(result.returncode, 0, result.stderr)
            for family in ("iptables", "ip6tables"):
                calls = state["calls"]
                attach = calls.index([family, "-t", "nat", "-I", "OUTPUT"] + JUMP)
                for proto in ("udp", "tcp"):
                    redirect = calls.index([family, "-t", "nat", "-A", CHAIN, "-p", proto,
                                            "--dport", "53", "-j", "REDIRECT", "--to-ports", "1053"])
                    self.assertLess(redirect, attach)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--xtables":
        sys.exit(xtables(sys.argv[2:]))
    unittest.main()
