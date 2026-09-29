#!/usr/bin/env python3
"""Integrity regressions for the locally built Android kernel cache."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('kernel_builder', Path(__file__).with_name('build-android-kernel.py'))
KERNEL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(KERNEL)


class KernelCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'bzImage').write_bytes(b'fixture-kernel')
        (self.root / 'build-info.txt').write_text('fixture metadata')
        self.manifest = dict(KERNEL.IDENTITY, sha256={
            name: KERNEL.digest(self.root / name) for name in ('bzImage', 'build-info.txt')})
        self.publish()

    def publish(self):
        (self.root / 'provenance.json').write_text(json.dumps(self.manifest))

    def test_complete_cache_verifies(self):
        self.assertEqual(KERNEL.verify(self.root), self.manifest)

    def test_altered_kernel_and_metadata_are_rejected(self):
        for name in ('bzImage', 'build-info.txt'):
            with self.subTest(name=name):
                original = (self.root / name).read_bytes()
                (self.root / name).write_bytes(b'tampered')
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    KERNEL.verify(self.root)
                (self.root / name).write_bytes(original)

    def test_wrong_source_identity_is_rejected_even_with_valid_hashes(self):
        for key in KERNEL.IDENTITY:
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = 'unreviewed'
                self.publish()
                with self.assertRaisesRegex(ValueError, 'source pins'):
                    KERNEL.verify(self.root)
                self.manifest[key] = original
        self.publish()

    def test_missing_empty_or_symlink_output_is_rejected(self):
        path = self.root / 'bzImage'
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            KERNEL.verify(self.root)
        path.touch()
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            KERNEL.verify(self.root)
        path.unlink()
        target = self.root / 'other-kernel'
        target.write_bytes(b'fixture-kernel')
        path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            KERNEL.verify(self.root)


if __name__ == '__main__':
    unittest.main()
