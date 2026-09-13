#!/usr/bin/env python3
"""No-network regressions for the raw archive accepted by split packaging."""
import contextlib
import importlib.util
import io
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('packager', ROOT / 'scripts/package-components.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class ArchiveSafetyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'MagicNet.zip'
        self.entries = {
            'module.prop': (b'id=MagicNet\nversion=v1.4.8\nversionCode=148\n', stat.S_IFREG | 0o644),
            'customize.sh': (b'#!/bin/sh\nimport this\necho done\n', stat.S_IFREG | 0o644),
            'bin/magicnet-components': (b'bootstrap-fixture', stat.S_IFREG | 0o755),
            'bin/magicnet-cli': (b'cli-fixture', stat.S_IFREG | 0o755),
            'bin/sing-box': (b'core-fixture', stat.S_IFREG | 0o755),
        }

    def write(self):
        packager.write_zip(self.archive, self.entries)

    def split(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return packager.package(self.archive, 'LIghtJUNction/MagicNet')

    def reject_without_output(self):
        original = self.archive.read_bytes()
        with self.assertRaises(ValueError):
            self.split()
        self.assertEqual(self.archive.read_bytes(), original)
        self.assertEqual({p.name for p in self.root.iterdir()}, {'MagicNet.zip'})

    def test_internal_leaf_links_survive_packaging(self):
        self.entries['cli'] = (b'bin/magicnet-cli', stat.S_IFLNK | 0o777)
        self.entries['system/bin/sing-box'] = (b'../../bin/sing-box', stat.S_IFLNK | 0o777)
        self.write()
        self.split()
        for filename in ('MagicNet-core.zip', 'MagicNet-full.zip'):
            with zipfile.ZipFile(self.root / filename) as archive:
                self.assertTrue(stat.S_ISLNK(archive.getinfo('cli').external_attr >> 16))
                self.assertEqual(archive.read('system/bin/sing-box'), b'../../bin/sing-box')

    def test_escaping_absolute_and_malformed_links_are_rejected(self):
        for target in (b'/system/bin/sh', b'../../outside', b'../outside', b'bin\\outside',
                       b'', b'bin/file\x00', b'bin/file\n', b'\xff'):
            with self.subTest(target=target):
                self.entries['cli'] = (target, stat.S_IFLNK | 0o777)
                self.write()
                self.reject_without_output()

    def test_archive_cannot_write_through_internal_directory_link(self):
        self.entries['alias'] = (b'bin', stat.S_IFLNK | 0o777)
        self.entries['alias/unexpected'] = (b'payload', stat.S_IFREG | 0o644)
        self.write()
        self.reject_without_output()

    def test_parent_relative_link_cannot_escape_from_nested_path(self):
        self.entries['system/bin/escape'] = (b'../../../outside', stat.S_IFLNK | 0o777)
        self.write()
        self.reject_without_output()

    def test_total_size_is_checked_before_any_payload_read(self):
        self.write()
        with zipfile.ZipFile(self.archive) as archive:
            total = sum(info.file_size for info in archive.infolist())
        with patch.object(packager, 'MAX_UNCOMPRESSED', total - 1), \
                patch.object(zipfile.ZipFile, 'read', side_effect=AssertionError('payload read before size check')):
            self.reject_without_output()

    def test_single_compressed_member_is_limited(self):
        self.entries['oversized'] = (b'x' * 65536, stat.S_IFREG | 0o644)
        self.write()
        self.assertLess(self.archive.stat().st_size, 4096)
        with patch.object(packager, 'MAX_UNCOMPRESSED', 32768):
            self.reject_without_output()

    def test_removed_build_cache_links_never_reach_runtime_archives(self):
        self.entries['.local/state/cache-link'] = (b'/tmp/build-cache', stat.S_IFLNK | 0o777)
        self.write()
        self.split()
        with zipfile.ZipFile(self.root / 'MagicNet-full.zip') as archive:
            self.assertFalse(any(name.startswith('.local/state/') for name in archive.namelist()))


if __name__ == '__main__':
    unittest.main()
