#!/usr/bin/env python3
"""Real sing-box loopback routing test; not Google Play/device acceptance."""
from __future__ import annotations

import http.client
import json
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def read_exact(stream, count: int) -> bytes:
    data = stream.read(count)
    if len(data) != count:
        raise EOFError("incomplete fixture request")
    return data


class SocksFixture(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        self.connection.settimeout(5)
        version, methods = read_exact(self.rfile, 2)
        if version != 5:
            return
        read_exact(self.rfile, methods)
        self.wfile.write(b"\x05\x00")
        version, command, _, address_type = read_exact(self.rfile, 4)
        if version != 5 or command != 1:
            return
        if address_type == 1:
            read_exact(self.rfile, 4)
        elif address_type == 3:
            read_exact(self.rfile, read_exact(self.rfile, 1)[0])
        elif address_type == 4:
            read_exact(self.rfile, 16)
        else:
            return
        read_exact(self.rfile, 2)
        self.wfile.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
        # No destination dial: this controlled SOCKS endpoint identifies the
        # selected node and cannot accidentally contact a public Google host.
        first_line = self.rfile.readline(4096)
        if not first_line.startswith(b"GET "):
            return
        for _ in range(64):
            if self.rfile.readline(4096) in (b"\r\n", b"\n", b""):
                break
        marker = self.server.marker  # type: ignore[attr-defined]
        self.wfile.write(
            b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
            + str(len(marker)).encode() + b"\r\n\r\n" + marker
        )


class FixtureServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, marker: bytes) -> None:
        self.marker = marker
        super().__init__(("127.0.0.1", 0), SocksFixture)


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def api(port: int, method: str, path: str, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        payload = None if body is None else json.dumps(body)
        conn.request(method, path, payload, {"Content-Type": "application/json"})
        response = conn.getresponse()
        data = response.read()
        if response.status not in (200, 204):
            raise AssertionError(f"fixture API returned {response.status}: {data!r}")
        return json.loads(data) if data else None
    finally:
        conn.close()


def probe(port: int, expected: bytes) -> None:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request("GET", "http://play.fixture.invalid/check", headers={"Connection": "close"})
        response = conn.getresponse()
        body = response.read()
        if response.status != 200 or body != expected:
            raise AssertionError(f"wrong selected outbound: {response.status} {body!r}, wanted {expected!r}")
    finally:
        conn.close()


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: test-service-selector-routing.py GENERATED_CONFIG")
    core = shutil.which("sing-box")
    if core is None:
        raise SystemExit("real-core routing test requires sing-box")
    template = json.loads(Path(sys.argv[1]).read_text())
    with FixtureServer(b"first-node") as first, FixtureServer(b"selected-node") as second:
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (first, second)]
        for thread in threads:
            thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="magicnet-selector-core-") as directory:
                root = Path(directory)
                mixed, controller = free_port(), free_port()
                while mixed == controller:
                    controller = free_port()
                nodes = [
                    {"type": "socks", "tag": "US-test", "server": "127.0.0.1", "server_port": first.server_address[1], "version": "5"},
                    {"type": "socks", "tag": "US-secondary", "server": "127.0.0.1", "server_port": second.server_address[1], "version": "5"},
                ]
                # Retain the exact generated Google selector under test; add
                # the second fixture node as another selectable proxy choice.
                google = next(out for out in template["outbounds"] if out["tag"] == "google-proxy")
                configuration = {
                    "log": {"level": "error"},
                    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": mixed}],
                    "outbounds": nodes + [
                        {"type": "selector", "tag": "proxy", "outbounds": ["US-test", "US-secondary"], "default": "US-test"},
                        google, {"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"},
                    ],
                    "route": {"rules": [{"domain": ["play.fixture.invalid"], "outbound": "google-proxy"}], "final": "proxy"},
                    "experimental": {"clash_api": {"external_controller": f"127.0.0.1:{controller}"}},
                }
                config_path = root / "config.json"
                config_path.write_text(json.dumps(configuration))
                subprocess.run([core, "check", "-c", str(config_path), "-D", directory], check=True, timeout=15)
                with (root / "core.log").open("w+") as log:
                    process = subprocess.Popen([core, "run", "-c", str(config_path), "-D", directory], stdout=log, stderr=log)
                    try:
                        deadline = time.monotonic() + 10
                        while True:
                            if process.poll() is not None:
                                raise AssertionError("fixture core exited before readiness")
                            try:
                                api(controller, "GET", "/proxies")
                                break
                            except (OSError, http.client.HTTPException):
                                if time.monotonic() >= deadline:
                                    raise
                                time.sleep(0.1)
                        probe(mixed, b"first-node")
                        api(controller, "PUT", "/proxies/proxy", {"name": "US-secondary"})
                        probe(mixed, b"selected-node")
                        # An explicit per-service pin still overrides proxy.
                        api(controller, "PUT", "/proxies/google-proxy", {"name": "US-test"})
                        probe(mixed, b"first-node")
                        api(controller, "PUT", "/proxies/google-proxy", {"name": "proxy"})
                        probe(mixed, b"selected-node")
                    except BaseException:
                        log.flush()
                        log.seek(0)
                        print(log.read(), file=sys.stderr)
                        raise
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
        finally:
            for server in (first, second):
                server.shutdown()
            for thread in threads:
                thread.join(timeout=2)
    print("Real sing-box: Google selector follows proxy changes and respects explicit per-service pins")


if __name__ == "__main__":
    main()
