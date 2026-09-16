#!/usr/bin/env python3
"""Execute read-only collection against an owned dummy process, never a device."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
class SnapshotTests(unittest.TestCase):
    def check_snapshot(self, valid=True):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'bin').mkdir(); (root/'.config/sing-box').mkdir(parents=True)
            shutil.copy(ROOT/'src/MagicNet/feedback-snapshot.sh', root/'feedback-snapshot.sh')
            (root/'bin/jq').symlink_to(shutil.which('jq'))
            (root/'bin/sing-box').symlink_to(shutil.which('sleep'))
            proc=subprocess.Popen([str(root/'bin/sing-box'),'30'],env=dict(os.environ,GOMEMLIMIT='321MiB',PASSWORD='NEVER_EXPORT'))
            try:
                envelope={'schema':1,'ok':valid,'command':'service.status','data':{'core':{'sing_box':{'pid_summary':str(proc.pid)}}}}
                (root/'cli').write_text("#!/bin/sh\nprintf '%s' '"+json.dumps(envelope)+"'\n"); (root/'cli').chmod(0o755)
                for name,text in {'am':'echo 0','cmd':"printf 'package:com.android.vending uid:10123\\npackage:private.package uid:10124\\n'"}.items():
                    path=root/'bin'/name;path.write_text('#!/bin/sh\n'+text+'\n');path.chmod(0o755)
                config={'route':{'rule_set':[{}], 'rules':[{'package_name':['com.android.vending'],'outbound':'google-proxy'}]},'endpoints':[], 'password':'NEVER_EXPORT'}
                (root/'.config/sing-box/config.json').write_text(json.dumps(config))
                cp=subprocess.run(['sh',str(root/'feedback-snapshot.sh')],capture_output=True,text=True,env=dict(os.environ,PATH=str(root/'bin')+':'+os.environ['PATH']),timeout=15,check=True)
                self.assertNotIn('NEVER_EXPORT',cp.stdout);self.assertNotIn('private.package',cp.stdout)
                return json.loads(cp.stdout)
            finally:
                proc.terminate();proc.wait(timeout=5)
    def test_owned_process_is_measured_without_environment_or_config_secrets(self):
        result=self.check_snapshot()
        self.assertGreater(result['memory']['processes'][0]['rss_kib'],0)
        self.assertEqual(result['memory']['processes'][0]['go_knobs'],['GOMEMLIMIT=321MiB'])
        self.assertEqual(result['packages'],[{'package':'com.android.vending','uid':10123}])
        self.assertEqual(result['config']['rule_sets'],1)
    def test_invalid_machine_response_is_not_zero_memory_or_a_process_match(self):
        result=self.check_snapshot(False)
        self.assertEqual(result['memory']['measurement'],'unavailable')
        self.assertEqual(result['memory']['processes'],[])
if __name__=='__main__':unittest.main()
