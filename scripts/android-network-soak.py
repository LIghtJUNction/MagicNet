#!/usr/bin/env python3
"""Sustained, non-root Android HTTPS checks plus privacy-safe core telemetry.

Uses the test-only APK built by build-android-network-probe.sh. Does not change
selectors, configuration, network interfaces or the running core. Public target
URLs and device traffic are never written to the report. Use ANDROID_SERIAL to
select the physical device; this is deliberately separate from offline CI.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import shlex
import subprocess
import time

spec = importlib.util.spec_from_file_location(
    'benchmark', Path(__file__).with_name('android-network-benchmark.py'))
bench = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(bench)
MOD = '/data/adb/modules/MagicNet'


def root(command: str, strategy: str = 'su') -> str | None:
    try:
        shell = command if strategy == 'adb' else 'su -M -c ' + shlex.quote(command)
        result = subprocess.run(['adb', 'shell', shell],
                                capture_output=True, text=True, timeout=10)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def telemetry(root_mode: str = 'su') -> dict:
    try:
        envelope = json.loads(root(MOD + '/cli --json service status', root_mode) or '')
        if envelope.get('schema') != 1 or envelope.get('ok') is not True:
            raise ValueError('status')
        data = envelope['data']
        core = data['core']['sing_box']
        pid = core['pid_summary']
        if not isinstance(pid, str) or not pid.isdecimal():
            raise ValueError('pid')
        text = root(f'cat /proc/{pid}/stat; cat /proc/{pid}/status; '
                    f'ls -1 /proc/{pid}/fd; printf "\\nEND_FDS\\n"; '
                    f'cat /proc/{pid}/stat', root_mode)
        lines = (text or '').splitlines()
        # Re-read process generation after collecting resources: a reused PID
        # cannot turn an interrupted observation into a healthy sample.
        first = lines[0].rsplit(')', 1)[1].split()
        last = lines[-1].rsplit(')', 1)[1].split()
        if first[19] != last[19]:
            raise ValueError('generation')
        rss = threads = None
        fds = 0
        for line in lines[1:-2]:
            if line.startswith('VmRSS:'):
                rss = int(line.split()[1])
            elif line.startswith('Threads:'):
                threads = int(line.split()[1])
            elif line.isdecimal():
                fds += 1
        if rss is None or threads is None or fds == 0:
            raise ValueError('resources')
        transparent = data['transparent']
        return dict(known=True, pid=int(pid), generation=int(first[19]),
                    rss_kib=rss, threads=threads, fds=fds,
                    ready=data['readiness']['overall'] is True,
                    configured_mode=transparent['configured_mode'],
                    effective_mode=transparent['effective_mode'],
                    transition=transparent['transition'])
    except (ValueError, KeyError, TypeError, IndexError, AttributeError):
        return dict(known=False)


def evaluate(probes: list[dict], snapshots: list[dict], *, duration: float,
             elapsed: float, max_latency_ms: int, max_rss_growth_kib: int,
             max_fd_growth: int) -> dict:
    latencies = sorted(row['elapsed_ms'] for row in probes if row['ok'])
    known = [s for s in snapshots if s.get('known')]
    failures = sum(not row['ok'] for row in probes)
    slow = sum(value > max_latency_ms for value in latencies)
    identities = {(s['pid'], s['generation']) for s in known}
    readiness_losses = sum(not s['ready'] or s['configured_mode'] != s['effective_mode']
                           or s['transition'] != 'idle' for s in known)
    rss_growth = max((s['rss_kib'] for s in known), default=0) - known[0]['rss_kib'] if known else None
    fd_growth = max((s['fds'] for s in known), default=0) - known[0]['fds'] if known else None
    incomplete = (not probes or elapsed < duration or len(known) != len(snapshots)
                  or not known or any(not row['complete'] for row in probes))
    degraded = (failures or slow or readiness_losses or len(identities) != 1
                or (rss_growth is not None and rss_growth > max_rss_growth_kib)
                or (fd_growth is not None and fd_growth > max_fd_growth))
    return dict(verdict='INCOMPLETE' if incomplete else ('FAIL' if degraded else 'PASS'),
                elapsed_s=round(elapsed, 2), requested_duration_s=duration,
                probes=len(probes), failures=failures, slow_probes=slow,
                max_latency_ms=max(latencies, default=None),
                p95_latency_ms=latencies[math.ceil(len(latencies) * .95) - 1] if latencies else None,
                unknown_snapshots=len(snapshots) - len(known),
                core_generations=len(identities), readiness_losses=readiness_losses,
                peak_rss_growth_kib=rss_growth, peak_fd_growth=fd_growth)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--targets', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--duration', type=int, default=600)
    parser.add_argument('--interval', type=int, default=20)
    parser.add_argument('--timeout', type=int, default=12)
    parser.add_argument('--root-mode', choices=('su', 'adb'), default='su',
                        help='Root transport; adb requires an already-root adbd (CI AVD only)')
    parser.add_argument('--max-latency-ms', type=int, default=1500)
    parser.add_argument('--max-rss-growth-kib', type=int, default=65536)
    parser.add_argument('--max-fd-growth', type=int, default=256)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    # Invalidate both artifacts before input validation or device calls. A
    # failed new attempt must not retain an old PASS or an old sample window.
    (args.output / 'results.json').write_text(json.dumps(
        {'schema': 1, 'scope': 'installed_device_app_uid_https_soak',
         'summary': {'verdict': 'INCOMPLETE', 'reason': 'observation_pending'}},
        indent=2) + '\n')
    (args.output / 'samples.json').write_text(json.dumps(
        {'schema': 1, 'verdict': 'INCOMPLETE', 'probes': [], 'telemetry': []},
        indent=2) + '\n')
    if not (1 <= args.duration <= 86400 and 1 <= args.interval <= 60
            and 1 <= args.timeout <= 60 and args.max_latency_ms > 0
            and args.max_rss_growth_kib >= 0 and args.max_fd_growth >= 0):
        parser.error('invalid time or resource budget')
    os.environ['ANDROID_SERIAL'] = args.serial
    try:
        targets = bench.parse_targets(args.targets)
    except (OSError, ValueError):
        parser.error('invalid target corpus (URLs are not printed)')
    identity = bench.instrument(bench.COMPONENT, 'identity', 5)
    if not identity['ok']:
        print('Probe APK unavailable; install the test-only APK with adb install -t.')
        return 2
    if (root('id -u', args.root_mode) or '').strip() != '0':
        print('Selected root transport unavailable; no observation was started.')
        return 2
    started = time.monotonic()
    rows, snapshots = [], []
    interrupted = False
    try:
        cycle = 0
        while time.monotonic() - started < args.duration:
            cycle += 1
            cycle_started = time.monotonic()
            snapshot = telemetry(args.root_mode) | {'elapsed_s': round(cycle_started - started, 2)}
            snapshots.append(snapshot)
            for target in targets:
                result = bench.fetch_probe(bench.COMPONENT, target['url'], args.timeout, target['expected'])
                if result.get('uid') != identity['uid']:
                    result = bench.failure('app_uid_changed')
                row = {'id': target['id'], 'cycle': cycle,
                       'elapsed_s': round(time.monotonic() - started, 2)} | result
                rows.append(row)
                print(f"cycle={cycle} target={target['id']} ok={row['ok']} "
                      f"reason={row['reason']} latency_ms={row['elapsed_ms']}", flush=True)
            # Write each completed cycle so disconnects/interruption preserve
            # failures and cannot leave a stale PASS from an earlier run.
            (args.output / 'samples.json').write_text(json.dumps(
                {'schema': 1, 'verdict': 'INCOMPLETE', 'probes': rows,
                 'telemetry': snapshots}, indent=2) + '\n')
            delay = min(args.interval - (time.monotonic() - cycle_started),
                        args.duration - (time.monotonic() - started))
            if delay > 0:
                time.sleep(delay)
    except KeyboardInterrupt:
        interrupted = True
    snapshots.append(telemetry(args.root_mode) | {'elapsed_s': round(time.monotonic() - started, 2)})
    elapsed = time.monotonic() - started
    summary = evaluate(rows, snapshots, duration=args.duration, elapsed=elapsed,
                       max_latency_ms=args.max_latency_ms,
                       max_rss_growth_kib=args.max_rss_growth_kib,
                       max_fd_growth=args.max_fd_growth)
    if interrupted:
        summary['verdict'] = 'INCOMPLETE'
    report = {'schema': 1, 'scope': 'installed_device_app_uid_https_soak',
              'tun_path_proof': 'not_verified',
              'limits': {'latency_ms': args.max_latency_ms,
                         'rss_growth_kib': args.max_rss_growth_kib,
                         'fd_growth': args.max_fd_growth},
              'not_tested': ['authenticated_apps', 'udp_quic', 'network_handover',
                             'sleep_wake', 'all_app_uids', 'dns_leaks'],
              'summary': summary, 'probes': rows, 'telemetry': snapshots}
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    return 0 if summary['verdict'] == 'PASS' else (2 if summary['verdict'] == 'INCOMPLETE' else 1)


if __name__ == '__main__':
    raise SystemExit(main())
