#!/usr/bin/env python3
"""Real UDP/TCP DNS through production NAT rules in an isolated network namespace.

All answers come from a local fixture. This does NOT test public DNS, the user's
subscription, Android netd, authenticated apps, or website availability.
"""
import ipaddress
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
NETWORK = ROOT / "src/MagicNet/lib/magicnet/network.sh"
CORPUS = ROOT / "src/MagicNet/lib/magicnet/network-targets.tsv"
EXTRA_HOSTS = ("android.clients.google.com", "android.googleapis.com", "android.apis.google.com",
               "oauth2.googleapis.com", "mtalk.google.com", "checkin.gstatic.com", "gemini.google.com")
SHELL = r'''
set -eu
. "$NETWORK_SOURCE"
magicnet_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
magicnet_transparent_mode() { echo tun; }
magicnet_ipv6_mode() { echo prefer_ipv6; }
magicnet_dns_profile() { echo default; }
magicnet_dns_capture_singbox_mark() { echo 128; }
magicnet_dns_capture_singbox_udp_marked() { return 1; }
magicnet_warn() { echo "$*" >&2; }
magicnet_log() { echo "$*"; }
case "$ACTION" in
    enable) magicnet_enable_dns_capture ;;
    disable) magicnet_disable_dns_capture ;;
esac
'''


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=15, **kwargs)


def hosts():
    names = set(EXTRA_HOSTS)
    count = 0
    for line in CORPUS.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) != 4:
            raise ValueError("invalid HTTPS corpus")
        name = urlsplit(fields[2]).hostname
        if not name:
            raise ValueError("missing hostname")
        names.add(name)
        count += 1
    if count < 20 or len(names) > 64:
        raise ValueError("empty, incomplete, or oversized DNS corpus")
    return sorted(names)


def question(name, kind):
    wire = b"".join(bytes([len(label)]) + label.encode("ascii") for label in name.split(".")) + b"\0"
    return b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + wire + struct.pack("!HH", kind, 1)


def answer(query):
    # The fixture accepts only our one-question, uncompressed A/AAAA queries.
    at = 12
    while query[at]:
        at += query[at] + 1
    end = at + 5
    kind, klass = struct.unpack("!HH", query[at + 1:end])
    if kind not in (1, 28) or klass != 1 or end != len(query):
        raise ValueError("unexpected fixture DNS question")
    address = ipaddress.ip_address("198.18.0.77" if kind == 1 else "2001:db8::77").packed
    return (query[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0) + query[12:end] +
            b"\xc0\x0c" + struct.pack("!HHIH", kind, 1, 60, len(address)) + address)


def read_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise EOFError("short DNS frame")
        data += chunk
    return data


def serve(listener, tcp, stop, errors):
    listener.settimeout(0.2)
    while not stop.is_set():
        try:
            if tcp:
                conn, _ = listener.accept()
                with conn:
                    conn.settimeout(1)
                    query = read_exact(conn, struct.unpack("!H", read_exact(conn, 2))[0])
                    reply = answer(query)
                    conn.sendall(struct.pack("!H", len(reply)) + reply)
            else:
                query, peer = listener.recvfrom(4096)
                listener.sendto(answer(query), peer)
        except socket.timeout:
            continue
        except Exception as exc:
            if not stop.is_set():
                errors.append(str(exc))
                return


def probe(family, tcp, name, kind=1, source_port=0):
    destination = "198.18.0.53" if family == socket.AF_INET else "2001:db8::53"
    query = question(name, kind)
    with socket.socket(family, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as conn:
        conn.settimeout(0.6)
        if source_port:
            conn.bind(("0.0.0.0" if family == socket.AF_INET else "::", source_port))
        conn.connect((destination, 53))
        if tcp:
            conn.sendall(struct.pack("!H", len(query)) + query)
            reply = read_exact(conn, struct.unpack("!H", read_exact(conn, 2))[0])
        else:
            conn.send(query)
            reply = conn.recv(4096)
    if reply != answer(query):
        raise AssertionError(f"invalid DNS response: {name} family={family} tcp={tcp} type={kind}")


def inside():
    # Refuse to touch the caller's network namespace even when invoked as root.
    own = os.readlink("/proc/self/ns/net")
    parent = os.readlink(f"/proc/{os.getppid()}/ns/net")
    if os.geteuid() != 0 or own == parent:
        raise RuntimeError("kernel fixture requires an isolated root network namespace")
    names = hosts()
    run("ip", "link", "set", "lo", "up")
    run("ip", "link", "add", "mn-dns-test", "type", "dummy")
    run("ip", "addr", "add", "198.18.0.1/24", "dev", "mn-dns-test")
    run("ip", "-6", "addr", "add", "2001:db8::1/64", "dev", "mn-dns-test", "nodad")
    run("ip", "link", "set", "mn-dns-test", "up")
    run("ip", "route", "add", "default", "dev", "mn-dns-test")
    run("ip", "-6", "route", "add", "default", "dev", "mn-dns-test")
    listeners, threads, errors = [], [], []
    stop = threading.Event()
    try:
        for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
            for tcp in (False, True):
                listener = socket.socket(family, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM)
                listeners.append(listener)
                if family == socket.AF_INET6:
                    listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                listener.bind((address, 1053))
                if tcp:
                    listener.listen(8)
                thread = threading.Thread(target=serve, args=(listener, tcp, stop, errors), daemon=True)
                threads.append(thread)
                thread.start()
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, NETWORK_SOURCE=str(NETWORK), MODDIR=tmp,
                       MAGIC_DNS_CAPTURE="1", MAGIC_DNS_CAPTURE_PORT="1053", ACTION="enable")
            run("sh", "-c", SHELL, env=env)
            for binary, bad in (("iptables", "172.19.0.2"), ("ip6tables", "2001:db8::dead")):
                run(binary, "-t", "nat", "-N", "sing-box-output")
                run(binary, "-t", "nat", "-A", "sing-box-output", "-p", "udp", "--dport", "53",
                    "-j", "DNAT", "--to-destination", bad)
                run(binary, "-t", "nat", "-I", "OUTPUT", "-j", "sing-box-output")
                # A duplicate from an older install must not accumulate on reapply.
                run(binary, "-t", "nat", "-A", "OUTPUT", "-j", "magicnet-dns-output")
            try:
                probe(socket.AF_INET, False, "accounts.google.com", source_port=21053)
            except (TimeoutError, OSError):
                print("PASS: competing DNAT reproduces the DNS black hole", flush=True)
            else:
                raise AssertionError("fixture did not reproduce the pre-repair failure")
            run("sh", "-c", SHELL, env=env)
            count = 0
            for name in names:
                for family in (socket.AF_INET, socket.AF_INET6):
                    for tcp in (False, True):
                        for kind in (1, 28):
                            probe(family, tcp, name, kind)
                            count += 1
            for binary in ("iptables", "ip6tables"):
                rules = run(binary, "-t", "nat", "-S", "OUTPUT").stdout.splitlines()
                jumps = [r for r in rules if r.startswith("-A OUTPUT ")]
                if jumps[0] != "-A OUTPUT -j magicnet-dns-output" or sum("magicnet-dns-output" in r for r in jumps) != 1:
                    raise AssertionError("DNS jump priority/uniqueness is wrong")
                run(binary, "-t", "nat", "-A", "OUTPUT", "-p", "tcp", "--dport", "53", "-j", "magicnet-dns-output")
            env["ACTION"] = "disable"
            run("sh", "-c", SHELL, env=env)
            for binary in ("iptables", "ip6tables"):
                rules = run(binary, "-t", "nat", "-S").stdout
                if "magicnet-dns-output" in rules or "sing-box-output" not in rules:
                    raise AssertionError("cleanup removed foreign rules or stranded capture")
            if errors:
                raise AssertionError(errors)
            print(f"PASS: {count} fixture DNS exchanges; {len(names)} hosts, A/AAAA, UDP/TCP, IPv4/IPv6, UID 0")
            print("NOT_TESTED: public resolvers, Android netd, subscription, logged-in apps, real website availability")
    finally:
        stop.set()
        for thread in threads:
            thread.join(timeout=2)
        for listener in listeners:
            listener.close()


def main():
    if sys.argv[1:] == ["--inside"]:
        inside()
        return 0
    if sys.argv[1:] not in ([], ["--require"]):
        print("usage: test-dns-kernel.py [--require]", file=sys.stderr)
        return 64
    missing = [tool for tool in ("unshare", "ip", "iptables", "ip6tables") if not shutil.which(tool)]
    if missing:
        print("INCOMPLETE: missing kernel test tools: " + ", ".join(missing), file=sys.stderr)
        return 2 if "--require" in sys.argv else 77
    command = ["unshare", "--net", sys.executable, "-S", str(Path(__file__).resolve()), "--inside"]
    if os.geteuid() != 0:
        command = ["sudo", "-n"] + command
    return subprocess.run(command, timeout=120, check=False).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, AssertionError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
