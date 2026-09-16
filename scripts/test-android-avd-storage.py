#!/usr/bin/env python3
"""Execute AVD path and failure contracts; --sdk creates a disposable real AVD."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import yaml
ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/android-kernelsu-acceptance.yml'

def steps():
    return yaml.safe_load(WORKFLOW.read_text())['jobs']['android-kernelsu']['steps']

def script(name):
    return next(step['run'] for step in steps() if step.get('name') == name)

def execute(name, env, timeout=10):
    return subprocess.run(['bash', '-euo', 'pipefail', '-c', script(name)], env=env,
                          text=True, capture_output=True, timeout=timeout)

class AvdStorageTests(unittest.TestCase):
    def test_storage_is_pinned_before_cache_create_and_boot(self):
        names = [step.get('name') for step in steps()]
        for name in ('Restore pristine Android AVD', 'Create pristine Android 15 AVD', 'Boot Android with KernelSU kernel'):
            self.assertLess(names.index('Pin Android AVD storage'), names.index(name))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); home = root/'runner home'; envfile = root/'env'
            cp = execute('Pin Android AVD storage', dict(os.environ, HOME=str(home),
                ANDROID_AVD_HOME='/unrelated', GITHUB_ENV=str(envfile)))
            self.assertEqual(cp.returncode, 0, cp.stderr)
            self.assertEqual(envfile.read_text(), f'ANDROID_AVD_HOME={home}/.android/avd\n')
            self.assertTrue((home/'.android/avd').is_dir())

    def test_creation_validates_path_outputs_and_propagates_failures(self):
        for outcome in ('success', 'missing-config', 'missing-descriptor', 'wrong-path', 'failure'):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                root=Path(directory); home=root/'runner home'; tools=root/'bin'; tools.mkdir()
                path=tools/'sdkmanager';path.write_text('#!/bin/sh\nexit 0\n');path.chmod(0o755)
                path=tools/'avdmanager'
                path.write_text(f'#!{sys.executable}\n'+'''import os, pathlib, sys
args=sys.argv[1:]
assert args[:3]==['create','avd','--force']
assert '--path' in args
assert sys.stdin.read().strip()=='no'
outcome=os.environ['OUTCOME']
if outcome=='failure': sys.exit(19)
name=args[args.index('--name')+1]
path=pathlib.Path(args[args.index('--path')+1])
assert path==pathlib.Path(os.environ['HOME'])/'.android/avd'/(name+'.avd')
path.mkdir(parents=True,exist_ok=True)
if outcome!='missing-config': (path/'config.ini').write_text('avd.ini.encoding=UTF-8\\n')
if outcome!='missing-descriptor':
    (pathlib.Path(os.environ['ANDROID_AVD_HOME'])/(name+'.ini')).write_text('path='+('/wrong' if outcome=='wrong-path' else str(path))+'\\n')
''')
                path.chmod(0o755); avdhome=home/'.android/avd';avdhome.mkdir(parents=True)
                env=dict(os.environ,HOME=str(home),ANDROID_AVD_HOME=str(avdhome),
                         AVD_NAME='MagicNet_API_35',SYSTEM_IMAGE='system-images;android-35;google_apis;x86_64',
                         OUTCOME=outcome,PATH=str(tools)+':'+os.environ['PATH'])
                cp=execute('Create pristine Android 15 AVD',env)
                self.assertEqual(cp.returncode,0 if outcome=='success' else 19 if outcome=='failure' else 1,cp.stderr)
                config=avdhome/'MagicNet_API_35.avd/config.ini'
                self.assertEqual('hw.cpu.ncore=4' in (config.read_text() if config.exists() else ''),outcome=='success')

def sdk_smoke():
    # No pre-existing user AVD can be touched: HOME and all state are temporary.
    with tempfile.TemporaryDirectory(prefix='magicnet-avd-path-') as directory:
        root=Path(directory);home=root/'runner home';home.mkdir()
        pathfile=root/'path';envfile=root/'env'
        env=dict(os.environ,HOME=str(home),GITHUB_ENV=str(envfile),GITHUB_PATH=str(pathfile),
                 AVD_NAME='MagicNet_API_35',SYSTEM_IMAGE='system-images;android-35;google_apis;x86_64')
        for name, budget in (('Locate Android SDK tools',660),('Pin Android AVD storage',10),('Create pristine Android 15 AVD',1250)):
            cp=execute(name,env,budget)
            print(cp.stdout)
            if cp.returncode: raise RuntimeError(name+' failed: '+cp.stderr[-3000:])
            if pathfile.exists(): env['PATH']=':'.join(pathfile.read_text().splitlines())+':'+os.environ['PATH']
            if envfile.exists(): env.update(line.split('=',1) for line in envfile.read_text().splitlines())
        avdhome=Path(env['ANDROID_AVD_HOME']);config=avdhome/'MagicNet_API_35.avd/config.ini'
        assert config.is_file() and 'hw.cpu.ncore=4' in config.read_text()
        cp=subprocess.run(['avdmanager','list','avd'],env=env,capture_output=True,text=True,timeout=30,check=True)
        assert 'Name: MagicNet_API_35' in cp.stdout and str(config.parent) in cp.stdout
        report={'schema':1,'status':'PASS','scope':'real_SDK_AVD_creation_and_discovery',
                'source_commit':os.environ.get('GITHUB_SHA'),
                'config_sha256':hashlib.sha256(config.read_bytes()).hexdigest(),
                'not_tested':['kernel_boot','TUN','Play_GMS','physical_device']}
        out=ROOT/'artifacts/avd-storage.json';out.parent.mkdir(exist_ok=True);out.write_text(json.dumps(report,indent=2)+'\n')
        print('Real SDK created and discovered the AVD at the verified explicit path')

if __name__=='__main__':
    if sys.argv[1:]==['--sdk']: sdk_smoke()
    else: unittest.main()
