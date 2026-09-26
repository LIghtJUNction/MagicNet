import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('candidate_package',ROOT/'tools/package.py')
package=importlib.util.module_from_spec(spec); spec.loader.exec_module(package)


def fixture_elf(machine=62,loader=None):
    # Structural test input only; never run or upload these synthetic binaries.
    data=bytearray(64); data[:7]=b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HH',data,16,2,machine)
    if loader:
        struct.pack_into('<Q',data,32,64); struct.pack_into('<HH',data,54,56,1)
        header=bytearray(56);struct.pack_into('<I',header,0,3)
        struct.pack_into('<Q',header,8,120);struct.pack_into('<Q',header,32,len(loader))
        data.extend(header);data.extend(loader)
    return bytes(data)


class Packaging(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='mn-package-')
        self.root=Path(self.temp.name);self.runtime=self.root/'runtime';self.web=self.root/'web'
        self.runtime.mkdir();self.web.mkdir()
        for name in package.BINARIES:(self.runtime/name).write_bytes(fixture_elf())
        (self.web/'index.html').write_text('<!doctype html><title>fixture</title>')
    def tearDown(self):self.temp.cleanup()
    def build(self,name='candidate.zip'):
        return package.build(self.runtime,self.web,self.root/name,'x86_64-linux-android','2.0.0-test','a'*40)
    def test_deterministic_archive_and_checksums(self):
        self.assertEqual(self.build('one.zip'),self.build('two.zip'))
        with zipfile.ZipFile(self.root/'one.zip') as z:
            manifest=json.loads(z.read('manifest.json'))
            self.assertFalse(manifest['production'])
            for entry in manifest['files']:
                raw=z.read(entry['path']);self.assertEqual(len(raw),entry['size'])
                self.assertEqual(hashlib.sha256(raw).hexdigest(),entry['sha256'])
                self.assertEqual(stat.S_IMODE(z.getinfo(entry['path']).external_attr>>16),entry['mode'])
            self.assertEqual(set(package.HOOKS)-set(z.namelist()),set())
            self.assertFalse(any(name.startswith(('.config/','.state/','.env')) for name in z.namelist()))
    def test_reject_wrong_abi_before_publishing_output(self):
        (self.runtime/'sing-box').write_bytes(fixture_elf(183))
        with self.assertRaises(ValueError):self.build()
        self.assertFalse((self.root/'candidate.zip').exists())
    def test_reject_host_dynamic_loader_even_with_matching_cpu(self):
        (self.runtime/'curl').write_bytes(fixture_elf(loader=b'/lib64/ld-linux-x86-64.so.2\0'))
        with self.assertRaises(ValueError):self.build()
    def test_accept_android_linker_header(self):
        package.elf(fixture_elf(loader=b'/system/bin/linker64\0'),'x86_64-linux-android')
    def test_reject_linked_asset_and_private_file(self):
        (self.web/'leak.js').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):self.build()
        (self.web/'leak.js').unlink();(self.web/'.env').write_text('PRIVATE=fixture')
        with self.assertRaises(ValueError):self.build()
    def test_reject_linked_asset_directory(self):
        (self.web/'assets').symlink_to(self.runtime,target_is_directory=True)
        with self.assertRaises(ValueError):self.build()
    def test_reject_crlf_and_missing_runtime_dependency(self):
        (self.runtime/'yq').unlink()
        with self.assertRaises(FileNotFoundError):self.build()
        for hook in package.HOOKS:self.assertNotIn(b'\r',(ROOT/'module'/hook).read_bytes())
    def test_hook_syntax_and_single_dispatch(self):
        for name in package.HOOKS:
            subprocess.run(['/bin/sh','-n',str(ROOT/'module'/name)],check=True)
            if name!='customize.sh':
                text=(ROOT/'module'/name).read_text()
                self.assertEqual(text.count('exec '),1)
                self.assertNotIn('source ',text);self.assertNotIn('kill',text);self.assertNotIn('/data/adb/modules/MagicNet',text)
    def test_version_and_revision_are_not_shell_or_metadata_injection(self):
        with self.assertRaises(ValueError):package.inputs(self.runtime,self.web,'x86_64-linux-android','v1\nauthor=oops','a'*40)
        with self.assertRaises(ValueError):package.inputs(self.runtime,self.web,'x86_64-linux-android','v1','main')

if __name__=='__main__':unittest.main()
