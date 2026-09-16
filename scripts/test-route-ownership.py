#!/usr/bin/env python3
"""Execute real route lifecycle helpers against a stateful netlink/firewall fixture.

The fixture rejects blanket flushes, records all kernel writes, and injects
inspection/deletion errors. These are host regressions, not Android acceptance.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = r'''import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
path = root / 'kernel.json'
s = json.loads(path.read_text())
a = sys.argv[1:]
def done(code=0, text=''):
    if text: print(text)
    path.write_text(json.dumps(s))
    raise SystemExit(code)
if a[0] == 'kernel': done(s['kernel'])
if a[0] == 'mode': done(0, s['mode'])
if a[0] == 'iface': done(0 if s.get('iface', True) else 1)
if a[0] == 'enabled': done(0 if s.get('enabled', True) else 1)
if a[0] == 'pairs': done(0, s.get('pairs', 'wlan2|10.1.1.0/24'))
if a[0] == 'iptables':
    a = a[1:]
    op = a[0]; rule = ' '.join(a[1:])
    if op == '-L': done()
    if op == '-S':
        if s.get('fail_scan'): done(2)
        done(0, '\n'.join('-A ' + r for r in s['forward'] if r.startswith(rule + ' ')))
    if op == '-C': done(s.get('fail_check', 0) or (0 if rule in s['forward'] else 1))
    assert op in ('-D', '-I'), a
    s['writes'].append(['iptables'] + a)
    if s.get('fail_' + ('forward_delete' if op == '-D' else 'forward_add')): done(2)
    if op == '-D':
        if rule not in s['forward']: done(1)
        s['forward'].remove(rule)
    else:
        # All hotspot writes must already have a durable write-ahead record.
        if rule.startswith('FORWARD '):
            assert (root / 'module/.state/hotspot/tun-rules.list.pending').is_file()
        else:
            assert (root / 'module/.state/dns-leak-guard.ifaces').is_file()
        if rule not in s['forward']: s['forward'].append(rule)
    done()
assert a.pop(0) == 'ip'
family = '4'
if a[0] == '-6': family = '6'; a.pop(0)
kind, op = a[:2]; a = a[2:]
key = kind + family
if op == 'show':
    if s.get('fail_' + key): done(2, 'netlink permission denied')
    if kind == 'route': assert a == ['table', '2022'], a
    done(0, '\n'.join(s[key]))
s['writes'].append(['ip', family, kind, op] + a)
if kind == 'rule':
    assert a[0] == 'priority', a
    record = a[1] + ': ' + ('from all ' if a[2] == 'iif' else '') + ' '.join(a[2:])
    if op == 'del':
        if s.get('fail_delete'): done(2)
        if record not in s[key]: done(1)
        if not s.get('lie_delete'): s[key].remove(record)
    elif op == 'add':
        assert (root / 'module/.state/hotspot/tun-rules.list.pending').is_file()
        if s.get('fail_add'): done(2)
        record = a[1] + ': from all ' + ' '.join(a[2:])
        s[key].append(record)
    else: raise AssertionError(op)
elif kind == 'route':
    assert op == 'flush' and a == ['table', '2022', 'dev', 'magicnet0'], a
    if s.get('fail_flush'): done(2)
    s[key] = [r for r in s[key] if 'dev magicnet0' not in r.split(' scope ')[0]]
else: raise AssertionError(kind)
done()
'''


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='magicnet-ownership-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mod = self.root / 'module'
        (self.mod / '.state/network').mkdir(parents=True)
        (self.mod / '.state/hotspot').mkdir()
        self.state = self.mod / '.state/network/kernel-route-table.state'
        self.pending = self.mod / '.state/hotspot/tun-rules.list.pending'
        self.hotspot = self.mod / '.state/hotspot/tun-rules.list'
        self.error = self.mod / '.state/transparent-recent-error'
        self.fixture = self.root / 'fixture.py'
        self.fixture.write_text(FIXTURE)
        self.save(dict(kernel=1, mode='tun', rule4=[], rule6=[], route4=[], route6=[], forward=[], writes=[]))
        self.shell = os.environ.get('MAGICNET_TEST_SHELL', 'sh')
        self.prefix = f'''
set -eu
MODDIR={shlex.quote(str(self.mod))}
fixture() {{ {shlex.quote(sys.executable)} -S {shlex.quote(str(self.fixture))} "$@"; }}
ip() {{ fixture ip "$@"; }}
magicnet_kernel_running() {{ fixture kernel; }}
magicnet_transparent_mode() {{ fixture mode; }}
magicnet_iface_exists() {{ fixture iface; }}
magicnet_warn() {{ printf '%s\\n' "$*" >&2; }}
magicnet_refresh_status() {{ :; }}
. {shlex.quote(str(ROOT / 'src/MagicNet/lib/magicnet/routes.sh'))}
. {shlex.quote(str(ROOT / 'src/MagicNet/lib/magicnet/lifecycle.sh'))}
magicnet_iptables_cmd() {{ fixture iptables "$@"; }}
magicnet_iptables_ensure() {{ fixture iptables -I "$@"; }}
magicnet_hotspot_active_networks() {{ fixture pairs; }}
magicnet_hotspot_proxy_enabled() {{ fixture enabled; }}
'''

    def save(self, state):
        (self.root / 'kernel.json').write_text(json.dumps(state))

    def read(self):
        return json.loads((self.root / 'kernel.json').read_text())

    def change(self, **changes):
        value = self.read()
        value.update(changes)
        self.save(value)

    def run_helper(self, code, expected=0):
        cmd = ['busybox', 'sh'] if self.shell == 'busybox' else [self.shell]
        cp = subprocess.run(cmd + ['-c', self.prefix + '\n' + code], text=True, capture_output=True,
                            env=dict(os.environ, FIXTURE_ROOT=str(self.root)), timeout=15)
        self.assertEqual(cp.returncode, expected, cp.stdout + cp.stderr)
        return cp

    def active(self):
        # Keep a foreign rule in the same table across the entire start.
        self.change(rule4=['9002: from 192.0.2.0/24 lookup 2022'])
        self.run_helper('magicnet_kernel_route_state_begin')
        self.change(kernel=0, rule4=self.read()['rule4'] + ['9000: from all fwmark 0x200000 lookup 2022'],
                    route4=['default dev magicnet0 scope link', '10.0.0.0/8 dev wlan0'])
        self.run_helper('magicnet_kernel_route_state_capture')
        self.assertIn('phase=active', self.state.read_text())
        self.assertNotIn('from 192.0.2.0', self.state.read_text())

    def test_baseline_without_kernel_changes_is_read_only(self):
        self.run_helper('magicnet_kernel_route_state_begin')
        self.assertIn('phase=prepared', self.state.read_text())
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.read()['writes'])

    def test_existing_rules_and_foreign_table_routes_survive_stop(self):
        self.active()
        self.change(kernel=1)
        self.run_helper('magicnet_lifecycle_after_stop')
        s = self.read()
        self.assertEqual(s['rule4'], ['9002: from 192.0.2.0/24 lookup 2022'])
        self.assertEqual(s['route4'], ['10.0.0.0/8 dev wlan0'])
        self.assertFalse(self.state.exists())
        before = s['writes'][:]
        self.run_helper('magicnet_lifecycle_after_stop')
        self.assertEqual(self.read()['writes'], before, 'repeated stop must not write kernel state')

    def test_late_rule_is_not_adopted_on_repeated_capture(self):
        self.active()
        late = '9001: from all fwmark 0x400000 lookup 2022'
        self.change(rule4=self.read()['rule4'] + [late])
        ledger = self.state.read_text()
        self.run_helper('magicnet_kernel_route_state_capture')
        self.assertEqual(self.state.read_text(), ledger)
        self.change(kernel=1)
        self.run_helper('magicnet_lifecycle_after_stop')
        self.assertIn(late, self.read()['rule4'])

    def test_ambiguous_same_priority_rule_is_not_deleted_with_wildcard_selectors(self):
        self.active()
        foreign = '9000: from 192.0.2.0/24 fwmark 0x200000 lookup 2022'
        self.change(kernel=1, rule4=[foreign] + self.read()['rule4'])
        self.run_helper('magicnet_lifecycle_after_stop', 2)
        self.assertFalse(self.read()['writes'])
        self.assertTrue(self.state.exists())

    def test_hotspot_ambiguous_source_rule_is_never_deleted(self):
        self.change(rule4=['8999: from 192.0.2.0/24 iif wlan2 lookup 2022',
                           '8999: from all iif wlan2 lookup 2022'])
        self.run_helper('magicnet_hotspot_delete_rule 8999 wlan2', 2)
        self.assertFalse(self.read()['writes'])

    def test_replaced_rule_at_same_priority_is_not_deleted(self):
        self.active()
        replacement = '9000: from all fwmark 0x800000 lookup 2022'
        self.change(kernel=1, rule4=[replacement])
        self.run_helper('magicnet_lifecycle_after_stop')
        self.assertEqual(self.read()['rule4'], [replacement])
        self.assertFalse(any(w[2:4] == ['rule', 'del'] for w in self.read()['writes']))

    def test_running_or_unknown_core_blocks_cleanup_and_preserves_evidence(self):
        self.active()
        for kernel, expected in ((0, 1), (2, 2)):
            self.change(kernel=kernel, writes=[])
            self.run_helper('magicnet_lifecycle_after_stop', expected)
            self.assertTrue(self.state.exists())
            self.assertTrue(self.error.exists())
            self.assertFalse(self.read()['writes'])

    def test_unreadable_rules_or_routes_never_look_clean(self):
        self.active()
        for fault in ('fail_rule4', 'fail_route4', 'fail_rule6', 'fail_route6'):
            if '6' in fault and not Path('/proc/net/if_inet6').exists():
                continue
            self.change(kernel=1, writes=[], **{fault: True})
            self.run_helper('magicnet_lifecycle_after_stop', 2)
            self.assertTrue(self.state.exists())
            self.assertFalse(self.read()['writes'])
            self.change(**{fault: False})

    def test_failed_delete_or_false_success_retains_evidence_for_retry(self):
        self.active()
        for fault in ('fail_delete', 'lie_delete'):
            self.change(kernel=1, **{fault: True})
            self.run_helper('magicnet_lifecycle_after_stop', 2)
            self.assertTrue(self.state.exists())
            self.assertTrue(self.error.exists())
            self.change(**{fault: False})
        self.run_helper('magicnet_lifecycle_after_stop')
        self.assertFalse(self.state.exists())
        self.assertFalse(self.error.exists())

    def test_capture_without_baseline_does_not_claim_foreign_rules(self):
        self.change(kernel=0, rule4=['9000: from all lookup 2022'], route4=['default dev magicnet0'])
        self.run_helper('magicnet_kernel_route_state_capture', 2)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.read()['writes'])

    def test_prepared_failed_start_with_unknown_new_rule_stays_pending(self):
        self.run_helper('magicnet_kernel_route_state_begin')
        self.change(rule4=['9000: from all lookup 2022'])
        self.run_helper('magicnet_lifecycle_after_stop', 2)
        self.assertIn('phase=prepared', self.state.read_text())
        self.assertFalse(self.read()['writes'])

    def test_legacy_marker_never_deletes_guessed_rules(self):
        self.state.write_text('table=2022\ninterface=magicnet0\n')
        self.change(rule4=['9000: from all lookup 2022'])
        self.run_helper('magicnet_lifecycle_after_stop', 2)
        self.assertTrue(self.state.exists())
        self.assertFalse(self.read()['writes'])
        self.change(rule4=[])
        self.run_helper('magicnet_lifecycle_after_stop')
        self.assertFalse(self.state.exists())

    def test_new_boot_does_not_reuse_old_ownership(self):
        self.active()
        text = self.state.read_text()
        text = '\n'.join('boot=old-boot' if v.startswith('boot=') else v for v in text.splitlines()) + '\n'
        self.state.write_text(text)
        self.change(kernel=1)
        self.run_helper('magicnet_lifecycle_after_stop', 2)
        self.assertFalse(self.read()['writes'])

    def test_switch_to_ebpf_cleans_only_recorded_stopped_tun_generation(self):
        self.active()
        self.change(kernel=1, mode='ebpf')
        self.run_helper('magicnet_kernel_route_state_begin')
        self.assertFalse(self.state.exists())
        self.assertEqual(self.read()['route4'], ['10.0.0.0/8 dev wlan0'])

    def test_success_does_not_clear_an_unrelated_transparent_error(self):
        self.error.write_text('mode-transition-failed\n')
        self.run_helper('magicnet_lifecycle_after_stop')
        self.assertEqual(self.error.read_text(), 'mode-transition-failed\n')

    def test_hotspot_presence_requires_exact_tuple_and_successful_read(self):
        for line in ('8999: from all iif wlan2 lookup 20220',
                     '8999: from 192.0.2.0/24 iif wlan2 lookup 2022',
                     '8999: from all iif wlan2 lookup 2022 suppress_prefixlength 0'):
            self.change(rule4=[line])
            self.run_helper('magicnet_hotspot_rule_present 8999 wlan2', 1)
            self.run_helper('magicnet_hotspot_delete_rule 8999 wlan2')
            self.assertFalse(self.read()['writes'])
        self.change(fail_rule4=True)
        self.run_helper('magicnet_hotspot_delete_rule 8999 wlan2', 2)
        self.assertFalse(self.read()['writes'])

    def test_hotspot_unchanged_reconcile_does_not_write_or_replace_journal(self):
        self.change(kernel=0, route4=['default dev magicnet0'])
        self.run_helper('magicnet_hotspot_reconcile')
        before = self.read()['writes'][:]
        stamp = self.hotspot.stat().st_mtime_ns
        self.run_helper('magicnet_hotspot_reconcile')
        self.assertEqual(self.read()['writes'], before)
        self.assertEqual(self.hotspot.stat().st_mtime_ns, stamp)
        self.assertFalse(self.pending.exists())

    def test_hotspot_failed_install_and_rollback_retains_pending_record(self):
        self.change(kernel=0, route4=['default dev magicnet0'], fail_add=True, fail_forward_delete=True)
        self.run_helper('magicnet_hotspot_reconcile', 1)
        self.assertTrue(self.pending.exists())
        self.assertFalse(self.hotspot.exists())
        self.assertTrue(self.read()['forward'])
        self.change(fail_add=False, fail_forward_delete=False)
        self.run_helper('magicnet_hotspot_route_cleanup')
        self.assertFalse(self.pending.exists())
        self.assertFalse(self.read()['forward'])

    def test_hotspot_cleanup_does_not_delete_journal_on_failed_inspection(self):
        self.pending.write_text('8999|wlan2\n')
        self.change(fail_rule4=True)
        self.run_helper('magicnet_hotspot_route_cleanup', 2)
        self.assertTrue(self.pending.exists())
        self.assertFalse(self.read()['writes'])

    def test_hotspot_status_does_not_change_kernel_resources(self):
        self.change(kernel=0, route4=['default dev magicnet0'])
        self.run_helper('magicnet_hotspot_reconcile')
        before = self.read()['writes'][:]
        self.run_helper('magicnet_hotspot_route_status')
        self.assertEqual(self.read()['writes'], before)

    def test_failed_cleanup_marks_previously_active_hotspot_pending(self):
        self.change(kernel=0, route4=['default dev magicnet0'])
        self.run_helper('magicnet_hotspot_reconcile')
        self.assertTrue(self.hotspot.exists())
        self.change(fail_rule4=True, writes=[])
        self.run_helper('magicnet_hotspot_route_cleanup', 2)
        self.assertTrue(self.pending.exists())
        self.assertFalse(self.read()['writes'])
        self.change(fail_rule4=False)
        self.run_helper('magicnet_hotspot_route_cleanup')
        self.assertFalse(self.pending.exists())
        self.assertFalse(self.hotspot.exists())

    def guard_code(self, helper):
        return f"""
. {shlex.quote(str(ROOT / 'src/MagicNet/lib/magicnet/network.sh'))}
magicnet_cmd_exists() {{ case "$1" in iptables|ip6tables) return 0 ;; *) return 1 ;; esac; }}
magicnet_ip6tables_cmd() {{ case "$1" in -C) return 1 ;; *) return 0 ;; esac; }}
magicnet_xtables_available() {{ [ "$1" = iptables ]; }}
magicnet_iptables_cmd() {{ fixture iptables "$@"; }}
magicnet_iptables_ensure() {{ fixture iptables -I "$@"; }}
magicnet_log() {{ :; }}
magicnet_ipv6_mode() {{ printf 'ipv4_only\\n'; }}
magicnet_collect_physical_egress_ifaces() {{ printf 'wlan0\\n'; }}
{helper}
"""

    def test_guard_does_not_delete_unowned_rejects_on_a_physical_interface(self):
        vendor = 'OUTPUT -o wlan0 -p udp --dport 53 -j REJECT'
        own = 'OUTPUT -o wlan0 -p tcp --dport 853 -m comment --comment magicnet-dns-guard -j REJECT'
        self.change(forward=[vendor, own])
        self.run_helper(self.guard_code('magicnet_disable_dns_leak_guard'))
        self.assertEqual(self.read()['forward'], [vendor])
        before = self.read()['writes'][:]
        self.run_helper(self.guard_code('magicnet_disable_dns_leak_guard'))
        self.assertEqual(self.read()['writes'], before)

    def test_new_guard_journal_never_authorizes_untagged_rule_deletion(self):
        journal = self.mod / '.state/dns-leak-guard.ifaces'
        journal.write_text('wlan0\n# magicnet-owned-v2\n# families=4\n')
        vendor = 'OUTPUT -o wlan0 -p udp --dport 53 -j REJECT'
        self.change(forward=[vendor])
        self.run_helper(self.guard_code('magicnet_disable_dns_leak_guard'))
        self.assertEqual(self.read()['forward'], [vendor])
        self.assertFalse(self.read()['writes'])

    def test_legacy_guard_cleanup_requires_recorded_interface(self):
        journal = self.mod / '.state/dns-leak-guard.ifaces'
        journal.write_text('rmnet0\n')
        old = 'OUTPUT -o rmnet0 -p udp --dport 53 -j REJECT'
        foreign = 'OUTPUT -o wlan0 -p udp --dport 53 -j REJECT'
        self.change(forward=[old, old, foreign])
        self.run_helper(self.guard_code('magicnet_disable_dns_leak_guard'))
        self.assertEqual(self.read()['forward'], [foreign])
        self.assertFalse(journal.exists())

    def test_guard_unreadable_rules_preserve_journal_without_guessing(self):
        journal = self.mod / '.state/dns-leak-guard.ifaces'
        journal.write_text('rmnet0\n')
        self.change(fail_scan=True)
        self.run_helper(self.guard_code('magicnet_disable_dns_leak_guard'), 1)
        self.assertTrue(journal.exists())
        self.assertFalse(self.read()['writes'])

    def test_guard_failed_rollback_preserves_write_ahead_journal(self):
        self.change(fail_forward_delete=True)
        # Trigger one partial apply failure after the first insertion.
        code = self.guard_code('magicnet_enable_dns_leak_guard')
        code = code.replace('magicnet_enable_dns_leak_guard', """
MAGIC_DNS_LEAK_GUARD=1
magicnet_iptables_ensure() {
    case "$*" in *'--dport 853'*) return 1 ;; esac
    fixture iptables -I "$@"
}
magicnet_enable_dns_leak_guard
""")
        self.run_helper(code, 1)
        journal = self.mod / '.state/dns-leak-guard.ifaces'
        self.assertIn('# magicnet-owned-v2', journal.read_text())
        self.assertTrue(self.read()['forward'])
        self.change(fail_forward_delete=False)
        self.run_helper(self.guard_code('magicnet_disable_dns_leak_guard'))
        self.assertFalse(journal.exists())
        self.assertFalse(self.read()['forward'])

    def test_offload_restore_verifies_write_and_retains_failed_journal(self):
        owner = self.mod / '.state/hotspot/tether-offload.previous'
        owner.write_text('value=0\n')
        code = '''
magicnet_hotspot_offload_value() { cat "$MODDIR/current-offload"; }
settings() { printf '%s\n' "$*" >>"$MODDIR/settings-writes"; :; }
printf '1\n' >"$MODDIR/current-offload"
magicnet_hotspot_offload_restore
'''
        self.run_helper(code, 1)
        self.assertTrue(owner.exists())
        self.assertEqual((self.mod / 'settings-writes').read_text().strip(),
                         'put global tether_offload_disabled 0')
        (self.mod / 'settings-writes').unlink()
        self.run_helper('''
magicnet_hotspot_offload_value() { printf '0\n'; }
settings() { printf '%s\n' "$*" >>"$MODDIR/settings-writes"; }
magicnet_hotspot_offload_restore
''')
        self.assertFalse(owner.exists())
        self.assertFalse((self.mod / 'settings-writes').exists())

    def test_offload_conflict_never_overwrites_external_setting(self):
        owner = self.mod / '.state/hotspot/tether-offload.previous'
        owner.write_text('unset\n')
        self.run_helper('''
magicnet_hotspot_offload_value() { printf '0\n'; }
settings() { printf '%s\n' "$*" >>"$MODDIR/settings-writes"; }
magicnet_hotspot_offload_restore
''', 1)
        self.assertTrue(owner.exists())
        self.assertFalse((self.mod / 'settings-writes').exists())
        self.assertFalse(self.read()['writes'])

    def test_hotspot_enable_does_not_rewrite_active_setting_or_uninstall_script(self):
        owner = self.mod / '.state/hotspot/tether-offload.previous'
        uninstall = self.mod / 'uninstall.sh'
        uninstall.write_text('# fixture hook\n')
        self.run_helper('''
magicnet_hotspot_offload_value() { printf '1\n'; }
settings() { printf '%s\n' "$*" >>"$MODDIR/settings-writes"; }
magicnet_hotspot_offload_enable
magicnet_hotspot_offload_enable
''')
        self.assertEqual(owner.read_text(), 'value=1\n')
        self.assertEqual(owner.stat().st_mode & 0o777, 0o600)
        self.assertEqual(uninstall.read_text(), '# fixture hook\n')
        self.assertFalse((self.mod / 'settings-writes').exists())


    def test_failed_settings_read_never_clears_an_unset_journal(self):
        owner = self.mod / '.state/hotspot/tether-offload.previous'
        owner.write_text('unset\n')
        self.run_helper('''
settings() { case "$1" in get) printf 'null\n'; return 4 ;; *) printf '%s\n' "$*" >>"$MODDIR/settings-writes" ;; esac; }
magicnet_hotspot_offload_restore
''', 1)
        self.assertTrue(owner.exists())
        self.assertFalse((self.mod / 'settings-writes').exists())
        self.assertFalse(self.read()['writes'])

    def test_enable_refuses_failed_reads_with_and_without_previous_journal(self):
        owner = self.mod / '.state/hotspot/tether-offload.previous'
        for saved in (None, 'value=0\n'):
            if saved is not None:
                owner.write_text(saved)
            self.run_helper('''
settings() { case "$1" in get) return 4 ;; *) printf '%s\n' "$*" >>"$MODDIR/settings-writes" ;; esac; }
magicnet_hotspot_offload_enable
''', 1)
            self.assertEqual(owner.read_text() if owner.exists() else None, saved)
            self.assertFalse((self.mod / 'settings-writes').exists())

    def test_settings_multi_line_and_invalid_values_remain_unknown(self):
        for value in ('1\n0', 'permission denied', '2'):
            result = self.run_helper('settings() { printf %s ' + shlex.quote(value)
                                     + '; }; magicnet_hotspot_offload_value', 1)
            self.assertEqual(result.stdout, '')

    def test_offload_status_never_turns_failed_read_into_disabled_zero(self):
        result = self.run_helper('settings() { return 4; }; magicnet_hotspot_offload_status')
        self.assertIn('offload_disabled=unknown', result.stdout)
        self.assertNotIn('offload_disabled=0', result.stdout)


if __name__ == '__main__':
    unittest.main()
