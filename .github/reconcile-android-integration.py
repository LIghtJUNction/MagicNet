from pathlib import Path


def edit(path, old, new):
    p = Path(path)
    text = p.read_text()
    assert text.count(old) == 1, (path, old[:100], text.count(old))
    p.write_text(text.replace(old, new, 1))


p = 'scripts/android-device-simulation.py'
edit(p, 'four ABI-specific executables', 'all bundled ABI-specific executables')
text = Path(p).read_text()
a = text.index('# Production ships these as Android arm64-only')
b = text.index('PHASES =', a)
Path(p).write_text(text[:a] + "# Optional components must be replaced when present, never silently omitted.\nOPTIONAL_PAYLOADS = ('bin/ecapture', 'bin/proxylink')\n" + text[b:])
edit(p, "require(set(replacements) == set(PAYLOADS), 'exactly four ABI replacements are required')", "require(set(PAYLOADS) <= set(replacements) <= set(PAYLOADS + OPTIONAL_PAYLOADS),\n            'required ABI replacements missing or unknown replacement supplied')")
edit(p, "                'excluded_optional_arm64_sha256': {},\n", '')
edit(p, "require(set(PAYLOADS).issubset(names), 'production ZIP is missing runtime payloads')", "require(set(replacements).issubset(names), 'production ZIP is missing runtime payloads')\n            require(set(names).intersection(OPTIONAL_PAYLOADS) <= set(replacements),\n                    'bundled optional tool has no ABI replacement')")
text = Path(p).read_text()
a = text.index('                if item.filename in OPTIONAL_ARM64_HELPERS')
b = text.index("                if item.filename == 'cli':", a)
Path(p).write_text(text[:a] + text[b:])
edit(p, "        current = self.shell(KSUD + ' boot-info current-kmi', timeout=30).stdout.strip()", """        # A pristine AVD has no KernelSU BusyBox yet. Use the official embedded
        # asset, not a host binary or fake command, before boot-info/late-load.
        self.shell('mkdir -p /data/adb/ksu/bin')
        self.shell(KSUD + ' debug extract-binary busybox ' + BB, timeout=30)
        self.shell(f'chmod 0755 {BB} && {BB} --install -s /data/adb/ksu/bin')
        command = 'PATH=/data/adb/ksu/bin:/system/bin:/system/xbin ' + KSUD
        current = self.shell(command + ' boot-info current-kmi', timeout=30).stdout.strip()""")
edit(p, "supported = self.shell(KSUD + ' boot-info supported-kmis', timeout=30).stdout.split()", "supported = self.shell(command + ' boot-info supported-kmis', timeout=30).stdout.split()")
edit(p, "self.shell(KSUD + ' late-load', timeout=120)", "self.shell(command + ' late-load', timeout=120)")
edit(p, "    encoded = base64.b64encode(json.dumps(candidate).encode()).decode('ascii')\n", "    encoded = base64.b64encode(json.dumps(candidate).encode()).decode('ascii')\n    require(len(encoded) <= 6 * 1024 * 1024, 'upgrade fixture exceeds payload budget')\n")
edit(p, "    device.reboot()\n    require(device.kshell(f'cat {MOD}/.config/magicnet/ci-upgrade-marker').stdout == marker,", """    # Read the installer's actual staged result before activation. No reseeding.
    device.kshell(f'test -f {STAGED}/module.prop')
    verify_migrated_node(json.loads(device.kshell(f'cat {STAGED}/.config/sing-box/config.json').stdout,
                                   object_pairs_hook=unique_keys))
    require(device.kshell(f'cat {STAGED}/.config/magicnet/ci-upgrade-marker').stdout == marker,
            'staged upgrade lost user config')
    require(device.kshell(f'cat {STAGED}/.config/magicnet/network-policy.conf').stdout == before_policy,
            'staged upgrade changed network policy')
    device.reboot()
    require(device.kshell(f'cat {MOD}/.config/magicnet/ci-upgrade-marker').stdout == marker,""")
edit(p, "    return {'node_preserved': True, 'user_policy_preserved': True,", "    return {'node_preserved': True, 'staged_node_preserved': True,\n            'staged_policy_preserved': True, 'user_policy_preserved': True,")
edit(p, "                replacements.update({f'bin/{name}': tools / name for name in ('jq', 'yq')})", """                replacements.update({f'bin/{name}': tools / name for name in ('jq', 'yq')})
                with zipfile.ZipFile(source) as production:
                    replacements.update({name: tools / Path(name).name for name in OPTIONAL_PAYLOADS
                                         if name in production.namelist()})""")

p = '.github/workflows/android-kernelsu-acceptance.yml'
edit(p, '      - name: Download and verify official KernelSU userspace', '''      - name: Prepare complete x86_64 installation payloads
        shell: bash
        run: bash scripts/prepare-android-fixture-tools.sh "$RUNNER_TEMP/magicnet-x86-tools"

      - name: Download and verify official KernelSU userspace''')
edit(p, 'key: android-avd-v3-api35-google-apis-x86_64', 'key: android-avd-v4-api35-google-apis-x86_64-stock-late-load')

p = 'scripts/test-android-simulation-fixes.py'
text = Path(p).read_text()
a = text.index('    def test_exact_arm64_optional_helpers_are_excluded_and_attested')
b = text.index('    def test_directory_cannot_masquerade_as_cli_executable', a)
text = text[:a] + '''    def test_every_bundled_optional_helper_is_replaced_and_attested(self):
        entries = dict(self.entries)
        for name in SIM.OPTIONAL_PAYLOADS:
            entries[name] = (elf(183, name.encode()), stat.S_IFREG | 0o755)
            path = self.root / Path(name).name
            path.write_bytes(elf(62, name.encode() + b'-fixture'))
            self.replacements[name] = path
        report = self.build(entries)
        with zipfile.ZipFile(self.output) as z:
            for name in SIM.OPTIONAL_PAYLOADS:
                self.assertEqual(z.read(name), self.replacements[name].read_bytes())
                self.assertIn(name, report['payload_sha256'])
        self.assertNotIn('excluded_optional_arm64_sha256', report)

    def test_missing_optional_replacement_fails_instead_of_dropping_it(self):
        for name in SIM.OPTIONAL_PAYLOADS:
            for machine in (183, 62, 40):
                with self.subTest(name=name, machine=machine), self.assertRaisesRegex(RuntimeError, 'no ABI replacement'):
                    self.build(self.entries | {name: (elf(machine), stat.S_IFREG | 0o755)})
                self.assertFalse(self.output.exists())

    def test_wrong_arch_optional_replacement_still_fails(self):
        name = SIM.OPTIONAL_PAYLOADS[0]
        path = self.root / 'invalid'
        path.write_bytes(elf(183))
        self.replacements[name] = path
        with self.assertRaisesRegex(RuntimeError, 'invalid x86_64 ELF'):
            self.build(self.entries | {name: (elf(183), stat.S_IFREG | 0o755)})

    def test_unknown_foreign_helper_still_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'unreplaced foreign ELF'):
            self.build(self.entries | {'bin/other-helper': (elf(183), stat.S_IFREG | 0o755)})

''' + text[b:]
Path(p).write_text(text)
edit(p, "        self.rebooted = False\n", "        self.rebooted = False\n        self.staged = None\n")
edit(p, "        if command == 'cat ' + SIM.MOD + '/.config/magicnet/network-policy.conf':", """        if command == 'test -f ' + SIM.STAGED + '/module.prop':
            if self.staged is None:
                raise RuntimeError('staged install missing')
            return result()
        if command == 'cat ' + SIM.STAGED + '/.config/sing-box/config.json':
            return result(json.dumps(self.staged))
        if command == 'cat ' + SIM.STAGED + '/.config/magicnet/ci-upgrade-marker':
            return result('lost' if self.fault == 'staged-marker' else self.marker)
        if command == 'cat ' + SIM.STAGED + '/.config/magicnet/network-policy.conf':
            return result('changed\\n' if self.fault == 'staged-policy'
                          else 'MAGICNET_NETWORK_IPV6_POLICY=ipv4_only\\n')
        if command == 'cat ' + SIM.MOD + '/.config/magicnet/network-policy.conf':""")
edit(p, "            self.config = {'outbounds': [{'type': 'direct', 'tag': 'direct'}] + nodes,\n                           'route': {'final': 'proxy'}}", "            self.staged = {'outbounds': [{'type': 'direct', 'tag': 'direct'}] + nodes,\n                           'route': {'final': 'proxy'}}")
edit(p, "            if self.fault == 'drop-node':\n                self.config['outbounds'].pop()", "            if self.fault == 'drop-node':\n                self.staged['outbounds'].pop()")
edit(p, "                self.config['outbounds'][-1]['server_port'] += 1", "                self.staged['outbounds'][-1]['server_port'] += 1")
edit(p, "                self.config['outbounds'].append(copy.deepcopy(nodes[0]))", "                self.staged['outbounds'].append(copy.deepcopy(nodes[0]))")
edit(p, "        self.rebooted = True\n", "        self.rebooted = True\n        self.config = copy.deepcopy(self.staged)\n        if self.fault == 'activation-drop':\n            self.config['outbounds'].pop()\n")
edit(p, "        self.assertTrue(report['node_preserved'])", "        self.assertTrue(report['node_preserved'])\n        self.assertTrue(report['staged_node_preserved'])\n        self.assertTrue(report['staged_policy_preserved'])")
edit(p, "for fault in ('drop-node', 'change-node', 'duplicate-node'):", "for fault in ('drop-node', 'change-node', 'duplicate-node', 'activation-drop'):")
edit(p, "for fault in ('lose-policy', 'lose-marker', 'keep-standalone'):", "for fault in ('lose-policy', 'lose-marker', 'keep-standalone', 'staged-policy', 'staged-marker'):")
edit(p, 'class FailureGateTests(unittest.TestCase):', '''    def test_oversized_upgrade_never_creates_payload_or_installs(self):
        device = MemoryDevice()
        device.config['test-padding'] = 'x' * (6 * 1024 * 1024)
        with self.assertRaisesRegex(RuntimeError, 'payload budget'):
            SIM.upgrade_preservation(device)
        self.assertFalse(device.installed)
        self.assertEqual(device.buffers, {})
        self.assertFalse(any('payload create' in c for c in device.calls))


class BootstrapTests(unittest.TestCase):
    def bootstrap(self, fault=''):
        calls = []
        class Stub:
            verified = True
            late_load_on_reboot = False
            def shell(self, command, **kwargs):
                calls.append(command)
                if 'extract-binary' in command and fault == 'extract-failed':
                    raise RuntimeError('extract failed')
                if command == 'getenforce':
                    return result('Enforcing')
                if 'current-kmi' in command:
                    if not any('extract-binary busybox' in c for c in calls):
                        raise RuntimeError('missing embedded tools')
                    return result('android15-6.6')
                if 'supported-kmis' in command:
                    return result('android14-6.1' if fault == 'unsupported' else 'android15-6.6')
                if 'debug version' in command:
                    return result('Kernel Version: 0' if fault == 'no-kernel' else 'Kernel Version: 12345')
                return result()
            def kshell(self, command, **kwargs):
                if command == 'id -Z':
                    return result('u:r:shell:s0' if fault == 'wrong-domain' else 'u:r:ksu:s0')
                if command == 'getenforce':
                    return result('Permissive' if fault == 'permissive' else 'Enforcing')
                raise AssertionError(command)
        device = Stub()
        report = SIM.Device.late_load_kernelsu(device)
        return device, calls, report

    def test_official_busybox_precedes_kmi_and_real_late_load(self):
        device, calls, report = self.bootstrap()
        extract = next(i for i,c in enumerate(calls) if 'extract-binary busybox' in c)
        kmi = next(i for i,c in enumerate(calls) if 'current-kmi' in c)
        load = next(i for i,c in enumerate(calls) if c.endswith(' late-load'))
        self.assertLess(extract, kmi)
        self.assertLess(kmi, load)
        self.assertTrue(device.late_load_on_reboot)
        self.assertEqual(report['kmi'], 'android15-6.6')
        self.assertIn('PATH=/data/adb/ksu/bin:', calls[load])

    def test_bootstrap_preconditions_and_real_kernel_gate_still_fail(self):
        for fault in ('extract-failed', 'unsupported', 'no-kernel', 'wrong-domain', 'permissive'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                self.bootstrap(fault)


class FailureGateTests(unittest.TestCase):''')

p = 'scripts/test-android-simulation-workflow.py'
edit(p, '    def test_exact_serial_stock_kernel_and_enforcing_not_disabled(self):', '''    def test_complete_payload_preparation_cannot_be_skipped(self):
        step = self.step('Prepare complete x86_64 installation payloads')
        self.assertNotIn('if', step)
        self.assertNotIn('continue-on-error', step)
        self.assertIn('scripts/prepare-android-fixture-tools.sh', step['run'])
        self.assertEqual(self.step('Restore pristine Android AVD')['with']['key'],
                         self.step('Save pristine Android AVD')['with']['key'])

    def test_exact_serial_stock_kernel_and_enforcing_not_disabled(self):''')

p = 'docs/android-simulation.md'
edit(p, 'Only four ABI-specific executables are replaced in a **separate test ZIP**, before\ninstallation: CLI, sing-box, jq and yq.', 'All bundled ABI-specific executables are replaced in a **separate test ZIP**, before\ninstallation: CLI, sing-box, jq and yq, plus eCapture/Proxylink when present.\nThe extra payloads use verified release/source pins; missing replacements fail\npreparation instead of silently removing installed tools.')
edit(p, 'x86_64 `ksud` verifies', 'x86_64 `ksud` first extracts its own embedded BusyBox using `debug extract-binary`,\nthen verifies')
edit(p, 'Real reinstall/reboot preserves a marker inside the supported `.config/magicnet` migration scope; no re-seeding to hide data loss', 'Real reinstall checks the staged node, marker and policy before reboot, then checks the activated result; no re-seeding to hide data loss')
p = 'docs/android-simulation-fixture-repair.md'
text = Path(p).read_text()
a = text.index('The production module also ships')
b = text.index('\n\n', a)
text = text[:a] + '''The production module also ships `bin/ecapture` and `bin/proxylink`. The fixture
requires matching x86_64 replacements for every bundled helper and records each
replacement hash. It does not omit these installed components to make the test
pass. Payload preparation uses the reviewed eCapture release digest and the
production Proxylink source revision. Their actual capture/proxy operation is
outside this standalone TUN lifecycle test.''' + text[b:]
Path(p).write_text(text)
Path('scripts/android-simulation-upgrade.py').unlink()

p = 'scripts/test-android-device-simulation.py'
text = Path(p).read_text()
old = '''        def shell(command, **_):
            calls.append(command)
            values = {
                'getenforce': 'Enforcing\\n','''
new = '''        def shell(command, **_):
            command = command.removeprefix('PATH=/data/adb/ksu/bin:/system/bin:/system/xbin ')
            calls.append(command)
            values = {
                'mkdir -p /data/adb/ksu/bin': '',
                SIM.KSUD + ' debug extract-binary busybox ' + SIM.BB: '',
                f'chmod 0755 {SIM.BB} && {SIM.BB} --install -s /data/adb/ksu/bin': '',
                'getenforce': 'Enforcing\\n','''
assert text.count(old) == 2
Path(p).write_text(text.replace(old, new))
