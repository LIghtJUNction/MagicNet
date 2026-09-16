#!/usr/bin/env python3
"""Small, stateful kernel double for fake-magisk-smoke; never invokes ip/iptables.

Only this host fixture uses it. Production scripts are copied without changing
failure handling, ownership checks or lifecycle ordering.
"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import sys


def initial():
    return {
        "tables": {
            family: {table: {chain: [] for chain in chains}
                     for table, chains in {
                         "filter": ("INPUT", "FORWARD", "OUTPUT", "tetherctrl_FORWARD"),
                         "nat": ("PREROUTING", "INPUT", "OUTPUT", "POSTROUTING"),
                     }.items()}
            for family in ("iptables", "ip6tables")
        },
        "rules": {"4": [], "6": []},
        "core": None,
    }


def live(core):
    if not core:
        return False
    try:
        # A terminated but unreaped child is not a live listener.
        tail = Path(f"/proc/{core['pid']}/stat").read_text().rsplit(") ", 1)[1]
        fields = tail.split()
        return fields[0] not in ("Z", "X", "x") and ("start" not in core or fields[19] == core["start"])
    except (FileNotFoundError, ProcessLookupError):
        return False


@contextlib.contextmanager
def locked_state():
    path = Path(os.environ["MAGICNET_FAKE_NETWORK_STATE"])
    path.parent.mkdir(parents=True, exist_ok=True)
    with Path(str(path) + ".lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(path.read_text()) if path.exists() else initial()
        yield state
        temporary = Path(str(path) + ".new")
        temporary.write_text(json.dumps(state))
        temporary.replace(path)


def xtables(state, family, args):
    if args == ["--version"]:
        print(f"{family} v1.8.11 (nf_tables)")
        return 0
    args = list(args)
    table = "filter"
    if args[:1] == ["-t"]:
        table = args[1]
        args = args[2:]
    if table not in state["tables"][family]:
        print("Table does not exist", file=sys.stderr)
        return 3
    action, *rest = args
    chains = state["tables"][family][table]
    name = rest[0] if rest and not rest[0].startswith("-") else None
    if action in ("-L", "-nL"):
        return 0 if name is None or name in chains else 1
    if action == "-S":
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
    if action == "-N":
        if name in chains:
            return 1
        chains[name] = []
        return 0
    if name not in chains:
        return 1
    if action == "-F":
        chains[name] = []
        return 0
    if action == "-X":
        if chains[name] or any("-j" in r and r[r.index("-j") + 1] == name
                               for rules in chains.values() for r in rules):
            return 1
        del chains[name]
        return 0
    rule = rest[1:]
    position = int(rule.pop(0)) - 1 if action == "-I" and rule and rule[0].isdigit() else 0
    if "-j" in rule:
        target = rule[rule.index("-j") + 1]
        if target not in {"ACCEPT", "DROP", "REJECT", "RETURN", "REDIRECT", "DNAT", "MASQUERADE", "MARK"} and target not in chains:
            return 2
    if action == "-C":
        return 0 if rule in chains[name] else 1
    if action == "-D":
        if os.environ.get("MAGICNET_FAKE_XTABLES_DELETE_FAIL") == "1":
            print("fixture xtables delete failure", file=sys.stderr)
            return 4
        if rule not in chains[name]:
            return 1
        chains[name].remove(rule)
        return 0
    if action == "-A":
        chains[name].append(rule)
        return 0
    if action == "-I":
        chains[name].insert(position, rule)
        return 0
    raise ValueError(f"unsupported xtables fixture command: {family} {args}")


def ip(state, args):
    args = list(args)
    family = "4"
    if args[:1] == ["-6"]:
        family, args = "6", args[1:]
    core = state["core"]
    tun = live(core) and core["mode"] == "tun"
    if args[:2] == ["rule", "show"]:
        if tun:
            print("9000: from all lookup 2022")
        for rule in state["rules"][family]:
            print(rule)
        return 0
    if args[:2] in (["rule", "add"], ["rule", "del"]):
        action, rule = args[1], args[2:]
        if rule[0] != "priority":
            raise ValueError(f"fixture requires exact priority: {args}")
        line = f"{rule[1]}: " + " ".join(rule[2:])
        if action == "add":
            state["rules"][family].append(line)
        elif line in state["rules"][family]:
            state["rules"][family].remove(line)
        else:
            return 2
        return 0
    if args[:2] == ["route", "show"]:
        if args[2:] == ["table", "2022"] and tun:
            print("default dev magicnet0 scope link")
        return 0
    if args[:2] == ["route", "flush"]:
        if args[2:] != ["table", "2022", "dev", "magicnet0"]:
            raise ValueError(f"unscoped route flush: {args}")
        if tun:
            raise ValueError("fixture must not flush a live core's routes")
        return 0
    if args[:3] == ["-o", "link", "show"]:
        print("1: lo: <LOOPBACK,UP>")
        if tun:
            print("8: magicnet0: <POINTOPOINT,UP>")
        return 0
    if args[:3] == ["-o", "-4", "addr"] and args[3:5] == ["show", "dev"]:
        dev = args[5]
        cidrs = {"ap0": "192.168.43.1/24", "wlan0": "192.168.43.1/24", "tun0": "10.8.0.2/24"}
        if tun:
            cidrs["magicnet0"] = "172.19.0.1/30"
        if dev in cidrs:
            print(f"8: {dev} inet {cidrs[dev]} scope global {dev}")
        return 0
    if args[:3] == ["-o", "-6", "addr"] and args[3:5] == ["show", "dev"]:
        if args[5] == "tun0":
            print("9: tun0 inet6 fd00::2/64 scope global")
        return 0
    raise ValueError(f"unsupported ip fixture command: {args}")


def main(args):
    with locked_state() as state:
        command, *args = args
        if command in ("iptables", "ip6tables"):
            return xtables(state, command, args)
        if command == "ip":
            return ip(state, args)
        if command == "core-start":
            config = json.loads(Path(args[1]).read_text())
            mode = "tun" if any(i.get("type") == "tun" for i in config.get("inbounds", [])) else "ebpf"
            fields = Path(f"/proc/{int(args[0])}/stat").read_text().rsplit(") ", 1)[1].split()
            state["core"] = {"pid": int(args[0]), "mode": mode, "start": fields[19]}
            return 0
        if command == "pid-live":
            return 0 if len(args) == 1 and live({"pid": int(args[0])}) else 1
        if command == "interface":
            return 0 if args == ["magicnet0"] and live(state["core"]) and state["core"]["mode"] == "tun" else 1
        if command == "seed-cleanup":
            for family in ("iptables", "ip6tables"):
                nat = state["tables"][family]["nat"]
                nat["magicnet-dns-output"] = [["-p", "udp", "--dport", "53", "-j", "REDIRECT", "--to-ports", "1053"]]
                nat["OUTPUT"] = [r for r in nat["OUTPUT"] if "magicnet-dns-output" not in r]
                nat["OUTPUT"].insert(0, ["-j", "magicnet-dns-output"])
                guard = ["-o", "lo", "-p", "udp", "--dport", "53", "-j", "REJECT"]
                output = state["tables"][family]["filter"]["OUTPUT"]
                if guard not in output:
                    output.append(guard)
            return 0
        if command == "reset":
            state.clear()
            state.update(initial())
            return 0
        raise ValueError(f"unsupported fixture command: {command}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (KeyError, IndexError, ValueError) as exc:
        print(f"fake kernel: {exc}", file=sys.stderr)
        sys.exit(64)
