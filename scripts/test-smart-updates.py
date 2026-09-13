#!/usr/bin/env python3
"""Smart installer identity and fail-closed release wiring regressions."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zipfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('smart_installer', ROOT / 'scripts/package-smart-installer.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class SmartInstallerTests(unittest.TestCase):
    def test_package_and_existing_manager_isolation_regressions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            helper = root / 'helper'
            # Only an ELF identity fixture; this test does not claim Android execution.
            binary = bytearray(64)
            binary[:4] = b'\x7fELF'
            struct.pack_into('<H', binary, 18, 183)
            helper.write_bytes(binary)
            output = root / 'magicnet_installer.zip'
            package.package(helper, output)
            with zipfile.ZipFile(output) as archive:
                prop = archive.read('module.prop')
                self.assertIn(b'name=MagicNet Installer\n', prop)
                self.assertIn(b'version=1.1.0\n', prop)
                self.assertEqual(archive.read('bin/module-downloader'), binary)
                self.assertEqual(json.loads(archive.read('download.json'))['asset'], 'MagicNet-core.zip')
            subprocess.run(['python3', str(ROOT / 'scripts/test-downloader-installer.py'), str(output)], check=True)

    def test_non_android_helper_is_rejected_before_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            helper = root / 'helper'
            helper.write_text('not an Android binary')
            with self.assertRaises(ValueError):
                package.package(helper, root / 'installer.zip')
            self.assertFalse((root / 'installer.zip').exists())

    def test_installer_shares_module_helper_and_signing_quality_gate(self):
        build = yaml.safe_load((ROOT / '.github/workflows/exec.yml').read_text())['jobs']['build']
        steps = build['steps']
        package_step = next(s for s in steps if s.get('name') == 'Package core, components and offline full module')
        sign_step = next(s for s in steps if s.get('name') == 'Sign and verify final release assets')
        gate = next(s for s in steps if s.get('id') == 'release_quality')
        publish = next(s for s in steps if s.get('name') == 'Create GitHub release')
        self.assertIn('package-smart-installer.py --helper "$RUNNER_TEMP/magicnet-components"', package_step['run'])
        self.assertIn('test-downloader-installer.py dist/magicnet_installer.zip', package_step['run'])
        self.assertLess(steps.index(package_step), steps.index(sign_step))
        self.assertLess(steps.index(sign_step), steps.index(gate))
        self.assertIn("steps.release_quality.outcome == 'success'", publish['if'])
        self.assertIn('dist/*', publish['run'])
        template_workflow = (ROOT / '.github/workflows/downloader-template.yml').read_text()
        self.assertNotIn('tag="magicnet-installer-', template_workflow)

    def test_scheduler_is_device_side_not_a_webui_timer(self):
        phases = (ROOT / 'src/MagicNet/lib/magicnet/phases.sh').read_text()
        engine = (ROOT / 'installer/components/update_service.go').read_text()
        self.assertIn('"${MODDIR}/bin/magicnet-components" update daemon', phases)
        self.assertIn('daemon.lock', engine)
        self.assertIn('operation.lock', engine)
        self.assertIn('module manager installation failed', engine)
        self.assertNotIn('"reboot"', engine)
        self.assertIn('Enabled: false', engine)
        self.assertIn('WifiOnly: true', engine)


if __name__ == '__main__':
    unittest.main()
