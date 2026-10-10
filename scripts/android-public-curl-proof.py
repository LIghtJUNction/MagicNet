#!/usr/bin/env python3
"""Local TLS controls for the guarded public-CI Android curl fixture.

The caller owns disposable-AVD, installed-byte and process attestation. This
module changes no module config, selector, core or trust store. A host-loopback
execution validates its logic only; it is not Android execution evidence.
"""
from __future__ import annotations

import gzip
import hashlib
import http.server
import os
from pathlib import Path
import secrets
import shlex
import shutil
import ssl
import subprocess
import tempfile
import threading
import time

MOD = '/data/adb/modules/MagicNet'
REMOTE = '/sdcard/Download/MagicNet/ci-simulation'
CURL = MOD + '/bin/curl'
KSU_DOMAIN = 'u:r:su:s0'
HOSTNAME = 'magicnet-curl-proof.test'
WRONG_HOSTNAME = 'wrong.magicnet-curl-proof.test'
TOTAL_SECONDS = 60
CLEANUP_SECONDS = 8
MAX_OUTPUT = 65536
EMBEDDED_CA_SIZE = 188900
EMBEDDED_CA_SHA256 = 'a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505'
# Fixed names only. Match trusted curl's proxy/loader/shell-hook clearing and
# additionally remove CA overrides so the last control tests embedded trust.
UNSET = (
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    'LD_PRELOAD', 'LD_LIBRARY_PATH', 'LD_AUDIT', 'LD_DEBUG',
    'LD_DYNAMIC_WEAK', 'LD_ORIGIN_PATH', 'LD_PROFILE', 'LD_SHOW_AUXV',
    'LD_TRACE_LOADED_OBJECTS', 'LD_USE_LOAD_BIAS', 'LD_VERBOSE', 'LD_WARN',
    'ENV', 'BASH_ENV', 'CDPATH', 'GCONV_PATH', 'NLSPATH', 'HOSTALIASES',
    'CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
)


def require(value, code):
    if not value:
        raise RuntimeError(code)


class Budget:
    def __init__(self):
        self.deadline = time.monotonic() + TOTAL_SECONDS

    def remaining(self, cap, *, cleanup=False):
        remaining = self.deadline - time.monotonic() - (0 if cleanup else CLEANUP_SECONDS)
        require(remaining > 0, 'curl_deadline')
        return min(cap, remaining)


def checked(cp, *, code, expected=0, max_output=MAX_OUTPUT):
    require(type(cp.returncode) is int and cp.returncode == expected, code)
    require(isinstance(cp.stdout, str) and isinstance(cp.stderr, str)
            and len(cp.stdout.encode('utf-8')) <= max_output
            and len(cp.stderr.encode('utf-8')) <= MAX_OUTPUT, 'curl_output_unknown')
    return cp.stdout


def clean_command(args):
    return 'unset ' + ' '.join(UNSET) + '; exec ' + shlex.join([CURL, '-q', *args])


def capabilities(device, budget):
    domain = device.kshell('id -Z', timeout=budget.remaining(5), check=False)
    require(checked(domain, code='curl_domain_unknown').strip() == KSU_DOMAIN, 'curl_domain_unknown')
    selector = ('MODDIR=' + shlex.quote(MOD) + '; . ' + shlex.quote(MOD + '/lib/magicnet/primitives.sh')
                + '; magicnet_trusted_curl')
    selected = device.kshell(selector, timeout=budget.remaining(5), check=False)
    require(checked(selected, code='curl_selector_unknown').strip() == CURL, 'curl_selector_mismatch')
    version = checked(device.kshell(clean_command(['--version']), timeout=budget.remaining(5), check=False),
                      code='curl_version_unknown')
    lines = version.splitlines()
    require(lines and lines[0].startswith('curl '), 'curl_version_unknown')
    protocols = [line.split(':', 1)[1].split() for line in lines if line.startswith('Protocols:')]
    features = [line.split(':', 1)[1].split() for line in lines if line.startswith('Features:')]
    require(len(protocols) == len(features) == 1 and 'https' in protocols[0]
            and {'SSL', 'libz'} <= set(features[0]), 'curl_capabilities_missing')
    help_text = checked(device.kshell(clean_command(['--help', 'all']),
                                     timeout=budget.remaining(5), check=False), code='curl_help_unknown')
    options = {word for line in help_text.splitlines() for word in line.split() if word.startswith('--')}
    require({'--resolve', '--compressed', '--max-filesize', '--proto', '--proto-redir'} <= options,
            'curl_options_missing')
    inspect_embedded_ca(device, budget)


def inspect_embedded_ca(device, budget):
    ca = checked(device.kshell(clean_command(['--dump-ca-embed']),
                              timeout=budget.remaining(5), check=False),
                 code='curl_embedded_ca_unknown', max_output=1024 * 1024).encode('utf-8')
    require(len(ca) == EMBEDDED_CA_SIZE and hashlib.sha256(ca).hexdigest() == EMBEDDED_CA_SHA256,
            'curl_embedded_ca_mismatch')


def reverse_pair(device, port, budget, *, cleanup=False):
    text = checked(device.run('reverse', '--list', timeout=budget.remaining(2, cleanup=cleanup),
                              check=False), code='curl_reverse_unknown')
    matches = []
    for line in text.splitlines():
        parts = line.split()
        require(len(parts) == 3, 'curl_reverse_unknown')
        if parts[1] == f'tcp:{port}':
            matches.append(parts[2])
    require(len(matches) <= 1, 'curl_reverse_unknown')
    return matches[0] if matches else None


def no_rebind_rejected(cp):
    """Only an isolated, known refusal proves creation did not take place.

    Ordinary exit 1 also covers lost ADB replies. Mixed or unknown diagnostics
    retain recovery ownership until the serialized caller's facts reconcile.
    """
    if type(cp.returncode) is not int or cp.returncode != 1:
        return False
    if not isinstance(cp.stdout, str) or not isinstance(cp.stderr, str):
        return False
    messages = [value.strip() for value in (cp.stdout, cp.stderr) if value.strip()]
    return len(messages) == 1 and messages[0] in {
        'cannot rebind existing socket', 'error: cannot rebind existing socket',
        'adb: error: cannot rebind existing socket',
    }


def certificate(work, budget):
    openssl = shutil.which('openssl')
    require(openssl is not None, 'curl_host_tls_unavailable')
    cert, key = work / 'public-test-ca.pem', work / 'private-server-key.pem'
    key.touch(mode=0o600, exist_ok=False)
    args = [openssl, 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
            '-nodes', '-days', '1', '-sha256', '-subj', '/CN=' + HOSTNAME,
            '-addext', 'subjectAltName=DNS:' + HOSTNAME,
            '-addext', 'basicConstraints=critical,CA:TRUE', '-keyout', str(key), '-out', str(cert)]
    checked(subprocess.run(args, capture_output=True, text=True, timeout=budget.remaining(8)),
            code='curl_host_tls_unavailable')
    require(key.is_file() and cert.is_file() and key.stat().st_mode & 0o777 == 0o600
            and 0 < cert.stat().st_size <= 16384, 'curl_host_tls_unknown')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(str(cert), str(key))
    return cert, context


class LocalServer(http.server.HTTPServer):
    def __init__(self, context, body):
        self.context = context
        self.body = gzip.compress(body, mtime=0)
        self.gets = 0
        self.counter_lock = threading.Lock()
        super().__init__(('127.0.0.1', 0), Handler)

    def get_request(self):
        stream, address = super().get_request()
        stream.settimeout(1)
        try:
            return self.context.wrap_socket(stream, server_side=True), address
        except BaseException:
            stream.close()
            raise

    def count(self):
        with self.counter_lock:
            return self.gets

    def handle_error(self, *_):
        # Rejected TLS peers can close before HTTP parsing. Never emit raw
        # loopback endpoints/tracebacks into the public CI artifact.
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with self.server.counter_lock:
            self.server.gets += 1
        if self.path != '/proof':
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Encoding', 'gzip')
        self.send_header('Content-Length', str(len(self.server.body)))
        self.end_headers()
        self.wfile.write(self.server.body)

    def log_message(self, *_):
        pass


def verify(device):
    require(getattr(device, 'verified', None) is True, 'curl_device_unverified')
    budget = Budget()
    server = thread = None
    ca_attempted = reverse_attempted = reverse_owned = False
    thread_started = False
    remote_ca = REMOTE + '/curl-proof-' + secrets.token_hex(16) + '.pem'
    port = None
    failure = None
    counts = []
    try:
        capabilities(device, budget)
        with tempfile.TemporaryDirectory(prefix='magicnet-curl-proof-') as directory:
            cert, context = certificate(Path(directory), budget)
            body = ('magicnet-local-tls-' + secrets.token_hex(32) + '\n').encode('ascii')
            expected_hash = hashlib.sha256(body).hexdigest()
            server = LocalServer(context, body)
            port = server.server_address[1]
            thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
            thread.start()
            thread_started = True
            checked(device.kshell('mkdir -p ' + shlex.quote(REMOTE),
                                  timeout=budget.remaining(5), check=False), code='curl_stage_failed')
            ca_attempted = True  # Even a failed push can leave our unique partial file.
            checked(device.run('push', str(cert), remote_ca,
                               timeout=budget.remaining(5), check=False), code='curl_stage_failed')
            require(reverse_pair(device, port, budget) is None, 'curl_reverse_collision')
            reverse_timeout = budget.remaining(5)
            reverse_attempted = True
            created = device.run('reverse', '--no-rebind', f'tcp:{port}', f'tcp:{port}',
                                 timeout=reverse_timeout, check=False)
            # An explicit rejection is not evidence that we own the mapping.
            # Reconcile only success or an unknown transport reply; callers
            # serialize operations on their disposable AVD.
            if no_rebind_rejected(created):
                reverse_attempted = False
            checked(created, code='curl_reverse_failed')
            require(reverse_pair(device, port, budget) == f'tcp:{port}', 'curl_reverse_unknown')
            reverse_owned = True
            common = ['--silent', '--show-error', '--fail', '--proxy', '', '--noproxy', '*',
                      '--connect-timeout', '3', '--max-time', '6', '--max-filesize', '4096',
                      '--proto', '=https', '--proto-redir', '=https', '--compressed']
            for hostname, trusted, expected_rc, code in (
                (HOSTNAME, True, 0, 'curl_tls_positive_failed'),
                (WRONG_HOSTNAME, True, 60, 'curl_hostname_reject_failed'),
                (HOSTNAME, False, 60, 'curl_default_trust_reject_failed'),
            ):
                before = server.count()
                args = common + ['--resolve', f'{hostname}:{port}:127.0.0.1']
                if trusted:
                    args += ['--cacert', remote_ca]
                args += ['--url', f'https://{hostname}:{port}/proof']
                cp = device.kshell(clean_command(args), timeout=budget.remaining(9), check=False)
                output = checked(cp, code=code, expected=expected_rc)
                delta = server.count() - before
                require(delta == (1 if expected_rc == 0 else 0), code)
                if expected_rc == 0:
                    require(hashlib.sha256(output.encode('utf-8')).hexdigest() == expected_hash,
                            'curl_gzip_body_mismatch')
                else:
                    require(output == '', code)
                counts.append(delta)
    except BaseException as error:
        failure = error if isinstance(error, RuntimeError) else RuntimeError('curl_proof_unknown')
    finally:
        # start() can spawn its thread and then be interrupted before returning.
        # The resource's observed identity, not only our assignment, owns cleanup.
        if thread is not None and thread.ident is not None:
            thread_started = True
        cleaned = True
        if reverse_attempted and not reverse_owned:
            try:
                pair = reverse_pair(device, port, budget, cleanup=True)
                if pair == f'tcp:{port}':
                    reverse_owned = True
                elif pair is not None:
                    cleaned = False  # Never remove a mapping with another target.
            except BaseException:
                cleaned = False
        if reverse_owned:
            try:
                require(reverse_pair(device, port, budget, cleanup=True) == f'tcp:{port}',
                        'curl_reverse_cleanup_failed')
                checked(device.run('reverse', '--remove', f'tcp:{port}',
                                   timeout=budget.remaining(3, cleanup=True), check=False),
                        code='curl_reverse_cleanup_failed')
                require(reverse_pair(device, port, budget, cleanup=True) is None,
                        'curl_reverse_cleanup_failed')
            except BaseException:
                cleaned = False
        if ca_attempted:
            try:
                checked(device.kshell('rm -f ' + shlex.quote(remote_ca) + ' && test ! -e ' + shlex.quote(remote_ca),
                                      timeout=budget.remaining(3, cleanup=True), check=False),
                        code='curl_ca_cleanup_failed')
            except BaseException:
                cleaned = False
        if server is not None:
            if thread_started:
                try:
                    stop = threading.Thread(target=server.shutdown, daemon=True)
                    stop.start()
                    stop.join(timeout=max(0, min(2, budget.deadline - time.monotonic())))
                    cleaned = cleaned and not stop.is_alive()
                except BaseException:
                    cleaned = False
            try:
                server.server_close()
            except BaseException:
                cleaned = False
        if thread_started:
            thread.join(timeout=max(0, min(1, budget.deadline - time.monotonic())))
            cleaned = cleaned and not thread.is_alive()
        if time.monotonic() > budget.deadline and failure is None:
            failure = RuntimeError('curl_deadline')
        if not cleaned:
            failure = RuntimeError('curl_cleanup_failed')
    if failure is not None:
        # Device exceptions can contain commands or raw output. Keep fixed codes only.
        code = str(failure)
        allowed = {'curl_deadline', 'curl_device_unverified', 'curl_domain_unknown',
                   'curl_selector_unknown', 'curl_selector_mismatch', 'curl_version_unknown',
                   'curl_capabilities_missing', 'curl_help_unknown', 'curl_options_missing',
                   'curl_embedded_ca_unknown', 'curl_embedded_ca_mismatch',
                   'curl_output_unknown', 'curl_host_tls_unavailable', 'curl_host_tls_unknown',
                   'curl_stage_failed', 'curl_reverse_failed', 'curl_tls_positive_failed',
                   'curl_reverse_unknown', 'curl_reverse_collision',
                   'curl_hostname_reject_failed', 'curl_default_trust_reject_failed',
                   'curl_gzip_body_mismatch', 'curl_cleanup_failed', 'curl_proof_unknown'}
        raise RuntimeError(code if code in allowed else 'curl_proof_unknown') from None
    require(counts == [1, 0, 0], 'curl_proof_unknown')
    return {'schema': 1, 'status': 'verified', 'https': True, 'ssl': True, 'resolve': True,
            'gzip': True, 'tls_positive': True, 'hostname_reject': True,
            'default_trust_reject': True, 'cleanup': True,
            'embedded_ca_identity': True, 'embedded_ca_bytes': EMBEDDED_CA_SIZE,
            'positive_gets': counts[0], 'hostname_reject_gets': counts[1], 'default_reject_gets': counts[2]}
