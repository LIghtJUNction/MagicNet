#!/usr/bin/env python3
"""Regression for KernelSU's SKIPUNZIP module.prop lifecycle.

KernelSU reads module.prop to choose MODID, but with SKIPUNZIP=1 the installer
must still leave $MODPATH/module.prop in place. On upgrades KernelSU copies that
file during its post-customize bookkeeping. Do not pre-seed or restore it in the
test: doing so masked the real-device failure this regression covers.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "package_components", ROOT / "scripts/package-components.py"
)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)
SHELLS = [["sh"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "ash"])
if shutil.which("mksh"):
    SHELLS.append(["mksh"])


class KernelSUInstallerLifecycleTest(unittest.TestCase):
    def test_skipunzip_installer_leaves_module_prop_for_manager_bookkeeping(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "MagicNet-source.zip"
            helper = root / "magicnet-components"
            output = root / "dist"

            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o755)

            entries = {
                "module.prop": b"id=MagicNet\nname=MagicNet\nversion=v1.4.13\nversionCode=143\n",
                "customize.sh": b"export SKIPUNZIP=1\nimport rich\n",
                ".config/sing-box/config.json": b"{}\n",
                "bin/sing-box": b"sing-box",
                "bin/magicnet-cli": b"cli",
            }
            PACKAGE.write_zip(
                source,
                {
                    name: PACKAGE.zip_entry(name, data, 0o755 if name.startswith("bin/") else 0o644)
                    for name, data in entries.items()
                },
            )
            PACKAGE.split(source, helper, output, "LIghtJUNction/MagicNet", "arm64")
            archive = output / "magicnet_installer.zip"

            # KernelSU resolves MODID from the archive before customize.sh, but it
            # does not populate MODPATH when SKIPUNZIP=1. Keep MODPATH empty here.
            with zipfile.ZipFile(archive) as z:
                props = z.read("module.prop").decode()
                customize = root / "manager-customize.sh"
                customize.write_bytes(z.read("customize.sh"))
            modid = next(line.split("=", 1)[1] for line in props.splitlines() if line.startswith("id="))
            self.assertEqual(modid, "MagicNet")

            nvbase = root / "data/adb"
            modpath = nvbase / "modules_update" / modid
            active = nvbase / "modules" / modid
            modpath.mkdir(parents=True)
            active.mkdir(parents=True)
            self.assertFalse((modpath / "module.prop").exists())

            harness = r'''
set -eu
abort() { printf '%s\n' "$*" >&2; exit 1; }
import() { :; }
. "$CUSTOMIZE"
# KernelSU userspace/ksud/src/installer.sh performs this copy after customize
# for an existing module. This exact step failed on-device when module.prop was
# never extracted into modules_update/MagicNet.
[ -f "$MODPATH/module.prop" ] || abort "KernelSU post-customize module.prop missing"
[ ! -L "$MODPATH/module.prop" ] || abort "KernelSU module.prop became a symlink"
cp -af "$MODPATH/module.prop" "$ACTIVE/module.prop"
'''
            result = subprocess.run(
                ["sh", "-c", harness],
                env={
                    **os.environ,
                    "ZIPFILE": str(archive),
                    "MODPATH": str(modpath),
                    "ACTIVE": str(active),
                    "CUSTOMIZE": str(customize),
                    "MAGICNET_PREV_DIR": str(active),
                },
                text=True,
                capture_output=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((modpath / "module.prop").read_text(), props)
            self.assertEqual((active / "module.prop").read_text(), props)


class PackagedConfigLifecycleTest(unittest.TestCase):
    """Run the actual customize script and framework after real component staging.

    Host file utilities stand in for Android manager utilities. Only the core is
    a controlled validator; it requires the rule file beside the candidate.
    The separate real-core template test checks the release's full rule format.
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.helper = cls.root / "components-host"
        env = dict(os.environ, GO111MODULE="off", CGO_ENABLED="0")
        env.pop("GOOS", None)
        env.pop("GOARCH", None)
        subprocess.run(["go", "build", "-trimpath", "-o", str(cls.helper),
                        "./installer/components"], cwd=ROOT, env=env, check=True)
        module = ROOT / "src/MagicNet"
        cls.template = json.dumps({
            "dns": {"servers": []},
            "route": {"final": "proxy", "rule_set": [
                {"type": "local", "tag": "fixture", "format": "source", "path": "rules/fixture.json"}]},
            "outbounds": [{"type": "direct", "tag": "direct"},
                          {"type": "selector", "tag": "proxy", "outbounds": ["direct"]}],
        }).encode()
        entries = {
            "module.prop": b"id=MagicNet\nversion=v1.6.2\nversionCode=162\n",
            "customize.sh": (module / "customize.sh").read_bytes(),
            ".config/kamfw/.envrc": (module / ".config/kamfw/.envrc").read_bytes(),
            ".config/sing-box/config.json": cls.template,
            ".config/sing-box/rules/fixture.json": b'{"version":3,"rules":[{"domain_suffix":["example.invalid"]}]}',
            "bin/jq": Path(shutil.which("jq")).read_bytes(),
            "bin/sing-box": b'''#!/bin/sh
[ "${REJECT_CONFIG:-0}" != 1 ] || { echo fixture-secret >&2; exit 1; }
[ "$1" = check ] && [ "$2" = -c ] && [ "$4" = -D ] || exit 1
[ "$5" != "$MODPATH/.config/sing-box" ] || exit 1
"$MODPATH/bin/jq" -e '.version == 3' "$5/rules/fixture.json" >/dev/null || exit 1
"$MODPATH/bin/jq" -e 'type == "object"' "$3" >/dev/null
''',
            "bin/magicnet-cli": b"#!/bin/sh\nexit 0\n",
        }
        for file in (module / "lib").rglob("*"):
            if file.is_file() and (file.suffix in (".sh", ".jq") or file.name == ".kamfwrc"):
                entries[file.relative_to(module).as_posix()] = file.read_bytes()
        source = cls.root / "source.zip"
        PACKAGE.write_zip(source, {name: PACKAGE.zip_entry(name, data, 0o755 if name.startswith("bin/") else 0o644)
                                   for name, data in entries.items()})
        output = cls.root / "dist"
        arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
        manifest = PACKAGE.split(source, cls.helper, output, "LIghtJUNction/MagicNet", arch)
        cls.components = cls.root / "offline-components"
        cls.components.mkdir()
        for component in manifest["components"]:
            shutil.copyfile(output / component["asset"], cls.components / (component["sha256"] + ".zip"))
        cls.archives = {}
        wrapper = ("#!/bin/sh\nexec " + shlex.quote(str(cls.helper)) +
                   ' "$@" --offline --cache-dir "$TEST_COMPONENTS"\n').encode()
        for name in ("MagicNet-core.zip", "MagicNet-full.zip", "magicnet_installer.zip"):
            with zipfile.ZipFile(output / name) as archive:
                packaged = {info.filename: (info, archive.read(info)) for info in archive.infolist()}
            packaged[PACKAGE.HELPER] = PACKAGE.zip_entry(PACKAGE.HELPER, wrapper, 0o755)
            cls.archives[name] = cls.root / name
            PACKAGE.write_zip(cls.archives[name], packaged)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def install(self, root, name, shell, *, upgrade=False, rejected=False, expected_error=None,
                customize=None, before="", after=""):
        module = root / "modules_update/MagicNet"
        active = root / "modules/MagicNet"
        (module / "bin").mkdir(parents=True)
        # Match the manager's usable file utilities after kamfw sets a fixed PATH.
        # No config, rule, jq, sing-box or module metadata is pre-extracted.
        for utility in ("awk", "bash", "busybox", "cat", "chmod", "chown", "cmp", "cp", "cut", "date", "dirname",
                        "find", "grep", "head", "ln", "mkdir", "mktemp", "mv", "printf", "readlink", "rm", "rmdir", "sed",
                        "sh", "sleep", "sort", "stat", "tail", "timeout", "touch", "tr", "uname", "unzip", "wc", "zipinfo"):
            executable = shutil.which(utility)
            if executable:
                (module / "bin" / utility).symlink_to(executable)
        previous = b'{"outbounds":[{"type":"trojan","tag":"US saved","server":"node.invalid","server_port":443,"password":"fixture-secret"}]}'
        if upgrade:
            (active / ".config/sing-box").mkdir(parents=True)
            (active / ".config/sing-box/config.json").write_bytes(previous)
            (active / ".config/sing-box/subscription.url").write_bytes(b"https://subscription.invalid/example\n")
        script = root / "customize.sh"
        with zipfile.ZipFile(self.archives[name]) as archive:
            source = archive.read("customize.sh").decode()
            script.write_text(customize(source) if customize else source)
        harness = '''
abort() { printf '%s\\n' "$*" >&2; exit 1; }
set_perm() { chmod "$4" "$1"; }
set_perm_recursive() {
    find "$1" -type d -exec chmod "$4" '{}' +
    find "$1" -type f -exec chmod "$5" '{}' +
}
'''
        harness += before + '\n. "$TEST_SCRIPT"\n' + after
        result = subprocess.run(shell + ["-c", harness], capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, MODPATH=str(module), ZIPFILE=str(self.archives[name]),
                                         MAGICNET_PREV_DIR=str(active), MAGICNET_NONINTERACTIVE="1",
                                         MAGICNET_INSTALL_ONBOARDING="0",
                                         TEST_COMPONENTS=str(self.components), TEST_SCRIPT=str(script),
                                         TEST_ROOT=str(root),
                                         KAM_LANG="en", REJECT_CONFIG="1" if rejected else "0"))
        self.assertEqual(result.returncode == 0, not (rejected or expected_error), result.stdout + result.stderr)
        self.assertNotIn("fixture-secret", result.stdout + result.stderr)
        self.assertNotIn("[download]", result.stdout + result.stderr)
        if rejected:
            self.assertIn("phase=", result.stderr)
        elif expected_error:
            self.assertIn(expected_error, result.stdout + result.stderr)
        else:
            config = json.loads((module / ".config/sing-box/config.json").read_bytes())
            self.assertEqual(config["route"]["rule_set"][0]["path"], "rules/fixture.json")
            self.assertEqual((module / ".config/sing-box/config.json").stat().st_mode & 0o777, 0o600)
            if upgrade:
                self.assertTrue(any(node.get("server") == "node.invalid" for node in config["outbounds"]))
        if upgrade:
            self.assertEqual((active / ".config/sing-box/config.json").read_bytes(), previous)
        self.assertEqual(list(module.rglob(".install-template.*")), [])
        self.assertEqual(list(module.rglob("install-config.*")), [])
        return result

    def add_future_migration_item(self, source):
        """Add an allowlisted path once, as a future installer change would.

        Match a single existing entry rather than both migration loops. The
        old duplicated lists then reproduce a successful install losing state.
        """
        lines = source.splitlines(keepends=True)
        for index, line in enumerate(lines):
            if line.strip() in (".state/network-access-recovery", '".state/network-access-recovery" \\'):
                lines.insert(index, line.replace(".state/network-access-recovery", ".state/future-migration-fixture"))
                return "".join(lines)
        self.fail("installer migration entry not found")

    def seed_future_migration_item(self, root):
        directory = root / "modules/MagicNet/.state/future-migration-fixture"
        directory.mkdir(parents=True, mode=0o700)
        record = directory / "record.json"
        record.write_bytes(b'{"schema":1,"phase":"applied","before":4}\n')
        record.chmod(0o600)
        return record

    def test_one_migration_entry_restores_state_without_restoring_old_config(self):
        for name in self.archives:
            for shell in SHELLS:
                with self.subTest(archive=name, shell=shell), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    previous_record = self.seed_future_migration_item(root)
                    self.install(root, name, shell, upgrade=True, customize=self.add_future_migration_item,
                                 before=r'''
cp() {
    # The full old config is only a node-recovery/rollback input. Detect even
    # a temporary raw restore that a later template refresh could conceal.
    if [ "$#" = 3 ] && [ "$1" = -a ]; then
        case "$2" in
        "$MODPATH"/.install-backup.*/.config/sing-box/config.json)
            [ "$3" != "$MODPATH/.config/sing-box/config.json" ] || return 71 ;;
        esac
    fi
    command cp "$@"
}
''')
                    module = root / "modules_update/MagicNet"
                    restored = module / ".state/future-migration-fixture/record.json"
                    self.assertEqual(restored.read_bytes(), previous_record.read_bytes())
                    self.assertEqual(restored.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(restored.parent.stat().st_mode & 0o777, 0o700)
                    old_config = root / "modules/MagicNet/.config/sing-box/config.json"
                    rollback_config = module / ".config/sing-box/config.json.pre-upgrade"
                    self.assertEqual(rollback_config.read_bytes(), old_config.read_bytes())
                    self.assertEqual(rollback_config.stat().st_mode & 0o777, 0o600)
                    self.assertNotEqual((module / ".config/sing-box/config.json").read_bytes(), old_config.read_bytes())
                    self.assertEqual(list(module.glob(".install-backup.*")), [])

    def test_migration_blank_lines_never_copy_or_remove_module_roots(self):
        def add_blank_lines(source):
            # Exercise empty and whitespace-only lines at the start, middle,
            # and end. In particular, an empty item must never become MODPATH/.
            return (source.replace("MAGICNET_INSTALL_MIGRATION_ITEMS='", "MAGICNET_INSTALL_MIGRATION_ITEMS='\n \t\n", 1)
                    .replace("\n.state/network-access-recovery\n", "\n\n \t\n.state/network-access-recovery\n", 1)
                    .replace("\n.config/magicnet'", "\n.config/magicnet\n \t\n'", 1))

        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                old_file = root / "modules/MagicNet/unlisted-file"
                old_file.parent.mkdir(parents=True)
                old_file.write_bytes(b"old-unlisted\n")
                self.install(root, "magicnet_installer.zip", shell, upgrade=True,
                             customize=add_blank_lines, before=r'''
printf 'new-module-file\n' >"$MODPATH/new-module-file"
cp() {
    case "${2:-}" in
    "$MAGICNET_PREV_DIR/"|"$MODPATH"/.install-backup.*/) return 73 ;;
    esac
    command cp "$@"
}
''')
                module = root / "modules_update/MagicNet"
                self.assertEqual((module / "new-module-file").read_bytes(), b"new-module-file\n")
                self.assertTrue((module / "module.prop").is_file())
                self.assertFalse((module / "unlisted-file").exists())
                self.assertEqual(old_file.read_bytes(), b"old-unlisted\n")
                self.assertEqual(list(module.glob(".install-backup.*")), [])

    def test_new_migration_item_copy_errors_abort_the_installer(self):
        for phase, source, error in (
            ("backup", '"$MAGICNET_PREV_DIR/.state/future-migration-fixture"', "failed to back up"),
            ("restore", '"$MODPATH"/.install-backup.*/.state/future-migration-fixture', "failed to restore"),
        ):
            for shell in SHELLS:
                with self.subTest(phase=phase, shell=shell), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    record = self.seed_future_migration_item(root)
                    contents = record.read_bytes()
                    self.install(root, "magicnet_installer.zip", shell, upgrade=True,
                                 customize=self.add_future_migration_item,
                                 expected_error=error + " MagicNet migration data: .state/future-migration-fixture",
                                 before='cp() {\n'
                                        f'    case "${{2:-}}" in {source}) return 72 ;; esac\n'
                                        '    command cp "$@"\n}\n',
                                 after=': >"$TEST_ROOT/install-finished"\n')
                    self.assertEqual(record.read_bytes(), contents)
                    self.assertFalse((root / "install-finished").exists())
                    self.assertEqual(list((root / "modules_update/MagicNet").glob(".install-backup.*")), [])

    def test_new_migration_item_source_symlink_still_aborts(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                sentinel = root / "unrelated"
                sentinel.mkdir(mode=0o700)
                (sentinel / "keep").write_bytes(b"untouched\n")
                source = root / "modules/MagicNet/.state/future-migration-fixture"
                source.parent.mkdir(parents=True)
                source.symlink_to(sentinel, target_is_directory=True)
                self.install(root, "magicnet_installer.zip", shell, upgrade=True,
                             customize=self.add_future_migration_item,
                             expected_error="refusing unsafe symlink in MagicNet migration data: .state/future-migration-fixture")
                self.assertEqual((sentinel / "keep").read_bytes(), b"untouched\n")
                module = root / "modules_update/MagicNet"
                self.assertFalse((module / ".state/future-migration-fixture").exists())
                self.assertEqual(list(module.glob(".install-backup.*")), [])

    def test_packaged_fresh_install_and_upgrade(self):
        for name in self.archives:
            for upgrade in (False, True):
                for shell in SHELLS:
                    with self.subTest(archive=name, upgrade=upgrade, shell=shell), tempfile.TemporaryDirectory() as tmp:
                        self.install(Path(tmp), name, shell, upgrade=upgrade)

    def test_rejected_core_upgrade_leaves_previous_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.install(Path(tmp), "magicnet_installer.zip", ["sh"], upgrade=True, rejected=True)

    def test_recovery_preserves_manager_output_descriptor(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self.install(root, "magicnet_installer.zip", shell, before=r'''
BOOTMODE=false
OUTFD=9
exec 9>"$TEST_ROOT/manager-output"
printf 'manager-before\n' >&9
''', after='ui_print manager-after\n')
                output = (root / "manager-output").read_text()
                self.assertTrue(output.startswith("manager-before\n"))
                self.assertIn("ui_print MagicNet\nui_print\n", output)
                self.assertIn("ui_print manager-after\nui_print\n", output)
                log = (root / "modules_update/MagicNet/.log/kam.log").read_text()
                self.assertNotIn("manager-after", log)

    def test_busy_log_descriptors_preserve_all_manager_channels(self):
        # Occupied descriptors are real manager-owned files, not a mocked /proc.
        before = "\n".join(
            f'exec {fd}>"$TEST_ROOT/manager-fd-{fd}"\n'
            f"printf 'before-{fd}\\n' >&{fd}"
            for fd in range(3, 10)
        ) + "\nBOOTMODE=false\nOUTFD=9\n"
        after = "\n".join(
            f"printf 'after-{fd}\\n' >&{fd}" for fd in range(3, 10)
        ) + "\nui_print manager-after\n"
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self.install(root, "magicnet_installer.zip", shell, before=before, after=after)
                for fd in range(3, 10):
                    output = (root / f"manager-fd-{fd}").read_text()
                    self.assertTrue(output.startswith(f"before-{fd}\n"))
                    self.assertIn(f"after-{fd}\n", output)
                self.assertIn("ui_print manager-after\nui_print\n",
                              (root / "manager-fd-9").read_text())
                log = (root / "modules_update/MagicNet/.log/kam.log").read_text()
                self.assertIn("INFO:", log)
                self.assertNotIn("manager-after", log)

    def test_abort_logs_after_manager_removes_staging_without_recreating_it(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                result = self.install(root, "magicnet_installer.zip", shell,
                                      upgrade=True, rejected=True, before=r'''
TEST_HOST_PATH=$PATH
abort() {
    printf '%s\n' "$*" >&2
    # Keep a test-only hard link so Python can inspect the unlinked log inode.
    ln "$MODPATH/.log/kam.log" "$TEST_ROOT/removed-install.log" || exit 2
    rm -rf "$MODPATH" || exit 2
    # Host utilities were exposed through MODPATH/bin. Android's system
    # utilities survive manager removal; restore their host equivalents.
    PATH=$TEST_HOST_PATH
    export PATH
    log manager-removed-staging
    exit 1
}
''')
                self.assertIn("manager-removed-staging",
                              (root / "removed-install.log").read_text())
                self.assertFalse((root / "modules_update/MagicNet").exists())
                self.assertNotIn("cannot create", result.stderr)


if __name__ == "__main__":
    unittest.main()
