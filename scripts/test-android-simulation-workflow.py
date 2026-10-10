#!/usr/bin/env python3
"""Prevent accidental bypasses of automatic Android/KernelSU acceptance."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
import zipfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / '.github/workflows'


def load(name):
    # BaseLoader deliberately keeps YAML 1.1's 'on' key a string.
    return yaml.load((WORKFLOWS / name).read_text(), Loader=yaml.BaseLoader)


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.flow = load('android-kernelsu-acceptance.yml')
        self.jobs = self.flow['jobs']
        self.steps = self.jobs['android-kernelsu']['steps']

    def step(self, name):
        return next(step for step in self.steps if step.get('name') == name)

    def test_every_change_can_trigger_acceptance_including_merge_queue(self):
        self.assertTrue({'pull_request', 'merge_group', 'push', 'workflow_dispatch'} <= self.flow['on'].keys())
        self.assertIn('main', self.flow['on']['push']['branches'])
        self.assertFalse(self.flow['on']['pull_request'])  # no path-filter bypass
        self.assertNotIn('pull_request_target', self.flow['on'])
        self.assertEqual(self.flow['permissions'], {'contents': 'read'})

    def test_harness_is_uncached_prerequisite(self):
        self.assertEqual(self.jobs['android-kernelsu']['needs'], 'harness')
        harness = self.jobs['harness']['steps']
        self.assertTrue(any('test-android-device-simulation.py' in s.get('run', '') for s in harness))
        self.assertFalse(any('cache' in s.get('uses', '') for s in harness))

    def test_harness_initializes_real_startup_helper_before_core_checks(self):
        harness = self.jobs['harness']['steps']
        names = [step.get('name') for step in harness]
        init = next(step for step in harness if step.get('name') == 'Initialize startup fixture helpers')
        self.assertNotIn('if', init)
        self.assertNotIn('continue-on-error', init)
        self.assertEqual(init['run'], 'git submodule update --init src/MagicNet/lib/kamfw')
        self.assertLess(names.index(init['name']), names.index('Test simulation safety and workflow wiring'))

    def test_simulation_is_not_optional_or_cached(self):
        simulation = self.step('Exercise offline Android KernelSU lifecycle')
        self.assertNotIn('if', simulation)
        self.assertNotIn('continue-on-error', simulation)
        self.assertEqual(simulation['run'], 'python3 scripts/android-device-simulation.py')
        self.assertEqual(simulation['env']['MAGICNET_DISPOSABLE_AVD'], '1')
        self.assertFalse(any('SUBSCRIPTION' in key or 'PROXY_REGION' in key for key in simulation['env']))
        self.assertNotIn('if', self.jobs['android-kernelsu'])
        self.assertNotIn('continue-on-error', self.jobs['android-kernelsu'])

    def test_public_proxy_is_explicit_opt_in_after_simulation(self):
        curl_build = self.step('Build verified Android curl for public runtime')
        preparation = self.step('Prepare public benchmark runtime')
        benchmark = self.step('Install and benchmark MagicNet in KernelSU AVD')
        self.assertIn("github.event_name == 'workflow_dispatch'", benchmark['if'])
        self.assertIn('inputs.public_benchmark == true', benchmark['if'])
        self.assertEqual(self.flow['on']['workflow_dispatch']['inputs']['public_benchmark']['default'], 'false')
        names = [s.get('name') for s in self.steps]
        self.assertLess(names.index('Exercise offline Android KernelSU lifecycle'),
                        names.index(curl_build['name']))
        self.assertLess(names.index(curl_build['name']),
                        names.index(preparation['name']))
        self.assertLess(names.index(preparation['name']),
                        names.index('Install and benchmark MagicNet in KernelSU AVD'))
        self.assertIn('android-public-benchmark', benchmark['env']['MAGICNET_ANDROID_REPORT_DIR'])
        self.assertEqual(preparation['id'], 'public_prepare')
        self.assertEqual(preparation['if'], benchmark['if'])
        self.assertEqual(curl_build['if'], preparation['if'])
        self.assertNotIn('continue-on-error', curl_build)
        self.assertEqual(curl_build['timeout-minutes'], '15')
        self.assertEqual(curl_build['run'], 'bash scripts/prepare-android-public-curl.sh "$MAGICNET_PUBLIC_CURL_DIR"')
        self.assertEqual(curl_build['env']['MAGICNET_PUBLIC_CURL_NDK_SHA256'], '${{ steps.toolchain.outputs.ndk }}')
        for step in (curl_build, preparation, benchmark):
            self.assertEqual(step['env']['MAGICNET_PUBLIC_CURL_DIR'], '${{ runner.temp }}/magicnet-public-curl')
        self.assertNotIn('MAGICNET_PUBLIC_CURL_DIR', self.step('Exercise offline Android KernelSU lifecycle')['env'])
        self.assertTrue(any('test-android-public-curl-proof.py' in step.get('run', '')
                            for step in self.jobs['harness']['steps']))
        self.assertNotIn('continue-on-error', preparation)
        self.assertNotIn('continue-on-error', benchmark)
        self.assertEqual(preparation['env']['MAGICNET_DISPOSABLE_AVD'], '1')
        self.assertEqual(benchmark['env']['MAGICNET_DISPOSABLE_AVD'], '1')
        self.assertEqual(benchmark['env']['MAGICNET_PUBLIC_RUNTIME'], 'prepared')
        self.assertIn('artifacts/android-public-benchmark/runtime',
                      benchmark['env']['MAGICNET_PREPARED_RUNTIME_DIR'])
        for key, value in self.step('Exercise offline Android KernelSU lifecycle')['env'].items():
            self.assertEqual(preparation['env'][key], value)
            self.assertEqual(benchmark['env'][key], value)
        self.assertIn('scripts/android-public-runtime.py prepare', preparation['run'])
        self.assertIn('--output artifacts/android-public-benchmark/runtime', preparation['run'])
        self.assertIn('--simulation-report artifacts/android-kernelsu/simulation.json', preparation['run'])

    def test_public_stability_observation_cannot_be_short_success_only(self):
        soak = self.step('Observe sustained application networking and core stability')
        self.assertIn("github.event_name == 'workflow_dispatch'", soak['if'])
        self.assertIn('inputs.public_benchmark == true', soak['if'])
        self.assertEqual(soak['if'], self.step('Install and benchmark MagicNet in KernelSU AVD')['if'])
        self.assertNotIn('always()', soak['if'])
        self.assertNotIn('!cancelled()', soak['if'])
        self.assertNotIn('continue-on-error', soak)
        self.assertIn('--duration 600', soak['run'])
        self.assertIn('--interval 20', soak['run'])
        self.assertIn('--root-mode adb', soak['run'])
        names = [s.get('name') for s in self.steps]
        self.assertLess(names.index('Install and benchmark MagicNet in KernelSU AVD'), names.index(soak['name']))
        self.assertLess(names.index(soak['name']), names.index('Stop emulator'))
        self.assertTrue(any('test-android-network-soak.py' in s.get('run', '')
                            for s in self.jobs['harness']['steps']))

    def test_only_pristine_vm_is_cached_and_runtime_inputs_are_verified_fresh(self):
        names = [s.get('name') for s in self.steps]
        boot = names.index('Boot pristine Android 15 AVD')
        self.assertLess(names.index('Save pristine Android AVD'), boot)
        for step in self.steps[boot + 1:]:
            self.assertNotIn('actions/cache', step.get('uses', ''))

        userspace = self.step('Download and verify official KernelSU userspace')['run']
        self.assertEqual(userspace.count('sha256sum --check --strict'), 1)
        self.assertIn('github.com/tiann/KernelSU/releases/download/$KSU_RELEASE/', userspace)
        self.assertIn('ksud-x86_64-linux-android', userspace)

        kernel = self.step('Build and verify pinned KernelSU AVD kernel')['run']
        self.assertIn('build-android-kernel.py --verify', kernel)
        self.assertIn('Build ID: $KSU_AVD_KERNEL_BUILD_ID', kernel)
        self.assertIn('MAGICNET_AVD_KERNEL=', kernel)
        self.assertEqual(self.flow['env']['KSU_AVD_KERNEL_BUILD_ID'], '12525588')
        self.assertNotIn('KSU_AVD_KERNEL_URL', self.flow['env'])
        restore = self.step('Restore matching KernelSU kernel')
        save = self.step('Save verified KernelSU kernel')
        self.assertEqual(restore['with']['key'], save['with']['key'])
        self.assertIn("hashFiles('scripts/build-android-kernel.py')", restore['with']['key'])
        self.assertLess(names.index('Build and verify pinned KernelSU AVD kernel'),
                        names.index('Save verified KernelSU kernel'))
        image = self.step('Verify pinned Android system image')
        self.assertNotIn('if', image)
        self.assertIn('Pkg.Revision', image['run'])
        self.assertIn('stock-boot-sha256.txt', image['run'])
        self.assertIn('sha256sum --check --strict', image['run'])
        for key in ('SYSTEM_IMAGE_KERNEL_SHA256', 'SYSTEM_IMAGE_RAMDISK_SHA256'):
            self.assertRegex(self.flow['env'][key], r'^[0-9a-f]{64}$')
            self.assertIn('$' + key, image['run'])

    def test_complete_payload_preparation_cannot_be_skipped(self):
        step = self.step('Prepare complete x86_64 installation payloads')
        self.assertNotIn('if', step)
        self.assertNotIn('continue-on-error', step)
        self.assertIn('scripts/prepare-android-fixture-tools.sh', step['run'])
        self.assertEqual(self.step('Restore pristine Android AVD')['with']['key'],
                         self.step('Save pristine Android AVD')['with']['key'])

    def test_exact_serial_pinned_kernel_and_enforcing_not_disabled(self):
        self.assertEqual(self.flow['env']['ANDROID_SERIAL'], 'emulator-5554')
        boot = self.step('Boot pristine Android 15 AVD')['run']
        self.assertIn('-port 5554', boot)
        self.assertIn('-kernel "$MAGICNET_AVD_KERNEL"', boot)
        self.assertIn('test -s "$MAGICNET_AVD_KERNEL"', boot)
        self.assertIn('-accel on', boot)
        self.assertIn('-no-snapshot-save', boot)
        self.assertIn('-show-kernel', boot)
        self.assertNotIn('permissive', boot)
        self.assertNotIn('setenforce', boot)

    def test_unique_removed_init_checks_are_preserved(self):
        self.assertFalse((WORKFLOWS / 'init.yml').exists())
        validation = self.step('Validate repository')['run']
        for command in ('kam validate', 'kam check', 'python3 scripts/test-release-workflow.py',
                        'bash scripts/test-subscription-usage.sh', 'bash scripts/test-artifact-signature.sh'):
            self.assertIn(command, validation)

    def test_final_gate_fails_on_failure_cancellation_or_skipped_jobs(self):
        gate = self.jobs['simulation-gate']
        self.assertIn('always()', gate['if'])
        self.assertEqual(set(gate['needs']), {'harness', 'android-kernelsu'})
        self.assertEqual(gate['permissions'], {})
        command = gate['steps'][0]['run']
        for harness in ('success', 'failure', 'cancelled', 'skipped', ''):
            for android in ('success', 'failure', 'cancelled', 'skipped', ''):
                env = dict(os.environ, HARNESS_RESULT=harness, ANDROID_RESULT=android)
                result = subprocess.run(['bash', '-e', '-c', command], env=env, timeout=2)
                self.assertEqual(result.returncode == 0, harness == android == 'success')

    def test_automatic_webui_duplicate_is_removed_but_preview_remains(self):
        self.assertFalse((WORKFLOWS / 'webui.yml').exists())
        preview = load('webui-preview.yml')
        self.assertEqual(set(preview['on']), {'workflow_dispatch'})
        steps = preview['jobs']['preview']['steps']
        artifacts = {s.get('with', {}).get('name') for s in steps if 'upload-artifact' in s.get('uses', '')}
        self.assertEqual(artifacts, {'webui-source', 'webui-preview'})

    def test_real_dns_kernel_is_not_attested_by_cached_pass(self):
        network = load('network-regression.yml')
        dns = network['jobs']['dns-kernel']['steps']
        self.assertFalse(any('test-cache' in s.get('uses', '') for s in dns))
        self.assertTrue(any('test-dns-kernel.py --require' in s.get('run', '') for s in dns))
        self.assertEqual(network['jobs']['internet-observation']['if'], "github.event_name == 'workflow_dispatch'")

    def test_reports_and_cleanup_run_on_failure(self):
        for name in ('Stop emulator', 'Upload Android acceptance report'):
            self.assertIn('always()', self.step(name)['if'])

    def test_public_curl_failure_invalidates_old_outputs_before_preparation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / 'curl-output'
            output.mkdir()
            for name in ('curl', 'cacert.pem', 'build-provenance.json'):
                (output / name).write_text('old successful output must not survive')
            environment = dict(os.environ, ANDROID_NDK_HOME=str(root / 'missing-ndk'),
                               MAGICNET_PUBLIC_CURL_JOBS='0', TMPDIR=str(root))
            result = subprocess.run(['bash', str(ROOT / 'scripts/prepare-android-public-curl.sh'), str(output)],
                                    env=environment, text=True, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(output.iterdir()), [])
            self.assertEqual(list(root.iterdir()), [output])
            self.assertNotIn('ELF built', result.stdout)

    def test_public_curl_build_cannot_inherit_make_flag_overrides(self):
        source = (ROOT / 'scripts/prepare-android-public-curl.sh').read_text()
        block = 'unset CFLAGS' + source.split('unset CFLAGS', 1)[1].split('export ANDROID_NDK_ROOT', 1)[0]
        names = block.replace('\\\n', ' ').split()
        self.assertEqual(names.pop(0), 'unset')
        self.assertTrue(all(re.fullmatch(r'[A-Z_0-9]+', name) for name in names))
        makefile = 'CFLAGS = configured-target-flags\nall:\n\t@printf "%s\\n" "$(CFLAGS)"\n'
        for flag in ('MAKEFLAGS', 'MAKEOVERRIDES', 'MFLAGS', 'GNUMAKEFLAGS'):
            with self.subTest(flag=flag):
                environment = {key: value for key, value in os.environ.items()
                               if key not in ('MAKEFLAGS', 'MAKEOVERRIDES', 'MFLAGS', 'GNUMAKEFLAGS')}
                environment[flag] = 'CFLAGS=inherited-override'
                for name in names:
                    environment.pop(name, None)
                result = subprocess.run(['make', '-s', '-f', '-'], input=makefile, env=environment,
                                        text=True, capture_output=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'configured-target-flags\n')

    def test_modified_workflow_shell_syntax(self):
        for name in ('android-kernelsu-acceptance.yml', 'network-regression.yml', 'webui-preview.yml'):
            for job in load(name)['jobs'].values():
                for step in job.get('steps', []):
                    if 'run' not in step:
                        continue
                    script = re.sub(r'\$\{\{.*?\}\}', 'placeholder', step['run'])
                    result = subprocess.run(['bash', '-n'], input=script, text=True, capture_output=True, timeout=2)
                    self.assertEqual(result.returncode, 0, (name, step.get('name'), result.stderr))

    def test_raw_kam_caches_do_not_block_fixture_or_hide_runtime_elf(self):
        # CI builds the raw KAM ZIP. Like the production component packager,
        # fixture preparation must omit build downloads, not execute them.
        spec = importlib.util.spec_from_file_location('simulation_cache', ROOT / 'scripts/android-device-simulation.py')
        simulation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(simulation)
        host = bytearray(64)
        host[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<HH', host, 16, 3, 62)
        foreign = bytearray(host)
        struct.pack_into('<H', foreign, 18, 183)
        caches = {'.local/state/tools/yq.asset': bytes(foreign),
                  '.local/state/tools/jq.asset': bytes(foreign),
                  '.local/state/zashboard.archive': b'cached dashboard'}
        for extra, kind in ((None, stat.S_IFREG), ('bin/hidden.asset', stat.S_IFREG),
                            ('.local/state/tools/runtime-helper', stat.S_IFREG),
                            ('.local/state/tools/link.asset', stat.S_IFLNK),
                            ('.local/state/../escape.asset', stat.S_IFREG)):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source, output = root / 'raw.zip', root / 'fixture.zip'
                replacements = {}
                for name in simulation.PAYLOADS:
                    path = root / name.replace('/', '-')
                    path.write_bytes(host)
                    replacements[name] = path
                entries = {name: bytes(foreign) for name in simulation.PAYLOADS} | caches | {
                    'module.prop': b'id=MagicNet\n', 'customize.sh': b'export SKIPUNZIP=1\n',
                    '.local/state/tools/metadata.json': b'{"keep": true}'}
                if extra:
                    entries[extra] = bytes(foreign)
                with zipfile.ZipFile(source, 'w') as z:
                    for name, data in entries.items():
                        item = zipfile.ZipInfo(name)
                        item.external_attr = ((kind if name == extra else stat.S_IFREG) | 0o644) << 16
                        z.writestr(item, data)
                before = source.read_bytes()
                if extra:
                    with self.assertRaises(RuntimeError):
                        simulation.prepare_archive(source, output, replacements)
                    self.assertFalse(output.exists())
                else:
                    report = simulation.prepare_archive(source, output, replacements)
                    self.assertEqual(report['excluded_build_cache_sha256'], {
                        name: hashlib.sha256(data).hexdigest() for name, data in caches.items()})
                    with zipfile.ZipFile(output) as z:
                        self.assertEqual(set(z.namelist()), set(entries) - set(caches) | {simulation.PROVENANCE})
                        self.assertEqual(z.read('.local/state/tools/metadata.json'), entries['.local/state/tools/metadata.json'])
                        recorded = json.loads(z.read(simulation.PROVENANCE))
                        self.assertEqual(recorded['excluded_build_cache_sha256'], report['excluded_build_cache_sha256'])
                self.assertEqual(source.read_bytes(), before)


class PublicRuntimeShellTests(unittest.TestCase):
    """Exercise branch/transport boundaries without an emulator or network."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / 'scripts'
        (scripts / 'lib').mkdir(parents=True)
        for name in ('android-kernelsu-acceptance.sh', 'android-device-simulation.py',
                     'lib/android-adb.sh'):
            shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
        self.trace = self.root / 'trace.jsonl'
        self.out = self.root / 'output'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (scripts / 'android-public-runtime.py').write_text('''import json, os, sys
with open(os.environ['PUBLIC_TEST_TRACE'], 'a') as f:
    f.write(json.dumps({'helper': sys.argv[1:]}) + '\\n')
raise SystemExit(int(os.environ.get('PUBLIC_TEST_VERIFY_EXIT', '0')))
''')
        (scripts / 'android-network-benchmark.py').write_text('''import json, os, sys
from pathlib import Path
with open(os.environ['PUBLIC_TEST_TRACE'], 'a') as f:
    f.write(json.dumps({'benchmark': sys.argv[1:]}) + '\\n')
out = Path(sys.argv[sys.argv.index('--output') + 1])
out.mkdir(parents=True, exist_ok=True)
(out / 'summary.md').write_text('test benchmark\\n')
raise SystemExit(int(os.environ.get('PUBLIC_TEST_BENCHMARK_EXIT', '0')))
''')
        fake = self.bin / 'adb'
        fake.write_text('''#!/usr/bin/env python3
import json, os, shlex, sys
from pathlib import Path
args = sys.argv[1:]
stdin = sys.stdin.read() if args == ['shell', '-T', '/data/adb/ksud debug su'] else ''
entry = {'adb': args, 'stdin': stdin}
with open(os.environ['PUBLIC_TEST_TRACE'], 'a') as f:
    f.write(json.dumps(entry) + '\\n')
if stdin:
    lines = stdin.splitlines()
    assert lines[0] == 'export KSU=true ASH_STANDALONE=1'
    words = shlex.split(lines[1])
    assert words[:4] == ['exec', '/data/adb/ksu/bin/busybox', 'sh', '-c']
    cli = shlex.split(words[4])
    assert cli[0] == '/data/adb/modules/MagicNet/cli'
    if cli[1:] == ['service', 'restart', 'sing-box']:
        raise SystemExit(int(os.environ.get('PUBLIC_TEST_RESTART_EXIT', '0')))
    if cli[1:] == ['health'] and os.environ.get('PUBLIC_TEST_HEALTH_EXIT'):
        raise SystemExit(int(os.environ['PUBLIC_TEST_HEALTH_EXIT']))
    if cli[1:] == ['--json', 'service', 'status']:
        count = Path(os.environ['PUBLIC_TEST_TRACE'] + '.status-count')
        before = int(count.read_text()) if count.exists() else 0
        count.write_text(str(before + 1))
        ready = not (os.environ.get('PUBLIC_TEST_NOT_READY_FIRST') == '1' and before == 0)
        print(json.dumps({'schema': 1, 'ok': True, 'command': 'service.status', 'data': {
            'core': {'sing_box': {'process_state': 'running'}}, 'api': {'ready': True},
            'readiness': {'dataplane': ready, 'overall': ready}}}))
    else:
        print('test CLI status')
    raise SystemExit(0)
if args and args[0] in ('push', 'install', 'root', 'reboot', 'wait-for-device'):
    raise SystemExit('prepared path performed a stock installation operation')
if args == ['get-state']:
    print('device')
elif args == ['shell', 'ip link show magicnet0']:
    if os.environ.get('PUBLIC_TEST_TUN_EXIT'):
        raise SystemExit(int(os.environ['PUBLIC_TEST_TUN_EXIT']))
    print('magicnet0: UP')
''')
        fake.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('MAGICNET_', 'PUBLIC_TEST_')) and key != 'GITHUB_STEP_SUMMARY'}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        MAGICNET_PUBLIC_RUNTIME='prepared', MAGICNET_DISPOSABLE_AVD='1',
                        MAGICNET_PREPARED_RUNTIME_DIR=str(self.root / 'runtime'),
                        MAGICNET_ANDROID_REPORT_DIR=str(self.out), MAGICNET_RUN_SPEED='0',
                        PUBLIC_TEST_TRACE=str(self.trace))

    def run_shell(self, **extra):
        return subprocess.run(['bash', str(self.root / 'scripts/android-kernelsu-acceptance.sh')],
                              env=self.env | extra, text=True, capture_output=True, timeout=15)

    def events(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def cli_calls(self):
        return [shlex.split(shlex.split(event['stdin'].splitlines()[1])[4])[1:]
                for event in self.events() if event.get('stdin')]

    def test_prepared_skips_stock_install_and_uses_one_ksu_cli_restart(self):
        result = self.run_shell()
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.events()
        self.assertEqual(events[0], {'helper': ['verify', '--output', str(self.root / 'runtime')]})
        calls = self.cli_calls()
        self.assertEqual(calls.count(['service', 'restart', 'sing-box']), 1)
        self.assertEqual(calls[:3], [
            ['setup', 'https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/clash.yaml'],
            ['sub', 'update-all'], ['sub', 'status']])
        for command in (['--json', 'service', 'status'], ['health'], ['transparent', 'status'],
                        ['service', 'status', 'sing-box'], ['config-editor', 'validate', 'sing-box']):
            self.assertIn(command, calls)
        self.assertEqual(sum('benchmark' in event for event in events), 1)
        benchmark = next(event['benchmark'] for event in events if 'benchmark' in event)
        self.assertEqual(benchmark[benchmark.index('--root-mode') + 1], 'ksud')
        self.assertEqual(benchmark[benchmark.index('--prepared-runtime-dir') + 1],
                         str(self.root / 'runtime'))
        self.assertFalse(any('service.sh' in ' '.join(event.get('adb', [])) for event in events))
        self.assertFalse(any(event.get('adb', [''])[0] in ('push', 'install', 'root', 'reboot', 'wait-for-device')
                             for event in events if 'adb' in event))

    def test_failed_live_verification_cannot_fall_back_or_mutate(self):
        result = self.run_shell(PUBLIC_TEST_VERIFY_EXIT='23')
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.cli_calls(), [])
        self.assertFalse(any('benchmark' in event for event in self.events()))
        self.assertFalse(any(event.get('adb', [''])[0] in ('push', 'install', 'root', 'reboot', 'wait-for-device')
                             for event in self.events() if 'adb' in event))

    def test_failed_restart_is_not_replayed_or_benchmarked(self):
        result = self.run_shell(PUBLIC_TEST_RESTART_EXIT='37')
        self.assertEqual(result.returncode, 1)
        self.assertIn('CLI restart failed', result.stderr)
        self.assertEqual(self.cli_calls().count(['service', 'restart', 'sing-box']), 1)
        self.assertNotIn(['--json', 'service', 'status'], self.cli_calls())
        self.assertFalse(any('benchmark' in event for event in self.events()))

    def test_dataplane_false_is_polled_without_restarting_again(self):
        result = self.run_shell(PUBLIC_TEST_NOT_READY_FIRST='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cli_calls().count(['--json', 'service', 'status']), 2)
        self.assertEqual(self.cli_calls().count(['service', 'restart', 'sing-box']), 1)

    def test_unknown_runtime_and_non_disposable_prepared_refuse_before_cli(self):
        for extra in ({'MAGICNET_PUBLIC_RUNTIME': 'auto'}, {'MAGICNET_DISPOSABLE_AVD': '0'},
                      {'MAGICNET_PREPARED_RUNTIME_DIR': ''}):
            with self.subTest(extra=extra):
                result = self.run_shell(**extra)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.cli_calls(), [])
                self.assertFalse(any('benchmark' in event for event in self.events()))

    def test_benchmark_failure_is_retained(self):
        result = self.run_shell(PUBLIC_TEST_BENCHMARK_EXIT='42')
        self.assertEqual(result.returncode, 42)
        self.assertEqual(sum('benchmark' in event for event in self.events()), 1)

    def test_health_and_tun_failure_do_not_reach_benchmark(self):
        for extra, code in (({'PUBLIC_TEST_HEALTH_EXIT': '31'}, 31),
                            ({'PUBLIC_TEST_TUN_EXIT': '32'}, 32)):
            with self.subTest(extra=extra):
                result = self.run_shell(**extra)
                self.assertEqual(result.returncode, code)
                self.assertFalse(any('benchmark' in event for event in self.events()))

    def test_default_remains_stock_late_load(self):
        del self.env['MAGICNET_PUBLIC_RUNTIME']
        result = self.run_shell()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MAGICNET_KSUD_HOST is required', result.stderr)
        self.assertFalse(any('helper' in event for event in self.events()))
        self.assertEqual(self.cli_calls(), [])


if __name__ == '__main__':
    unittest.main()
