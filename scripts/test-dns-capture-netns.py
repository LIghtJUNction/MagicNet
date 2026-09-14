#!/usr/bin/env python3
"""Real UDP/TCP DNS through production iptables rules, in isolated Linux netns.

All replies are synthetic fixtures. This is not public-site or Android account
acceptance, and it never needs a subscription, Internet DNS, or host firewall edits.
"""
import ipaddress
import itertools
import os
from pathlib import Path
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
DOMAINS = (
    "accounts.google.com", "android.clients.google.com", "play.google.com",
    "www.googleapis.com", "www.gstatic.com", "github.com", "www.bing.com",
    "login.microsoftonline.com", "www.cloudflare.com", "www.baidu.com",
)
ADDRESSES = {1: ipaddress.ip_address("203.0.113.9").packed,
             28: ipaddress.ip_address("2001:db8:1234::9").packed}


def question(name, kind):
    labels = b"".join(bytes([len(part)]) + part.encode("ascii") for part in name.split("."))
    return struct.pack("!6H", 0x4D4E, 0x0100, 1, 0, 0, 0) + labels + b"\0" + struct.pack("!HH", kind, 1)


def response(data, udp):
    if len(data) < 17:
        raise ValueError("short question")
    offset, labels = 12, []
    while data[offset]:
        size = data[offset]
        if size > 63 or offset + size + 1 >= len(data):
            raise ValueError("invalid question label")
        labels.append(data[offset + 1:offset + 1 + size].decode("ascii"))
        offset += size + 1
    kind, dns_class = struct.unpack("!HH", data[offset + 1:offset + 5])
    if dns_class != 1:
        raise ValueError("unexpected question class")
    name = ".".join(labels)
    flags, answer = 0x8180, b""
    if name == "missing.magicnet.test":
        flags |= 3  # NXDOMAIN must remain a real negative response.
    elif name == "truncated.magicnet.test" and udp:
        flags |= 0x0200  # Exercise UDP truncation followed by TCP, not a timeout retry.
    elif kind in ADDRESSES:
        address = ADDRESSES[kind]
        answer = b"\xc0\x0c" + struct.pack("!HHIH", kind, 1, 1, len(address)) + address
    header = data[:2] + struct.pack("!5H", flags, 1, int(bool(answer)), 0, 0)
    return header + data[12:offset + 5] + answer


def receive_exact(sock, count):
    data = b""
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise OSError("short TCP DNS response")
        data += part
    return data


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(response(data, True), self.client_address)


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(2)
        size = struct.unpack("!H", receive_exact(self.request, 2))[0]
        data = response(receive_exact(self.request, size), False)
        self.request.sendall(struct.pack("!H", len(data)) + data)


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(b"proxy-fixture\n")


def server(family, udp, port, handler):
    base = socketserver.ThreadingUDPServer if udp else socketserver.ThreadingTCPServer
    class FixtureServer(base):
        address_family = family
        allow_reuse_address = True
        daemon_threads = True

        def server_bind(self):
            if family == socket.AF_INET6:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()
    srv = FixtureServer(("127.0.0.1" if family == socket.AF_INET else "::1", port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def query(wire, resolver, name, kind):
    family = socket.AF_INET6 if ":" in resolver else socket.AF_INET
    data = question(name, kind)
    with socket.socket(family, socket.SOCK_DGRAM if wire == "udp" else socket.SOCK_STREAM) as sock:
        sock.settimeout(1)
        sock.connect((resolver, 53))
        if wire == "udp":
            sock.send(data)
            received = sock.recv(4096)
        else:
            sock.sendall(struct.pack("!H", len(data)) + data)
            size = struct.unpack("!H", receive_exact(sock, 2))[0]
            if size > 4096:
                raise ValueError("oversized response")
            received = receive_exact(sock, size)
    if len(received) < 12 or received[:2] != data[:2]:
        raise ValueError("invalid response or query ID")
    flags, questions, answers, _, _ = struct.unpack("!5H", received[2:12])
    if not flags & 0x8000 or questions != 1:
        raise ValueError("not a DNS response")
    if name == "missing.magicnet.test":
        if flags & 15 != 3 or answers != 0:
            raise ValueError("NXDOMAIN was disguised as success")
    elif name == "truncated.magicnet.test" and wire == "udp":
        if not flags & 0x0200:
            raise ValueError("missing truncation bit")
        return query("tcp", resolver, name, kind)
    elif flags & 15 or answers != 1 or not received.endswith(ADDRESSES[kind]):
        raise ValueError("wrong DNS answer")
    return received


SETUP = r'''
set -eu
. "$NETWORK_SOURCE"
. "$CORE_SOURCE"
magicnet_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
magicnet_transparent_mode() { printf 'tun\n'; }
magicnet_ipv6_mode() { printf 'prefer_ipv6\n'; }
magicnet_dns_profile() { printf 'default\n'; }
magicnet_dns_capture_singbox_mark() { printf '128\n'; }
magicnet_dns_capture_singbox_udp_marked() { return 0; }
magicnet_kernel_running() { return 0; }
magicnet_kernel_start_preamble() { :; }
magicnet_with_sub_config_lock() { "$@"; }
magicnet_start_kernel() { echo 'unexpected core restart' >&2; return 99; }
magicnet_warn() { printf '%s\n' "$*" >&2; }
magicnet_log() { :; }
magicnet_iptables_cmd() { timeout 5 "$IPTABLES" -w 1 "$@"; }
magicnet_ip6tables_cmd() { timeout 5 "$IP6TABLES" -w 1 "$@"; }
case "$ACTION" in
install) magicnet_enable_dns_capture ;;
ensure) magicnet_ensure_kernel ;;
stop) magicnet_disable_dns_capture ;;
*) exit 64 ;;
esac
'''


def run(*command, **options):
    return subprocess.run(command, check=True, text=True, capture_output=True, timeout=30, **options).stdout


def inside(backend):
    parent = os.environ.get("MAGICNET_TEST_PARENT_NETNS")
    if not parent or os.readlink("/proc/self/ns/net") == parent or os.geteuid() != 0:
        raise RuntimeError("refusing to modify firewall outside a fresh root network namespace")
    run("ip", "link", "set", "lo", "up")
    run("ip", "route", "add", "198.51.100.0/24", "dev", "lo")
    run("ip", "-6", "route", "add", "2001:db8::/64", "dev", "lo")
    run("ip", "route", "add", "blackhole", "172.19.0.2/32")
    run("ip", "-6", "route", "add", "blackhole", "fdfe:dcba::2/128")
    families = ("iptables-" + backend, "ip6tables-" + backend)
    for binary, target in zip(families, ("172.19.0.2", "fdfe:dcba::2")):
        for chain in ("sing-box-output", "vendor-output"):
            run(binary, "-t", "nat", "-N", chain)
        run(binary, "-t", "nat", "-A", "vendor-output", "-j", "RETURN")
        run(binary, "-t", "nat", "-A", "sing-box-output", "-p", "udp", "--dport", "53", "-j", "DNAT", "--to-destination", target)
        run(binary, "-t", "nat", "-A", "sing-box-output", "-p", "tcp", "-j", "REDIRECT", "--to-ports", "42791")
        run(binary, "-t", "nat", "-A", "OUTPUT", "-j", "sing-box-output")
        run(binary, "-t", "nat", "-A", "OUTPUT", "-j", "vendor-output")
    servers = [server(f, udp, 1053, UDPHandler if udp else TCPHandler)
               for f, udp in itertools.product((socket.AF_INET, socket.AF_INET6), (True, False))]
    servers += [server(f, False, 42791, ProxyHandler) for f in (socket.AF_INET, socket.AF_INET6)]
    try:
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, MODDIR=directory, MAGIC_DNS_CAPTURE="1", MAGIC_DNS_CAPTURE_PORT="1053",
                       NETWORK_SOURCE=str(ROOT / "src/MagicNet/lib/magicnet/network.sh"),
                       CORE_SOURCE=str(ROOT / "src/MagicNet/lib/magicnet/core.sh"),
                       IPTABLES=families[0], IP6TABLES=families[1])
            def action(name):
                run("sh", "-c", SETUP, env=dict(env, ACTION=name))
            def matrix(phase):
                # Real owner-matched sockets: netd/root, Play, Play Services, ordinary app.
                for uid in (0, 10093, 10109, 11000):
                    run(sys.executable, "-S", __file__, "--client-matrix", str(uid))
                print(f"PASS {backend} {phase}: 320 A/AAAA UDP/TCP queries + NXDOMAIN/truncation + non-DNS", flush=True)
            action("install")
            matrix("fresh install")
            for binary in families:
                run(binary, "-t", "nat", "-D", "OUTPUT", "-j", "sing-box-output")
                run(binary, "-t", "nat", "-I", "OUTPUT", "-j", "sing-box-output")
            # The exact ordering regression MUST break real DNS before repair.
            for resolver in ("198.51.100.53", "2001:db8::53"):
                try:
                    query("udp", resolver, "accounts.google.com", 1)
                except (OSError, ValueError):
                    pass
                else:
                    raise AssertionError("negative control did not reproduce DNS failure")
            action("ensure")
            matrix("watchdog repaired drift")
            for binary in families:
                for proto in ("udp", "tcp"):
                    run(binary, "-t", "nat", "-I", "OUTPUT", "-p", proto, "--dport", "53", "-j", "magicnet-dns-output")
            action("stop")
            for binary in families:
                rules = run(binary, "-t", "nat", "-S")
                if "magicnet-dns-output" in rules or "-A OUTPUT -j sing-box-output" not in rules:
                    raise AssertionError("cleanup left DNS rules or damaged other owners")
            action("install")
            matrix("stop/start")
            action("stop")
    finally:
        for srv in servers:
            srv.shutdown()
            srv.server_close()


def client_matrix(uid):
    os.setgroups([])
    os.setgid(uid)
    os.setuid(uid)
    for resolver, wire, kind, domain in itertools.product(
            ("198.51.100.53", "2001:db8::53"), ("udp", "tcp"), (1, 28), DOMAINS):
        query(wire, resolver, domain, kind)
    for resolver in ("198.51.100.53", "2001:db8::53"):
        for domain in ("missing.magicnet.test", "truncated.magicnet.test"):
            query("udp", resolver, domain, 1)
        with socket.create_connection((resolver, 443), timeout=1) as sock:
            if sock.recv(64) != b"proxy-fixture\n":
                raise AssertionError("DNS rules intercepted non-DNS traffic")


def main():
    if sys.argv[1:2] == ["--inside"]:
        inside(sys.argv[2])
    elif sys.argv[1:2] == ["--client-matrix"]:
        client_matrix(int(sys.argv[2]))
    else:
        for tool in ("ip", "unshare", "timeout", "iptables-legacy", "ip6tables-legacy", "iptables-nft", "ip6tables-nft"):
            if not shutil.which(tool):
                raise RuntimeError(f"required kernel-test tool missing: {tool}")
        prefix = [] if os.geteuid() == 0 else ["sudo", "-n"]
        for backend in ("legacy", "nft"):
            command = prefix + ["env", "MAGICNET_TEST_PARENT_NETNS=" + os.readlink("/proc/self/ns/net"),
                                "unshare", "--net", "--", sys.executable, str(Path(__file__).resolve()), "--inside", backend]
            subprocess.run(command, check=True, timeout=120)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or "", file=sys.stderr)
        print(error.stderr or "", file=sys.stderr)
        raise
