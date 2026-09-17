#!/usr/bin/env python3
"""Contract tests for the stateful smoke-only network model."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).with_name("fake-magisk-kernel.py")
spec = importlib.util.spec_from_file_location("fake_kernel", HELPER)
kernel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kernel)


class KernelFixtureTests(unittest.TestCase):
    def setUp(self):
        self.state = kernel.initial()

    def call(self, family, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return kernel.xtables(self.state, family, list(args))

    def test_rules_are_exact_and_families_independent(self):
        rule = ["OUTPUT", "-o", "lo", "-p", "udp", "--dport", "53", "-j", "REJECT"]
        for family in ("iptables", "ip6tables"):
            self.assertEqual(self.call(family, "-C", *rule), 1)
        self.assertEqual(self.call("iptables", "-A", *rule), 0)
        self.assertEqual(self.call("iptables", "-C", *rule), 0)
        self.assertEqual(self.call("ip6tables", "-C", *rule), 1)
        self.assertEqual(self.call("iptables", "-C", "OUTPUT", "-j", "REJECT"), 1)
        self.assertEqual(self.call("iptables", "-D", *rule), 0)
        self.assertEqual(self.call("iptables", "-C", *rule), 1)

    def test_failed_delete_preserves_rules(self):
        rule = ["OUTPUT", "-j", "ACCEPT"]
        self.call("iptables", "-A", *rule)
        before = json.dumps(self.state, sort_keys=True)
        old = os.environ.get("MAGICNET_FAKE_XTABLES_DELETE_FAIL")
        os.environ["MAGICNET_FAKE_XTABLES_DELETE_FAIL"] = "1"
        try:
            self.assertEqual(self.call("iptables", "-D", *rule), 4)
            self.assertEqual(self.call("iptables", "-C", "OUTPUT", "-j", "DROP"), 1)
        finally:
            if old is None:
                del os.environ["MAGICNET_FAKE_XTABLES_DELETE_FAIL"]
            else:
                os.environ["MAGICNET_FAKE_XTABLES_DELETE_FAIL"] = old
        self.assertEqual(json.dumps(self.state, sort_keys=True), before)

    def test_missing_and_attached_chains_are_not_success(self):
        self.assertNotEqual(self.call("iptables", "-t", "nat", "-F", "owned"), 0)
        self.call("iptables", "-t", "nat", "-N", "owned")
        self.call("iptables", "-t", "nat", "-A", "OUTPUT", "-j", "owned")
        self.assertNotEqual(self.call("iptables", "-t", "nat", "-X", "owned"), 0)
        self.call("iptables", "-t", "nat", "-D", "OUTPUT", "-j", "owned")
        self.assertEqual(self.call("iptables", "-t", "nat", "-X", "owned"), 0)

    def test_generation_is_not_a_pidfile_presence_check(self):
        self.assertTrue(kernel.live({"pid": os.getpid()}))
        self.assertFalse(kernel.live({"pid": os.getpid(), "start": "not-this-generation"}))
        self.assertFalse(kernel.live({"pid": 2147483647}))
        self.assertFalse(kernel.live(None))

    def test_unscoped_flush_and_unknown_command_are_rejected(self):
        with self.assertRaises(ValueError):
            kernel.ip(self.state, ["route", "flush", "table", "2022"])
        with self.assertRaises(ValueError):
            kernel.ip(self.state, ["link", "delete", "wlan0"])

    def test_owning_core_controls_tun_inventory(self):
        self.state["core"] = {"pid": os.getpid(), "mode": "tun"}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(kernel.ip(self.state, ["route", "show", "table", "2022"]), 0)
        self.assertIn("dev magicnet0", output.getvalue())
        self.state["core"]["mode"] = "ebpf"
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            kernel.ip(self.state, ["route", "show", "table", "2022"])
        self.assertEqual(output.getvalue(), "")

    def test_lock_preserves_parallel_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            env = dict(os.environ, MAGICNET_FAKE_NETWORK_STATE=str(Path(temp) / "state.json"))
            procs = [subprocess.Popen([sys.executable, "-S", str(HELPER), "iptables", "-A", "OUTPUT", "-m", "comment", "--comment", f"writer-{i}", "-j", "ACCEPT"], env=env) for i in range(8)]
            for process in procs:
                self.assertEqual(process.wait(timeout=10), 0)
            saved = json.loads(Path(env["MAGICNET_FAKE_NETWORK_STATE"]).read_text())
            self.assertEqual(len(saved["tables"]["iptables"]["filter"]["OUTPUT"]), 8)


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

    def test_whole_table_snapshot_includes_chain_and_caller_without_writes(self):
        state = self.seeded()
        before = copy.deepcopy(state)
        for family in ("iptables", "ip6tables"):
            code, text = self.call(state, family, "-t", "nat", "-S")
            self.assertEqual(code, 0)
            self.assertIn("-A OUTPUT -j " + kernel.CHAIN, text)
            self.assertIn("-A " + kernel.CHAIN + " -p udp", text)
            self.assertEqual(self.call(state, family, "-t", "nat", "-S", "absent")[0], 1)
        self.assertEqual(state, before)

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


if __name__ == "__main__":
    unittest.main()
