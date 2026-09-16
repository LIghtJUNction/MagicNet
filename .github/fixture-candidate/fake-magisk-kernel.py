#!/usr/bin/env python3
"""Private stateful host-fixture boundaries; never used by the shipped module.

Models only the ip/xtables calls exercised by fake-magisk-smoke. Unknown mutation
commands fail rather than inventing success. Real namespace tests validate actual
kernel behavior separately; this model is not Android/network acceptance.
"""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import shlex
import sys

CHAIN = 'magicnet-dns-output'
FOREIGN = ['-o', 'lo', '-p', 'udp', '--dport', '53', '-j', 'REJECT']


def initial():
    tables = {}
    for family in ('iptables', 'ip6tables'):
        tables[family] = {
            'filter': {'OUTPUT': [FOREIGN.copy()], 'INPUT': [], 'FORWARD': [], 'tetherctrl_FORWARD': []},
            'nat': {'OUTPUT': [['-j', CHAIN]], 'POSTROUTING': [], 'PREROUTING': [],
                    CHAIN: [['-p', p, '--dport', '53', '-j', 'REDIRECT', '--to-ports', '1053']
                            for p in ('udp', 'tcp')]},
        }
    return {'tables': tables, 'rules': {'4': [], '6': []}, 'core': None}


def alive(core):
    if not core:
        return False
    try:
        pid = int(core['pid'])
        os.kill(pid, 0)
        stat = Path(f'/proc/{pid}/stat').read_text()
        return stat.rsplit(')', 1)[1].split()[0] != 'Z'
    except (OSError, ValueError, KeyError):
        return False


def tun(state):
    return alive(state['core']) and state['core']['mode'] == 'tun'


def xtables(state, family, args):
    if args == ['--version']:
        print(f'{family} v1.8.11 (nf_tables)')
        return 0
    table = 'filter'
    if args[:1] == ['-t'] and len(args) >= 2:
        table, args = args[1], args[2:]
    if table not in state['tables'][family]:
        return 3
    chains = state['tables'][family][table]
    if not args:
        return 2
    action, *rest = args
    if action == '-nL':
        action = '-L'
    name = rest[0] if rest and not rest[0].startswith('-') else None
    if action == '-L':
        return 0 if name is None or name in chains else 1
    if action == '-S':
        if name is not None and name not in chains:
            return 1
        for chain in [name] if name else chains:
            for rule in chains[chain]:
                print(shlex.join(['-A', chain] + rule))
        return 0
    if name is None:
        return 2
    rule = rest[1:]
    if action == '-N':
        if name in chains:
            return 1
        chains[name] = []
        return 0
    if name not in chains:
        return 1
    if action == '-F':
        chains[name] = []
    elif action == '-X':
        if chains[name] or any(name in r for rs in chains.values() for r in rs):
            return 1
        del chains[name]
    elif action == '-C':
        return 0 if rule in chains[name] else 1
    elif action == '-D':
        if os.environ.get('MAGICNET_FAKE_XTABLES_DELETE_FAIL') == '1':
            print('fixture xtables delete failure', file=sys.stderr)
            return 4
        if rule not in chains[name]:
            return 1
        chains[name].remove(rule)
    elif action == '-I':
        at = int(rule.pop(0)) - 1 if rule and rule[0].isdigit() else 0
        if at < 0:
            return 2
        chains[name].insert(at, rule)
    elif action == '-A':
        chains[name].append(rule)
    else:
        print('unsupported fixture xtables operation', file=sys.stderr)
        return 2
    return 0


def rule_record(args):
    if len(args) < 2 or args[0] not in ('priority', 'pref') or not args[1].isdigit():
        raise ValueError('fixture requires an explicit priority')
    priority, rest = args[1], args[2:]
    if rest[:1] != ['from']:
        rest = ['from', 'all'] + rest
    if len(rest) < 4 or 'lookup' not in rest:
        raise ValueError('unsupported fixture rule')
    return priority + ': ' + shlex.join(rest)


def ip(state, args):
    family = '4'
    if args[:1] in (['-4'], ['-6']):
        family, args = args[0][1:], args[1:]
    if args[:2] == ['rule', 'show']:
        print('0: from all lookup local')
        for rule in state['rules'][family]:
            print(rule)
        print('32766: from all lookup main\n32767: from all lookup default')
        return 0
    if args[:2] in (['rule', 'add'], ['rule', 'del']):
        record = rule_record(args[2:])
        rules = state['rules'][family]
        if args[1] == 'add':
            rules.append(record)
        else:
            if record not in rules:
                return 2
            rules.remove(record)
        return 0
    if args[:2] == ['route', 'show']:
        if 'table' in args and args[args.index('table') + 1] == '2022' and tun(state):
            print('default dev magicnet0 scope link')
        return 0
    if args[:2] == ['route', 'flush']:
        if 'dev' not in args or args[args.index('dev') + 1] != 'magicnet0' or tun(state):
            return 2
        return 0
    if args[:2] == ['link', 'show']:
        name = args[-1]
        if name in ('lo', 'ap0', 'wlan0', 'tun0') or (name == 'magicnet0' and tun(state)):
            print(f'8: {name}: <UP> mtu 1500 state UNKNOWN')
            return 0
        return 1
    if args[:1] == ['-o'] and len(args) >= 4 and args[1] in ('-4', '-6'):
        addr_family, tail = args[1], args[2:]
        if tail[:2] != ['addr', 'show']:
            return 2
        name = tail[-1]
        if addr_family == '-4':
            addresses = {'ap0': '192.168.43.1/24', 'wlan0': '192.168.43.1/24',
                         'tun0': '10.8.0.2/24', 'magicnet0': '172.19.0.1/30'}
            if name in addresses:
                print(f'7: {name} inet {addresses[name]} scope global {name}')
        elif name == 'tun0':
            print('9: tun0 inet6 fd00::2/64 scope global')
        return 0
    print('unsupported fixture ip operation', file=sys.stderr)
    return 2


def dispatch(state, program, args):
    if program in ('iptables', 'ip6tables'):
        return xtables(state, program, args)
    if program == 'ip':
        return ip(state, args)
    if program == 'core-start':
        pid = int(args[0])
        config = json.loads(Path(args[1]).read_text())
        mode = 'tun' if any(i.get('type') == 'tun' for i in config.get('inbounds', [])) else 'ebpf'
        state['core'] = {'pid': pid, 'mode': mode}
        if mode == 'tun':
            for family in ('4', '6'):
                rule = '9000: from all lookup 2022'
                if rule not in state['rules'][family]:
                    state['rules'][family].append(rule)
        return 0
    if program == 'assert-clean':
        for family in ('iptables', 'ip6tables'):
            tables = state['tables'][family]
            if CHAIN in tables['nat'] or any(CHAIN in r for rs in tables['nat'].values() for r in rs):
                raise ValueError('owned DNS state was not cleaned')
            if tables['filter']['OUTPUT'] != [FOREIGN]:
                raise ValueError('foreign filter rule was changed or owned guard remains')
        return 0
    raise ValueError('unsupported fixture command')


def main():
    log = Path(os.environ['MAGICNET_FAKE_LOG'])
    # The harness owns this private directory; fixture self-tests use separate
    # log names, so no self-test mutation leaks into the runtime instance.
    path = log.with_name(log.name + '.kernel.json')
    lock = log.with_name(log.name + '.kernel.lock')
    with lock.open('a') as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        state = json.loads(path.read_text()) if path.exists() else initial()
        result = dispatch(state, sys.argv[1], sys.argv[2:])
        temp = path.with_name(path.name + '.new')
        temp.write_text(json.dumps(state))
        os.replace(temp, path)
        return result


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, IndexError) as error:
        print('kernel fixture error: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
