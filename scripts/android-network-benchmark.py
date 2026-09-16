#!/usr/bin/env python3
"""Bounded Android application-UID probes, never root wget/TUN assumptions.

The test-only APK uses the platform TLS verifier and a non-root app UID. Optional
--verify-tun adds an emulator-only positive/reject/positive sentinel transaction.
Public HTTPS success is not Google Play login/download or real-device acceptance.
"""
from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import statistics
import subprocess
import sys
import time
from typing import Any
from urllib.parse import urlsplit

PACKAGE = 'best.lmm.magicnet.probe'
COMPONENT = PACKAGE + '/.ProbeInstrumentation'
BODY_LIMIT = 2 * 1024 * 1024
SPEED_LIMIT = 8 * 1024 * 1024
REASONS = {
    'identity', 'https_response', 'https_prefix', 'sentinel', 'invalid_app_identity',
    'invalid_input', 'invalid_operation', 'interrupted', 'dns', 'tls', 'timeout',
    'connect', 'transport', 'unexpected_redirect', 'unsafe_redirect',
    'unexpected_http_status', 'unexpected_body', 'body_limit', 'short_body', 'sentinel_mismatch',
}


def adb_shell(command: str, timeout: int = 60, check: bool = False) -> subprocess.CompletedProcess[str]:
    try:
        cp = subprocess.run(['adb', 'shell', command], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        cp = subprocess.CompletedProcess(['adb'], 124, '')
    except OSError:
        cp = subprocess.CompletedProcess(['adb'], 127, '')
    if check and cp.returncode != 0:
        # Commands may carry config payloads; never include them or raw output.
        raise RuntimeError(f'adb operation failed (exit {cp.returncode})')
    return cp


def q(value: str) -> str:
    return shlex.quote(value)


def failure(reason: str, *, complete: bool = False, rc: int = 1) -> dict[str, Any]:
    return dict(ok=False, complete=complete, rc=rc, reason=reason, uid=None, http=0,
                redirects=0, received_bytes=0, elapsed_ms=0)


def no_duplicates(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate response key')
        value[key] = item
    return value


def decode_result(cp: subprocess.CompletedProcess[str], operation: str) -> dict[str, Any]:
    if cp.returncode != 0:
        return failure('adb_timeout' if cp.returncode == 124 else 'adb_transport', rc=cp.returncode)
    if len(cp.stdout) > 65536:
        return failure('invalid_response')
    prefix = 'INSTRUMENTATION_RESULT: magicnet_result='
    responses = [line[len(prefix):] for line in cp.stdout.splitlines() if line.startswith(prefix)]
    codes = [line.strip() for line in cp.stdout.splitlines() if line.startswith('INSTRUMENTATION_CODE:')]
    if len(responses) != 1 or codes != ['INSTRUMENTATION_CODE: -1']:
        return failure('invalid_response')
    try:
        value = json.loads(responses[0], object_pairs_hook=no_duplicates)
        if not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] != 1:
            raise ValueError('schema')
        if value.get('operation') != operation or value.get('reason') not in REASONS:
            raise ValueError('operation')
        for name in ('uid', 'http', 'redirects', 'received_bytes', 'elapsed_ms'):
            if type(value.get(name)) is not int or value[name] < 0:
                raise ValueError('number')
        if value['uid'] < 10000 or value['uid'] > 2147483647:
            raise ValueError('not an application UID')
        if type(value.get('ok')) is not bool or type(value.get('complete')) is not bool:
            raise ValueError('boolean')
        if value['ok'] and not value['complete']:
            raise ValueError('inconsistent result')
        if value['elapsed_ms'] > 65000 or value['received_bytes'] > SPEED_LIMIT + 1:
            raise ValueError('budget')
        if value['redirects'] > 5 or value['http'] > 599:
            raise ValueError('HTTP metadata')
        if value['ok'] and operation != 'identity' and value['elapsed_ms'] == 0:
            raise ValueError('timing')
        return {key: value[key] for key in ('ok', 'complete', 'reason', 'uid', 'http',
                'redirects', 'received_bytes', 'elapsed_ms')} | {'rc': 0 if value['ok'] else 1}
    except (ValueError, TypeError, KeyError):
        return failure('invalid_response')


def instrument(component: str, operation: str, timeout_s: int, **values: Any) -> dict[str, Any]:
    if component != COMPONENT or not 1 <= timeout_s <= 60:
        return failure('invalid_input')
    args = ['am', 'instrument', '-w', '-r', '-e', 'operation', operation,
            '-e', 'timeout_ms', str(timeout_s * 1000)]
    for key, value in values.items():
        args.extend(['-e', key, str(value)])
    args.append(component)
    cp = adb_shell(shlex.join(args), timeout=timeout_s + 10)
    result = decode_result(cp, operation)
    if not result['complete']:
        # Kill only our test application, not the core, unrelated apps or adbd.
        adb_shell('am force-stop ' + PACKAGE, timeout=5)
    return result


def fetch_probe(component: str, url: str, timeout_s: int, expected: str = '200',
                prefix_bytes: int = 0) -> dict[str, Any]:
    result = instrument(component, 'https', timeout_s, url=url, expected=expected,
                        prefix_bytes=prefix_bytes)
    if result['ok']:
        # Independent host assertions: a regression in the APK cannot silently
        # mark HTTP 200 as the expected 204, or a partial prefix as throughput.
        reason = 'https_prefix' if prefix_bytes else 'https_response'
        if result['reason'] != reason or result['http'] != int(expected):
            return failure('unexpected_http_status', complete=True)
        if expected == '204' and (result['redirects'] or result['received_bytes']):
            return failure('unexpected_body', complete=True)
        limit = prefix_bytes or BODY_LIMIT
        if result['received_bytes'] > limit or (prefix_bytes and result['received_bytes'] != prefix_bytes):
            return failure('short_or_oversized_body', complete=True)
    return result


def speed_probe(component: str, name: str, url: str, bytes_target: int, timeout_s: int) -> dict[str, Any]:
    result = fetch_probe(component, url, timeout_s, '200', bytes_target)
    mbps = None
    if result['ok'] and result['elapsed_ms'] > 0:
        mbps = round(result['received_bytes'] * 8 / result['elapsed_ms'] / 1000, 3)
    return result | dict(name=name, requested_bytes=bytes_target, mbps=mbps,
                         scope='bounded_https_prefix')


def parse_targets(path: Path) -> list[dict[str, str]]:
    if path.stat().st_size > 128 * 1024:
        raise ValueError('oversized target corpus')
    targets = []
    seen = set()
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split('|')
        if len(parts) != 4:
            raise ValueError('invalid target row')
        target_id, category, url, expected = parts
        parsed = urlsplit(url)
        if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', target_id) or target_id in seen:
            raise ValueError('invalid or duplicate target id')
        if not re.fullmatch(r'[a-z0-9_-]{1,64}', category) or expected not in ('200', '204'):
            raise ValueError('invalid target category or expected status')
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None or '@' in url:
            raise ValueError('HTTPS targets without credentials are required')
        if len(url) > 2048 or re.search(r'[\s\x00-\x1f\x7f]', url):
            raise ValueError('invalid target URL')
        if parsed.port is not None and not 1 <= parsed.port <= 65535:
            raise ValueError('invalid target port')
        seen.add(target_id)
        targets.append(dict(id=target_id, category=category, url=url, expected=expected))
    if not 1 <= len(targets) <= 64:
        raise ValueError('empty or oversized target corpus')
    return targets


def median(values: list[int]) -> float | None:
    return round(statistics.median(values), 2) if values else None


def collect_processes(bb: str) -> dict[str, Any]:
    result = {}
    for name in ('sing-box', 'magicnet-cli'):
        cp = adb_shell(f'{bb} pidof {q(name)}', timeout=5)
        if cp.returncode not in (0, 1):
            result[name] = None
            continue
        entries = []
        for pid in cp.stdout.split()[:16]:
            if not pid.isdigit():
                continue
            status = adb_shell(f'cat /proc/{pid}/status', timeout=5)
            entry: dict[str, Any] = {'pid': int(pid)}
            for line in status.stdout.splitlines():
                key, _, value = line.partition(':')
                if key in ('VmRSS', 'VmHWM', 'VmSize', 'Threads'):
                    entry[key] = value.strip()
            entries.append(entry)
        result[name] = entries
    return {'processes': result}


def process_rss_kb(snapshot: dict[str, Any], name: str) -> int | None:
    entries = snapshot.get('processes', {}).get(name)
    if not entries:
        return None
    values = []
    for entry in entries:
        match = re.fullmatch(r'([0-9]+) kB', str(entry.get('VmRSS', '')))
        if not match:
            return None
        values.append(int(match[1]))
    return sum(values)


def verify_tun_path() -> dict[str, Any]:
    path = Path(__file__).with_name('android-tun-proof.py')
    spec = importlib.util.spec_from_file_location('tun_proof', path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.verify(adb_shell, instrument, COMPONENT)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--targets', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--strict-external', action='store_true',
                        help='Compatibility flag; every failed target/round now fails, with or without this flag')
    parser.add_argument('--speed', action='store_true')
    parser.add_argument('--verify-tun', action='store_true', help='Run emulator-only, reversible TUN sentinel proof')
    parser.add_argument('--timeout', type=int, default=20)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 10 or not 1 <= args.timeout <= 60:
        parser.error('rounds must be 1..10 and timeout 1..60')
    try:
        targets = parse_targets(args.targets)
    except (OSError, ValueError):
        parser.error('invalid or unreadable target corpus (URLs are not printed)')
    args.output.mkdir(parents=True, exist_ok=True)
    identity = instrument(COMPONENT, 'identity', 5)
    proof = verify_tun_path() if args.verify_tun and identity['ok'] else {'status': 'not_verified'}
    before = collect_processes('/data/adb/ksu/bin/busybox')
    records = []
    for target in targets:
        for round_no in range(1, args.rounds + 1):
            result = fetch_probe(COMPONENT, target['url'], args.timeout, target['expected']) if identity['ok'] else failure('probe_app_unavailable')
            if result['uid'] is not None and result['uid'] != identity.get('uid'):
                result = failure('app_uid_changed')
            # A user-supplied URL may include a private path; only IDs are persisted.
            record = {key: target[key] for key in ('id', 'category', 'expected')} | {'round': round_no} | result
            records.append(record)
            print(f"[{target['category']}] {target['id']} round={round_no} ok={result['ok']} reason={result['reason']}")
    speed_records = []
    if args.speed:
        for name, url in (
            ('global-cloudflare-8MiB', 'https://speed.cloudflare.com/__down?bytes=8388608'),
            ('domestic-tuna-8MiB', 'https://mirrors.tuna.tsinghua.edu.cn/iina/IINA.v1.4.4.dmg'),
        ):
            result = speed_probe(COMPONENT, name, url, SPEED_LIMIT, 45) if identity['ok'] else failure('probe_app_unavailable') | dict(name=name, requested_bytes=SPEED_LIMIT, mbps=None)
            if result.get('uid') is not None and result['uid'] != identity.get('uid'):
                result.update(ok=False, complete=False, reason='app_uid_changed')
            speed_records.append(result)
    after = collect_processes('/data/adb/ksu/bin/busybox')
    per_target = []
    for target in targets:
        rows = [row for row in records if row['id'] == target['id']]
        successes = [row for row in rows if row['ok']]
        per_target.append(dict(id=target['id'], category=target['category'], expected=target['expected'],
                               rounds=len(rows), successes=len(successes),
                               success_rate=round(len(successes) / len(rows), 4),
                               median_latency_ms=median([row['elapsed_ms'] for row in successes])))
    complete = all(row['complete'] for row in records + speed_records)
    passed = all(row['ok'] for row in records + speed_records)
    if args.verify_tun and proof.get('status') != 'verified':
        complete = passed = False
    verdict = 'PASS' if passed else ('FAIL' if complete else 'INCOMPLETE')
    summary = dict(schema=1, scope='anonymous_app_uid_https', verdict=verdict,
                   rounds=args.rounds, strict_external=True, target_count=len(targets),
                   probe_count=len(records), success_count=sum(row['ok'] for row in records),
                   tun_proof=proof,
                   not_tested=['authenticated_apps', 'play_downloads', 'udp_quic', 'dns_leaks',
                               'network_handover', 'real_device', 'ipv6', 'sleep_wake', 'all_app_uids']
                               + ([] if args.speed else ['throughput']),
                   sing_box_rss_kb_before=process_rss_kb(before, 'sing-box'),
                   sing_box_rss_kb_after=process_rss_kb(after, 'sing-box'),
                   speed=speed_records, targets=per_target)
    source = os.environ.get('GITHUB_SHA', '')
    if re.fullmatch('[0-9a-f]{40}', source):
        summary['source_commit'] = source
    for name, value in (('results.json', summary), ('process-before.json', before), ('process-after.json', after)):
        (args.output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    with (args.output / 'probes.csv').open('w', newline='', encoding='utf-8') as handle:
        writer = csv.DictWriter(handle, fieldnames=['id', 'category', 'expected', 'round', 'ok',
            'complete', 'reason', 'uid', 'http', 'redirects', 'received_bytes', 'elapsed_ms', 'rc'])
        writer.writeheader()
        writer.writerows(records)
    md = ['# Android application-UID HTTPS probes', '',
          f"Result: **{verdict}**. TUN sentinel: **{proof.get('status', 'not_verified')}**.",
          'Every target and every round counts. A later success never erases a failure.', '',
          '| Target | Class | Success | Median latency |', '|---|---|---:|---:|']
    for row in per_target:
        latency = str(row['median_latency_ms']) + ' ms' if row['median_latency_ms'] is not None else 'unknown'
        md.append(f"| {row['id']} | {row['category']} | {row['successes']}/{row['rounds']} | {latency} |")
    for row in speed_records:
        md.append(f"\nThroughput {row['name']}: {'PASS' if row['ok'] else 'FAIL'} ({row['reason']}).")
    md += ['', '**NOT TESTED:** Play app login/downloads, GMS, UDP/QUIC, DNS leaks, handover, user-device behavior.',
           'The sentinel proves only this test UID/TCP path in the emulator, not all app routing or proxy-provider compatibility.', '']
    (args.output / 'summary.md').write_text('\n'.join(md), encoding='utf-8')
    return 0 if passed else (1 if complete else 2)


if __name__ == '__main__':
    raise SystemExit(main())
