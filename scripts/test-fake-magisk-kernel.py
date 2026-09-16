#!/usr/bin/env python3
"""Tests for the private fake-Magisk external-facts model, not network acceptance."""
import contextlib
import copy
import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fixture', Path(__file__).with_name('fake-magisk-kernel.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class KernelFixtureTests(unittest.TestCase):
    def call(self, state, program, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            code = fixture.dispatch(state, program, list(args))
        return code, output.getvalue()

    def test_chain_mutations_and_reads_share_state(self):
        state = fixture.initial()
        jump = ('OUTPUT', '-j', fixture.CHAIN)
        self.assertEqual(self.call(state, 'iptables', '-t','nat','-C', *jump)[0], 0)
        self.assertEqual(self.call(state, 'iptables', '-t','nat','-D', *jump)[0], 0)
        self.assertEqual(self.call(state, 'iptables', '-t','nat','-C', *jump)[0], 1)
        self.assertEqual(self.call(state, 'iptables', '-t','nat','-F', fixture.CHAIN)[0], 0)
        self.assertEqual(self.call(state, 'iptables', '-t','nat','-X', fixture.CHAIN)[0], 0)
        self.assertEqual(self.call(state, 'iptables', '-t','nat','-S', fixture.CHAIN)[0], 1)
        self.assertEqual(state['tables']['iptables']['filter']['OUTPUT'], [fixture.FOREIGN])

    def test_injected_delete_failure_preserves_evidence(self):
        state = fixture.initial()
        before = copy.deepcopy(state)
        with patch.dict(os.environ, MAGICNET_FAKE_XTABLES_DELETE_FAIL='1'):
            self.assertEqual(self.call(state, 'iptables', '-t','nat','-D','OUTPUT','-j',fixture.CHAIN)[0], 4)
        self.assertEqual(state, before)

    def test_missing_or_wrong_core_does_not_invent_interface_or_route(self):
        state = fixture.initial()
        for core in (None, {'pid': 2147483647, 'mode':'tun'}, {'pid':os.getpid(),'mode':'ebpf'}):
            state['core'] = core
            self.assertEqual(self.call(state,'ip','link','show','dev','magicnet0')[0], 1)
            self.assertEqual(self.call(state,'ip','route','show','table','2022'), (0,''))
        state['core'] = {'pid':os.getpid(),'mode':'tun'}
        self.assertEqual(self.call(state,'ip','link','show','dev','magicnet0')[0], 0)
        self.assertIn('default dev magicnet0', self.call(state,'ip','route','show','table','2022')[1])

    def test_policy_rule_add_delete_round_trip_preserves_foreign(self):
        state=fixture.initial()
        state['rules']['4']=['8888: from all lookup 7777']
        args=('priority','9000','from','all','lookup','2022')
        self.assertEqual(self.call(state,'ip','rule','add',*args)[0],0)
        self.assertIn('9000: from all lookup 2022',self.call(state,'ip','rule','show')[1])
        self.assertEqual(self.call(state,'ip','rule','del',*args)[0],0)
        self.assertEqual(state['rules']['4'],['8888: from all lookup 7777'])
        self.assertNotEqual(self.call(state,'ip','rule','del',*args)[0],0)

    def test_unknown_mutations_do_not_succeed(self):
        state=fixture.initial()
        before=copy.deepcopy(state)
        for program,args in [('ip',('route','flush','table','2022')),
                             ('ip',('invented','write')),
                             ('iptables',('-t','nat','-invented','OUTPUT'))]:
            self.assertNotEqual(self.call(state,program,*args)[0],0)
        self.assertEqual(state,before)

    def test_clean_state_assertion_rejects_remaining_owned_rules(self):
        state=fixture.initial()
        with self.assertRaises(ValueError):
            self.call(state,'assert-clean')
        for family in ('iptables','ip6tables'):
            state['tables'][family]['nat']['OUTPUT']=[]
            del state['tables'][family]['nat'][fixture.CHAIN]
        self.assertEqual(self.call(state,'assert-clean')[0],0)
        state['tables']['iptables']['filter']['OUTPUT']=[]
        with self.assertRaises(ValueError):
            self.call(state,'assert-clean')


if __name__ == '__main__':
    unittest.main()
