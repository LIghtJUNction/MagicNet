#!/usr/bin/env python3
"""Execute the production installer migration loops against private recovery records."""
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RELATIVE = Path(".state/network-access-recovery")


class RecoveryUpgradeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="magicnet-recovery-upgrade-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.previous, self.backup, self.module = [root / name for name in ("old", "backup", "new")]
        for directory in (self.previous, self.backup, self.module):
            directory.mkdir(mode=0o700)
        source = (ROOT / "src/MagicNet/customize.sh").read_text()
        snapshot = source.split("  # Snapshot the old full file for node recovery and a private rollback copy.\n", 1)[1]
        snapshot = snapshot.split("  MAGICNET_BACKUP_READY=1\n", 1)[0]
        restore = source.split('if [ "$MAGICNET_BACKUP_READY" = 1 ]; then\n', 1)[1]
        restore = restore.split("  unset _item\nfi", 1)[0]
        self.command = ('set -eu\nabort() { exit 31; }\n'
                        'MAGICNET_PREV_DIR=$1\nMAGICNET_BACKUP_DIR=$2\nMODPATH=$3\n'
                        + snapshot + restore)

    def migrate(self):
        return subprocess.run(["sh", "-c", self.command, "migration-test", str(self.previous),
                               str(self.backup), str(self.module)], capture_output=True,
                              text=True, timeout=10)

    def test_upgrade_retains_original_record_and_private_permissions(self):
        directory = self.previous / RELATIVE
        directory.mkdir(parents=True, mode=0o700)
        record = directory / ("a" * 64 + ".json")
        # Installer copies bytes; runtime validates the record before it can authorize rollback.
        contents = '{"schema":1,"before":4,"phase":"applied"}\n'
        record.write_text(contents)
        record.chmod(0o600)
        result = self.migrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        restored = self.module / RELATIVE / record.name
        self.assertEqual(restored.read_text(), contents)
        self.assertEqual(stat.S_IMODE(restored.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(restored.parent.stat().st_mode), 0o700)
        self.assertEqual(record.read_text(), contents)

    def test_older_release_without_recovery_does_not_create_fake_records(self):
        result = self.migrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.module / RELATIVE).exists())

    def test_symlink_recovery_source_aborts_instead_of_copying_another_directory(self):
        directory = self.previous / RELATIVE
        directory.parent.mkdir()
        sentinel = self.previous / "unrelated"
        sentinel.mkdir()
        (sentinel / "keep").write_text("untouched")
        directory.symlink_to(sentinel, target_is_directory=True)
        self.assertEqual(self.migrate().returncode, 31)
        self.assertEqual((sentinel / "keep").read_text(), "untouched")
        self.assertFalse((self.module / RELATIVE).exists())


if __name__ == "__main__":
    unittest.main()
