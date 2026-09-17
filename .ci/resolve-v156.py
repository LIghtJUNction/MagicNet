from pathlib import Path
import subprocess
repo=Path.cwd()
for name in ('fake-magisk-kernel.py','fake-magisk-smoke.sh','test-fake-magisk-kernel.py'):
    (repo/'scripts'/name).write_bytes(subprocess.check_output(['git','show','10a7f46024368091338dcf26768fb41d936f5c39:scripts/'+name]))
p=repo/'scripts/fake-magisk-kernel.py';s=p.read_text()
s=s.replace('import sys\n','import sys\n\nCHAIN = "magicnet-dns-output"\nFOREIGN = ["-o", "lo", "-p", "udp", "--dport", "53", "-j", "REJECT"]\n')
s=s.replace('    action, *rest = args\n','    if not args:\n        raise ValueError("missing xtables operation")\n    action, *rest = args\n')
s=s.replace('    if args[:1] == ["-6"]:\n        family, args = "6", args[1:]','    if args[:1] in (["-4"], ["-6"]):\n        family, args = args[0][1:], args[1:]')
s=s.replace('    if args[:2] == ["route", "show"]:\n','    if args[:3] == ["link", "show", "dev"] and len(args) == 4:\n        name = args[3]\n        if name in ("lo", "ap0", "wlan0", "tun0") or (name == "magicnet0" and tun):\n            print(f"8: {name}: <UP> mtu 1500 state UNKNOWN")\n            return 0\n        return 1\n    if args[:2] == ["route", "show"]:\n        if "dev" in args and args[-1] in ("ap0", "wlan0"):\n            name = args[-1]\n            print(f"192.168.43.0/24 dev {name} proto kernel scope link src 192.168.43.1")\n            return 0\n')
s=s.replace('def main(args):\n    with locked_state() as state:\n        command, *args = args\n', 'def dispatch(state, command, args):\n')
start=s.index('def dispatch(');end=s.index('\n\nif __name__',start)
part=s[start:end];lines=part.splitlines();lines=[lines[0]]+[line[4:] if line.startswith('    ') else line for line in lines[1:]]
s=s[:start]+'\n'.join(lines)+s[end:]
s=s.replace('            guard = ["-o", "lo", "-p", "udp", "--dport", "53", "-j", "REJECT"]','            guard = ["-o", "lo", "-p", "udp", "--dport", "53", "-m", "comment", "--comment", "magicnet-dns-guard", "-j", "REJECT"]')
anchor='    if command == "reset":\n'
s=s.replace(anchor,'''    if command == "seed-foreign":
        for family in ("iptables", "ip6tables"):
            output = state["tables"][family]["filter"]["OUTPUT"]
            if FOREIGN not in output:
                output.append(FOREIGN.copy())
        return 0
    if command == "assert-clean":
        for family in ("iptables", "ip6tables"):
            tables = state["tables"][family]
            if CHAIN in tables["nat"] or any(CHAIN in r for rules in tables["nat"].values() for r in rules):
                raise ValueError("owned DNS state was not cleaned")
            if tables["filter"]["OUTPUT"] != [FOREIGN]:
                raise ValueError("foreign filter rule was changed or owned guard remains")
        return 0
'''+anchor)
s=s.replace('\n\nif __name__', '\n\ndef main(args):\n    command, *args = args\n    with locked_state() as state:\n        return dispatch(state, command, args)\n\n\nif __name__')
p.write_text(s)
p=repo/'scripts/fake-magisk-smoke.sh';s=p.read_text()
s=s.replace('export MAGICNET_FAKE_KERNEL="$ROOT/scripts/fake-magisk-kernel.py"','export MAGICNET_FAKE_KERNEL="$ROOT/scripts/fake-magisk-kernel.py"\ntest -f "$MAGICNET_FAKE_KERNEL"')
s=s.replace('awk basename bash cat chmod cksum cp cut', 'awk basename bash cat chmod cksum cmp cp cut')
s=s.replace('    # This is the pre-upgrade ownership record for the unlabelled rule.\n    printf \'%s\\n\' lo >"$MODDIR/.state/dns-leak-guard.ifaces"','    # Keep a separately seeded unlabelled foreign rule outside this ledger.\n    printf \'%s\\n\' lo \'# magicnet-owned-v2\' \'# families=4,6\' >"$MODDIR/.state/dns-leak-guard.ifaces"')
s=s.replace("    rg -q '^iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT$' \"$log_file\"", "    rg -q '^iptables -D OUTPUT -o lo -p udp --dport 53 -m comment --comment magicnet-dns-guard -j REJECT$' \"$log_file\"\n    if rg -q '^iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT$' \"$log_file\"; then\n        echo 'cleanup attempted to remove a foreign DNS reject' >&2\n        return 1\n    fi\n    \"$MAGICNET_FAKE_PYTHON\" -S \"$MAGICNET_FAKE_KERNEL\" assert-clean")
s=s.replace('export MAGICNET_TEST_PATH="$PATH"','export MAGICNET_TEST_PATH="$PATH"\n"$MAGICNET_FAKE_PYTHON" -S "$MAGICNET_FAKE_KERNEL" seed-foreign')
s=s.replace('line == "iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT"','line == "iptables -D OUTPUT -o lo -p udp --dport 53 -m comment --comment magicnet-dns-guard -j REJECT"')
s=s.replace('    raise SystemExit("kernel bootstrap did not clear DNS interception before starting sing-box")','    raise SystemExit("kernel bootstrap did not clear DNS interception before starting sing-box")\nif "iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT" in lines:\n    raise SystemExit("kernel bootstrap attempted to remove a foreign DNS reject")')
p.write_text(s)
p=repo/'scripts/test-fake-magisk-kernel.py';s=p.read_text();s=s.replace('import contextlib\n','import contextlib\nimport copy\n');s=s.replace('import unittest\n','import unittest\nfrom unittest.mock import patch\n')
new='''

class ReleaseKernelFixtureTests(unittest.TestCase):
    def call(self, state, program, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            code = kernel.dispatch(state, program, list(args))
        return code, output.getvalue()

    def seeded(self):
        state = kernel.initial()
        self.call(state, "seed-foreign")
        self.call(state, "seed-cleanup")
        return state

    def test_chain_mutations_and_reads_share_state(self):
        state = self.seeded()
        jump = ("OUTPUT", "-j", kernel.CHAIN)
        self.assertEqual(self.call(state, "iptables", "-t", "nat", "-C", *jump)[0], 0)
        self.assertEqual(self.call(state, "iptables", "-t", "nat", "-D", *jump)[0], 0)
        self.assertEqual(self.call(state, "iptables", "-t", "nat", "-C", *jump)[0], 1)
        self.assertEqual(self.call(state, "iptables", "-t", "nat", "-F", kernel.CHAIN)[0], 0)
        self.assertEqual(self.call(state, "iptables", "-t", "nat", "-X", kernel.CHAIN)[0], 0)
        self.assertEqual(self.call(state, "iptables", "-t", "nat", "-S", kernel.CHAIN)[0], 1)
        self.assertIn(kernel.FOREIGN, state["tables"]["iptables"]["filter"]["OUTPUT"])

    def test_injected_delete_failure_preserves_evidence(self):
        state = self.seeded()
        before = copy.deepcopy(state)
        with patch.dict(os.environ, MAGICNET_FAKE_XTABLES_DELETE_FAIL="1"):
            self.assertEqual(self.call(state, "iptables", "-t", "nat", "-D", "OUTPUT", "-j", kernel.CHAIN)[0], 4)
        self.assertEqual(state, before)

    def test_missing_or_wrong_core_does_not_invent_interface_or_route(self):
        state = kernel.initial()
        for core in (None, {"pid": 2147483647, "mode": "tun"}, {"pid": os.getpid(), "mode": "ebpf"}):
            state["core"] = core
            self.assertEqual(self.call(state, "ip", "link", "show", "dev", "magicnet0")[0], 1)
            self.assertEqual(self.call(state, "ip", "route", "show", "table", "2022"), (0, ""))
        state["core"] = {"pid": os.getpid(), "mode": "tun"}
        self.assertEqual(self.call(state, "ip", "link", "show", "dev", "magicnet0")[0], 0)
        self.assertIn("default dev magicnet0", self.call(state, "ip", "route", "show", "table", "2022")[1])

    def test_policy_rule_round_trip_preserves_foreign(self):
        state = kernel.initial()
        state["rules"]["4"] = ["8888: from all lookup 7777"]
        args = ("priority", "9000", "from", "all", "lookup", "2022")
        self.assertEqual(self.call(state, "ip", "rule", "add", *args)[0], 0)
        self.assertIn("9000: from all lookup 2022", self.call(state, "ip", "rule", "show")[1])
        self.assertEqual(self.call(state, "ip", "rule", "del", *args)[0], 0)
        self.assertEqual(state["rules"]["4"], ["8888: from all lookup 7777"])
        self.assertNotEqual(self.call(state, "ip", "rule", "del", *args)[0], 0)

    def test_unknown_mutations_cannot_succeed(self):
        state = kernel.initial()
        before = copy.deepcopy(state)
        for program, args in (("ip", ("route", "flush", "table", "2022")),
                              ("ip", ("invented", "write")),
                              ("iptables", ("-t", "nat", "-invented", "OUTPUT"))):
            with self.assertRaises(ValueError):
                self.call(state, program, *args)
        self.assertEqual(state, before)

    def test_clean_assertion_requires_foreign_preservation_and_owned_absence(self):
        state = self.seeded()
        with self.assertRaises(ValueError):
            self.call(state, "assert-clean")
        for family in ("iptables", "ip6tables"):
            state["tables"][family]["nat"]["OUTPUT"] = []
            del state["tables"][family]["nat"][kernel.CHAIN]
            state["tables"][family]["filter"]["OUTPUT"] = [kernel.FOREIGN.copy()]
        self.assertEqual(self.call(state, "assert-clean")[0], 0)
        state["tables"]["iptables"]["filter"]["OUTPUT"] = []
        with self.assertRaises(ValueError):
            self.call(state, "assert-clean")
'''
s=s.replace('\n\nif __name__',new+'\n\nif __name__');p.write_text(s)
