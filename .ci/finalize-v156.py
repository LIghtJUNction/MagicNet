from pathlib import Path
p=Path('scripts/fake-magisk-kernel.py');s=p.read_text()
old='''    if action == "-S":
        if name not in chains:
            return 1
        if name in ("INPUT", "OUTPUT", "FORWARD", "PREROUTING", "POSTROUTING"):
            print(f"-P {name} ACCEPT")
        else:
            print(f"-N {name}")
        for rule in chains[name]:
            # xtables does not quote !; comments here are token-only.
            print(" ".join(["-A", name, *rule]))
        return 0
'''
new='''    if action == "-S":
        if name is not None and name not in chains:
            return 1
        for selected in [name] if name is not None else chains:
            if selected in ("INPUT", "OUTPUT", "FORWARD", "PREROUTING", "POSTROUTING"):
                print(f"-P {selected} ACCEPT")
            else:
                print(f"-N {selected}")
            for rule in chains[selected]:
                # xtables does not quote !; comments here are token-only.
                print(" ".join(["-A", selected, *rule]))
        return 0
'''
assert s.count(old)==1;s=s.replace(old,new);p.write_text(s)
p=Path('scripts/test-fake-magisk-kernel.py');s=p.read_text()
anchor='    def test_injected_delete_failure_preserves_evidence(self):\n'
newtest='''    def test_whole_table_snapshot_includes_chain_and_caller_without_writes(self):
        state = self.seeded()
        before = copy.deepcopy(state)
        for family in ("iptables", "ip6tables"):
            code, text = self.call(state, family, "-t", "nat", "-S")
            self.assertEqual(code, 0)
            self.assertIn("-A OUTPUT -j " + kernel.CHAIN, text)
            self.assertIn("-A " + kernel.CHAIN + " -p udp", text)
            self.assertEqual(self.call(state, family, "-t", "nat", "-S", "absent")[0], 1)
        self.assertEqual(state, before)

'''
assert s.count(anchor)==1;s=s.replace(anchor,newtest+anchor);p.write_text(s)
