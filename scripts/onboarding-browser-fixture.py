#!/usr/bin/env python3
"""JSON-line controller for the real BusyBox installer fixture used by Playwright.

Only temporary fixture URLs are used. No user configuration or network
subscription is read. Closing/resetting a session verifies listener cleanup.
"""
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('onboarding_contracts', ROOT / 'scripts/install-onboarding-test.py')
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
session = None


def emit(value):
    print(json.dumps(value), flush=True)


def close():
    global session
    if session is not None:
        try:
            if session.proc.poll() is None:
                os.killpg(session.proc.pid, signal.SIGTERM)
            session.wait(timeout=12)
        finally:
            session.close()
            session = None


def start():
    global session
    close()
    session = contracts.Session(timeout=180)
    return {'origin': f'http://127.0.0.1:{session.port}', 'token': session.token}


def state():
    output = session.root / '.config/sing-box/subscription.url'
    return {
        'value': output.read_text() if output.exists() else None,
        'mode': stat.S_IMODE(output.stat().st_mode) if output.exists() else None,
        'exit': session.proc.poll(),
    }


try:
    emit(start())
    for line in sys.stdin:
        request = json.loads(line)
        op = request['op']
        if op == 'reset':
            emit(start())
        elif op == 'state':
            emit(state())
        elif op == 'wait':
            code = session.wait(timeout=12)
            emit({**state(), 'exit': code})
        elif op == 'existing':
            (session.root / '.config/sing-box/subscription.url').write_text('https://existing.example.test/sub\n')
            emit(state())
        elif op == 'close':
            close()
            emit({'closed': True})
            break
        else:
            raise ValueError('unknown fixture operation')
except Exception as error:
    emit({'error': str(error)})
    raise
finally:
    close()
