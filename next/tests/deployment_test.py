"""Host-level installer/hook contracts. These fixtures are not Android packages."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import unittest

BASE=Path(__file__).resolve().parents[1]
BINARY=BASE/'target/debug/magicnet-cli'
MARKER={'schema':1,'kind':'isolated-candidate','version':2}

class Deployment(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='mn-deploy-')
        self.root=Path(self.temp.name)/'target';self.root.mkdir()
        self.package(self.root)
    def tearDown(self):self.temp.cleanup()
    def package(self,root):
        (root/'bin').mkdir();(root/'webroot').mkdir()
        shutil.copyfile(BINARY,root/'bin/magicnet-cli')
        for name in ('sing-box','curl','yq'):shutil.copyfile('/bin/true',root/'bin'/name)
        for file in (root/'bin').iterdir():file.chmod(0o700)
        (root/'webroot/index.html').write_text('<!doctype html><title>Host fixture only</title>')
        for name in ('customize.sh','service.sh','boot-completed.sh','action.sh','uninstall.sh'):shutil.copyfile(BASE/'module'/name,root/name)
        (root/'.magicnet-candidate.json').write_text(json.dumps(MARKER))
        (root/'module.prop').write_text('id=MagicNetNext\n')
        (root/'module-id').write_text('MagicNetNext\n')
        (root/'abi').write_text('x86_64-linux-android\n')
        files=[]
        for p in sorted(root.rglob('*')):
            if p.is_file():
                data=p.read_bytes();files.append({'path':str(p.relative_to(root)),'size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'mode':0o755 if p.parent.name=='bin' or p.suffix=='.sh' else 0o644})
        (root/'manifest.json').write_text(json.dumps({'schema':1,'kind':'isolated-candidate','production':False,'module_id':'MagicNetNext','version':'2.0.0-test','revision':'a'*40,'abi':'x86_64-linux-android','files':files}))
    def command(self,*args,root=None,body=None):
        result=subprocess.run([str(BINARY),'--root',str(root or self.root),*args],input=body,capture_output=True,timeout=8)
        data=json.loads(result.stdout);self.assertEqual(data['ok'],result.returncode==0,result.stderr.decode())
        return data
    def configure(self,root,method,params):
        current=self.command('settings',root=root)['data']
        request={'schema':1,'id':secrets.token_hex(16),'method':method,'expected_revision':current['revision'],'params':params}
        reply=self.command('--request-stdin',root=root,body=json.dumps(request).encode());self.assertTrue(reply['ok'],reply)
    def previous(self):
        source=Path(self.temp.name)/'source';source.mkdir();self.package(source)
        self.assertTrue(self.command('--hook','install',root=source)['ok'])
        self.configure(source,'sources.replace',{'text':'https://example.test/private-fixture'})
        return source
    def test_install_verifies_assets_before_creating_intent(self):
        self.assertTrue(self.command('--hook','install')['ok'])
        self.assertFalse(self.command('settings')['data']['enabled'])
        self.assertFalse((self.root/'.state/runtime.json').exists())
    def test_corrupt_payload_is_rejected_without_partial_config(self):
        (self.root/'bin/yq').write_bytes(b'corrupt')
        self.assertEqual(self.command('--hook','install')['error']['code'],'invalid_package')
        self.assertFalse((self.root/'.config').exists())
    def test_reinstall_does_not_reset_saved_settings(self):
        self.assertTrue(self.command('--hook','install')['ok'])
        self.configure(self.root,'sources.replace',{'text':'https://saved.test/source'})
        before=(self.root/'.config/settings.json').read_bytes()
        self.assertTrue(self.command('--hook','install')['ok'])
        self.assertEqual(before,(self.root/'.config/settings.json').read_bytes())
    def test_reinstall_refuses_corrupt_settings_without_overwriting_them(self):
        self.assertTrue(self.command('--hook','install')['ok'])
        path=self.root/'.config/settings.json';path.write_text('{invalid')
        self.assertEqual(self.command('--hook','install')['error']['code'],'invalid_json')
        self.assertEqual(path.read_text(),'{invalid')
    def test_aggregate_manifest_budget_is_checked_before_payload_reads(self):
        path=self.root/'manifest.json';manifest=json.loads(path.read_text())
        for asset in manifest['files']:asset['size']=256*1024*1024
        path.write_text(json.dumps(manifest))
        self.assertEqual(self.command('--hook','install')['error']['code'],'invalid_package')
        self.assertFalse((self.root/'.config').exists())
    def test_upgrade_preserves_private_intent_not_worker_state(self):
        source=self.previous();(source/'.state/foreign.pid').write_text('1234')
        before=(source/'.config/settings.json').read_bytes()
        self.assertTrue(self.command('--hook','install','--upgrade-from',str(source))['ok'])
        self.assertEqual(before,(self.root/'.config/settings.json').read_bytes())
        self.assertEqual(before,(source/'.config/settings.json').read_bytes())
        self.assertFalse((self.root/'.state/foreign.pid').exists())
        self.assertTrue(self.command('--hook','install','--upgrade-from',str(source))['ok'])
    def test_upgrade_conflict_never_overwrites_the_target(self):
        source=self.previous();self.assertTrue(self.command('--hook','install')['ok'])
        self.configure(self.root,'sources.replace',{'text':'https://newer.test/source'})
        before=(self.root/'.config/settings.json').read_bytes()
        self.assertEqual(self.command('--hook','install','--upgrade-from',str(source))['error']['code'],'upgrade_conflict')
        self.assertEqual(before,(self.root/'.config/settings.json').read_bytes())
    def test_profile_symlink_is_not_followed(self):
        source=self.previous();(source/'.config/linked').symlink_to('/etc/passwd')
        self.assertEqual(self.command('--hook','install','--upgrade-from',str(source))['error']['code'],'unsafe_profile')
        self.assertFalse((self.root/'.config').exists())
    def test_legacy_production_root_is_not_silently_imported(self):
        source=self.previous();(source/'.magicnet-candidate.json').unlink()
        before=(source/'.config/settings.json').read_bytes()
        self.assertEqual(self.command('--hook','install','--upgrade-from',str(source))['error']['code'],'migration_required')
        self.assertEqual(before,(source/'.config/settings.json').read_bytes())
    def test_disabled_boot_and_service_hooks_do_not_spawn_a_core(self):
        self.assertTrue(self.command('--hook','install')['ok'])
        for hook in ('service','boot-completed','uninstall'):
            result=subprocess.run(['/bin/sh',str(self.root/f'{hook}.sh')],capture_output=True,timeout=5)
            self.assertTrue(json.loads(result.stdout)['ok'],result.stderr.decode())
        self.assertFalse((self.root/'.state/workers').exists())
    def test_unknown_hook_and_misplaced_upgrade_argument_are_rejected(self):
        self.assertEqual(self.command('--hook','unknown')['error']['code'],'unsupported_hook')
        self.assertEqual(self.command('status','--upgrade-from','/etc')['error']['code'],'invalid_arguments')
        self.assertFalse((self.root/'.state').exists())
    def test_installer_abi_check_runs_before_the_payload(self):
        script='''abort() { exit 42; }; ui_print() { :; }; set_perm() { :; }; set_perm_recursive() { :; }; . "$MODPATH/customize.sh"'''
        env={**os.environ,'MODPATH':str(self.root),'ARCH':'arm64'}
        result=subprocess.run(['/bin/sh','-c',script],env=env,capture_output=True,timeout=5)
        self.assertEqual(result.returncode,42)
        self.assertFalse((self.root/'.config').exists())

if __name__=='__main__':unittest.main()
