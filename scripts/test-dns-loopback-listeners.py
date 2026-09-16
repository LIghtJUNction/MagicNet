#!/usr/bin/env python3
"""Exercise the exact built core's dual-family local DNS listeners, TCP and UDP.

Only loopback sockets are used. No TUN, route, firewall, public DNS or app-account
changes. This is a listener regression, NOT Android/Google Play acceptance.
"""
import argparse
import json
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time

QUERY = b'\x19\x53\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00' + b'\x07example\x07invalid\x00\x00\x01\x00\x01'
ANSWER_IP = b'\xc0\x00\x02\x11'


def read_exact(sock, count):
    result = b''
    while len(result) < count:
        data = sock.recv(count - len(result))
        if not data:
            raise RuntimeError('premature DNS TCP EOF')
        result += data
    return result


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        request, sock = self.request
        if len(request) < 12:
            return
        # One controlled question, same transaction ID, no personal queries.
        response = request[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + request[12:]
        response += b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x00\x00\x04' + ANSWER_IP
        sock.sendto(response, self.client_address)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', required=True)
    args = parser.parse_args()
    core = str(Path(args.core).resolve())
    with socket.socket(socket.AF_INET6) as available:
        available.bind(('::1', 0))  # Required fixture support, never silently skip.
        port = available.getsockname()[1]
    server = socketserver.UDPServer(('127.0.0.1', 0), DNS)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='magicnet-dns-loopback-') as td:
            root = Path(td)
            config = {
                'log': {'level': 'error'},
                'inbounds': [
                    {'type': 'direct', 'tag': 'magicnet-dns-in', 'listen': '127.0.0.1', 'listen_port': port},
                    {'type': 'direct', 'tag': 'magicnet-dns6-in', 'listen': '::1', 'listen_port': port},
                ],
                'dns': {'servers': [{'type': 'udp', 'tag': 'fixture', 'server': '127.0.0.1',
                                     'server_port': server.server_address[1]}]},
                'route': {'rules': [{'inbound': ['magicnet-dns-in', 'magicnet-dns6-in'], 'action': 'hijack-dns'}]},
            }
            path = root / 'config.json'
            path.write_text(json.dumps(config))
            subprocess.run([core, 'check', '-c', str(path)], check=True, timeout=10)
            with (root / 'core.log').open('w') as log:
                process = subprocess.Popen([core, 'run', '-c', str(path)], stdout=log, stderr=log)
                try:
                    # Bounded startup wait only; each actual protocol check is a
                    # single outcome. A failed request cannot become a pass later.
                    deadline = time.monotonic() + 5
                    while True:
                        if process.poll() is not None:
                            raise RuntimeError('core exited before listener readiness')
                        try:
                            with socket.create_connection(('127.0.0.1', port), timeout=.2):
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                raise RuntimeError('DNS listener startup timeout') from None
                            time.sleep(.05)
                    for family, host in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
                        for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                            with socket.socket(family, kind) as client:
                                client.settimeout(3)
                                client.connect((host, port))
                                if kind == socket.SOCK_STREAM:
                                    client.sendall(struct.pack('!H', len(QUERY)) + QUERY)
                                    length = struct.unpack('!H', read_exact(client, 2))[0]
                                    assert 12 <= length <= 4096, 'DNS response length'
                                    response = read_exact(client, length)
                                else:
                                    client.send(QUERY)
                                    response = client.recv(4096)
                                assert response[:2] == QUERY[:2], 'DNS transaction mismatch'
                                assert response[3] & 15 == 0 and response[6:8] == b'\x00\x01', 'DNS response failure'
                                assert response[-4:] == ANSWER_IP, 'DNS answer mismatch'
                                print(f'PASS loopback DNS family={family.name} transport={kind.name}')
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    print('Scope: loopback DNS only; Android interception and Play/GMS NOT TESTED')


if __name__ == '__main__':
    main()
