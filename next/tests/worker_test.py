"""Exercise the real Rust supervisor with a harmless, local fake dataplane.
No network interface or routing command is executed by these tests.
"""
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import tempfile
import time
import unittest

BINARY = Path(__file__).resolve().parents[1] / 'target/debug/magicnet-cli'
FAKE = '''#!/usr/bin/python3
import json, os, signal, sys, time
if sys.argv[1] == 'check': sys.exit(0)
config=json.load(open(sys.argv[sys.argv.index('-c')+1]))
root=sys.argv[sys.argv.index('-D')+1]
mode=config.get('fixture',{})
def stop(*_):
    open(root+'/stop-observed','w').write(str(os.getpid()))
    time.sleep(mode.get('stop_delay',0))
    open(root+'/cleanup-complete','w').write('done')
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
open(root+'/child-ready','w').write(str(os.getpid()))
if mode.get('exit_immediately'): sys.exit(2)
if mode.get('noisy'): sys.stdout.write('x'*2000000); sys.stdout.flush()
while True: time.sleep(.02)
'''

class NativeWorker(unittest.TestCase):
    def setUp(self):
        # Unix-domain socket paths are intentionally short and private.
        self.temp=tempfile.TemporaryDirectory(prefix='mnw-')
        self.root=Path(self.temp.name)
        self.rpc_raw(['--initialize-candidate'])
        (self.root/'bin').mkdir()
        (self.root/'bin/sing-box').write_text(FAKE)
        (self.root/'bin/sing-box').chmod(0o700)
        self.owner=None

    def tearDown(self):
        # Only processes created by this fixture are eligible for cleanup.
        try:
            self.rpc('service.stop',timeout=20)
        except (subprocess.SubprocessError,AssertionError):
            pass
        self.temp.cleanup()

    def rpc_raw(self,args,body=None,timeout=20):
        result=subprocess.run([str(BINARY),'--root',str(self.root),*args],input=body,
                              capture_output=True,timeout=timeout)
        value=json.loads(result.stdout)
        self.assertEqual(result.returncode==0,value['ok'], result.stderr.decode())
        return value

    def rpc(self,method,params=None,timeout=20):
        current=self.rpc_raw(['settings'])['data']
        req={'schema':1,'id':secrets.token_hex(16),'method':method,
             'expected_revision':current['revision'],'params':params}
        return self.rpc_raw(['--experimental-runtime','--request-stdin'],json.dumps(req).encode(),timeout)

    def start(self,stop_delay=0,noisy=False):
        settings=self.rpc_raw(['settings'])['data']
        settings['template']['fixture']={'stop_delay':stop_delay,'noisy':noisy}
        self.assertTrue(self.rpc('settings.replace',settings)['ok'])
        reply=self.rpc('service.start')
        self.assertTrue(reply['ok'],reply)
        self.owner=json.loads((self.root/'.state/runtime.json').read_text())
        self.assertTrue((self.root/'child-ready').exists())

    def test_graceful_stop_waits_for_three_second_cleanup_and_is_idempotent(self):
        self.start(stop_delay=3)
        begin=time.monotonic()
        reply=self.rpc('service.stop')
        self.assertTrue(reply['ok'],reply)
        self.assertGreaterEqual(time.monotonic()-begin,2.9)
        self.assertEqual((self.root/'cleanup-complete').read_text(),'done')
        before=self.rpc_raw(['settings'])['data']['revision']
        self.assertTrue(self.rpc('service.stop')['ok'])
        self.assertEqual(self.rpc_raw(['settings'])['data']['revision'],before)

    def test_loud_child_cannot_fill_disk_or_block_stop(self):
        self.start(noisy=True)
        self.assertTrue(self.rpc('service.stop')['ok'])
        self.assertLessEqual((self.root/'.log/core.log').stat().st_size,512*1024)

    def test_worker_crash_requests_child_cleanup_without_pid_fallback(self):
        self.start(stop_delay=.2)
        pid=self.owner['identity']['pid']
        os.kill(pid, signal.SIGKILL)
        deadline=time.monotonic()+5
        while not (self.root/'cleanup-complete').exists() and time.monotonic()<deadline:
            time.sleep(.03)
        self.assertTrue((self.root/'cleanup-complete').exists())
        self.assertTrue(self.rpc('service.stop')['ok'])

    def test_subsequent_start_uses_a_new_worker_identity(self):
        self.start()
        old=self.owner['generation']
        self.assertTrue(self.rpc('service.stop')['ok'])
        # A normal subsequent start is a new generation; ownership is not
        # accidentally inherited from a stale worker record.
        self.assertTrue(self.rpc('service.start')['ok'])
        current=json.loads((self.root/'.state/runtime.json').read_text())
        self.assertNotEqual(old,current['generation'])
        self.assertNotEqual(self.owner['identity'],current['identity'])


    def test_failed_candidate_restarts_the_original_generation(self):
        self.start()
        original=self.owner.copy()
        settings=self.rpc_raw(['settings'])['data']
        settings['template']['fixture']={'exit_immediately':True}
        self.assertTrue(self.rpc('settings.replace',settings)['ok'])
        reply=self.rpc('service.start')
        self.assertFalse(reply['ok'])
        restored=json.loads((self.root/'.state/runtime.json').read_text())
        self.assertEqual(restored['generation'],original['generation'])
        self.assertNotEqual(restored['identity'],original['identity'])
        self.assertEqual(self.rpc_raw(['status'])['data']['phase'],'running')

    def test_recovery_reuses_a_crashed_generation_without_stale_socket_failure(self):
        self.start(stop_delay=.05)
        original=self.owner.copy()
        os.kill(original['identity']['pid'], signal.SIGKILL)
        deadline=time.monotonic()+5
        while not (self.root/'cleanup-complete').exists() and time.monotonic()<deadline:
            time.sleep(.03)
        self.assertTrue((self.root/'cleanup-complete').exists())
        # Crash left a real filesystem socket. A failed subsequent switch must
        # still be able to restore this exact, previously good generation.
        socket=self.root/'.state/control'/f"{original['generation']}.sock"
        self.assertTrue(socket.exists())
        (self.root/'.state/switch.json').write_text(json.dumps({
            'schema':1,'previous':original,'was_running':True,
            'candidate':secrets.token_hex(16)}))
        reply=self.rpc('runtime.recover')
        self.assertTrue(reply['ok'],reply)
        restored=json.loads((self.root/'.state/runtime.json').read_text())
        self.assertEqual(restored['generation'],original['generation'])
        self.assertNotEqual(restored['identity'],original['identity'])
        self.assertEqual(self.rpc_raw(['status'])['data']['phase'],'running')

    def test_unpublished_worker_gate_cannot_start_a_child(self):
        generation=secrets.token_hex(16)
        folder=self.root/'.state/generations'/generation
        folder.mkdir(parents=True)
        (folder/'config.json').write_text('{}')
        result=self.rpc_raw(['--worker',generation],b'')
        self.assertEqual(result['error']['code'],'start_cancelled')
        self.assertFalse((self.root/'child-ready').exists())

if __name__=='__main__': unittest.main()
