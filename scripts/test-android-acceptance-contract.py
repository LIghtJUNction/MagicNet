#!/usr/bin/env python3
"""Execute the AVD payload build wiring without downloading an SDK or running a VM."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/android-kernelsu-acceptance.yml"


class AcceptanceContract(unittest.TestCase):
    def setUp(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        self.steps = workflow["jobs"]["android-kernelsu"]["steps"]

    def step(self, name):
        return next(step for step in self.steps if step.get("name") == name)

    def test_avd_build_references_real_workspace_packages(self):
        workspace = tomllib.loads((ROOT / "Cargo.toml").read_text())["workspace"]
        packages = []
        for member in workspace["members"]:
            for path in ROOT.glob(member):
                packages.append(tomllib.loads((path / "Cargo.toml").read_text())["package"]["name"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "scripts").mkdir()
            cargo = root / "bin/cargo"
            cargo.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
assert args[:3] == ["ndk", "-t", "x86_64"], args
assert "build" in args and "--release" in args, args
requested = [args[i+1] for i, arg in enumerate(args[:-1]) if arg in ("-p", "--package")]
assert requested, args
for package in requested:
    if package not in json.loads(os.environ["WORKSPACE_PACKAGES"]):
        sys.exit("AVD requested missing workspace package: " + package)
    output = pathlib.Path("target/x86_64-linux-android/release") / package
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("#!/bin/sh\\nexit 0\\n")
    output.chmod(0o755)
''')
            cargo.chmod(0o755)
            core = root / "scripts/build-sing-box.sh"
            core.write_text('#!/bin/sh\nset -eu\n[ "$1" = android ] && [ "$2" = amd64 ]\nprintf "#!/bin/sh\\nexit 0\\n" > "$3"\nchmod 0755 "$3"\n')
            core.chmod(0o755)
            env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                       RUNNER_TEMP=str(root / "runner"), WORKSPACE_PACKAGES=json.dumps(packages))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step("Build x86_64 AVD runtime payloads")["run"]],
                                    cwd=root, env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            payloads = root / "runner/magicnet-x86"
            self.assertEqual({p.name for p in payloads.iterdir()}, {"magicnet-cli", "sing-box"})
            self.assertTrue(all(os.access(p, os.X_OK) for p in payloads.iterdir()))

    def test_host_core_is_built_and_validated_before_packaging(self):
        name = "Build host core for package routing checks"
        names = [step.get("name") for step in self.steps]
        self.assertLess(names.index(name), names.index("Build current MagicNet module"))
        for failure in (0, 17):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "scripts").mkdir()
                builder = root / "scripts/build-sing-box.sh"
                builder.write_text('#!/bin/sh\nset -eu\n[ "$1" = linux ] && [ "$2" = amd64 ]\n'
                                   'test "$FAIL_BUILD" = 0 || exit "$FAIL_BUILD"\n'
                                   'printf "#!/bin/sh\\nexit 0\\n" > "$3"\nchmod 0755 "$3"\n')
                builder.chmod(0o755)
                validator = root / "scripts/test-android-tun-proof.py"
                validator.write_text('import os, pathlib, sys\n'
                                     'assert sys.argv[1] == "--check-core"\n'
                                     'assert pathlib.Path(sys.argv[2]).is_file()\n'
                                     'assert os.access(sys.argv[2], os.X_OK)\n'
                                     'pathlib.Path("validated").touch()\n')
                pathfile = root / "github-path"
                env = dict(os.environ, RUNNER_TEMP=str(root / "runner"),
                           GITHUB_PATH=str(pathfile), FAIL_BUILD=str(failure))
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step(name)["run"]],
                                        cwd=root, env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, failure, result.stdout + result.stderr)
                if failure:
                    self.assertFalse(pathfile.exists(), "failed core must not reach package checks")
                    self.assertFalse((root / "validated").exists())
                else:
                    self.assertEqual(pathfile.read_text().strip(), str(root / "runner/magicnet-host"))
                    self.assertTrue((root / "validated").exists())

    def test_acceptance_passes_only_the_current_runtime_payloads(self):
        env = self.step("Install and benchmark MagicNet in KernelSU AVD")["env"]
        self.assertIn("MAGICNET_X86_CLI", env)
        self.assertIn("MAGICNET_X86_SINGBOX", env)
        self.assertNotIn("MAGICNET_X86_MCP", env)


    def test_sdk_bootstrap_precedes_all_android_consumers(self):
        names = [step.get("name") for step in self.steps]
        for consumer in ("Build application-UID network probe", "Create pristine Android 15 AVD", "Boot pristine Android 15 AVD"):
            self.assertLess(names.index("Locate Android SDK tools"), names.index(consumer))

    def test_sdk_bootstrap_exports_all_tools_without_global_path_assumptions(self):
        for layout in ("latest", "versioned"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                sdk = root / "sdk with spaces"
                versions = ["latest"] if layout == "latest" else ["9.0", "16.0"]
                for version in versions:
                    toolbin = sdk / "cmdline-tools" / version / "bin"
                    toolbin.mkdir(parents=True)
                    for tool in ("sdkmanager", "avdmanager"):
                        file = toolbin / tool
                        file.write_text("#!/bin/sh\nexit 0\n")
                        file.chmod(0o755)
                pathfile = root / "github-path"
                env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk), ANDROID_HOME="/not/the/sdk", GITHUB_PATH=str(pathfile))
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step("Locate Android SDK tools")["run"]],
                                        env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(pathfile.read_text().splitlines(), [str(sdk / "cmdline-tools" / versions[-1] / "bin"), str(sdk / "platform-tools"), str(sdk / "emulator")])

    def test_sdk_bootstrap_fails_without_publishing_partial_paths(self):
        for failure in ("missing-directory", "missing-manager", "missing-avdmanager", "not-executable", "newline"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                sdk = root / ("sdk\ninjected-path" if failure == "newline" else "sdk")
                tools = sdk / "cmdline-tools/latest/bin"
                if failure != "missing-directory":
                    tools.mkdir(parents=True)
                    for tool in ("sdkmanager", "avdmanager"):
                        if (failure == "missing-manager" and tool == "sdkmanager") or (failure == "missing-avdmanager" and tool == "avdmanager"):
                            continue
                        file = tools / tool
                        file.write_text("#!/bin/sh\nexit 0\n")
                        file.chmod(0o644 if failure == "not-executable" else 0o755)
                pathfile = root / "github-path"
                env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk), GITHUB_PATH=str(pathfile))
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step("Locate Android SDK tools")["run"]],
                                        env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse(pathfile.exists(), "invalid SDK must not publish paths")


    def test_failed_sdk_install_does_not_publish_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / "sdk"
            tools = sdk / "cmdline-tools/latest/bin"
            tools.mkdir(parents=True)
            for tool in ("sdkmanager", "avdmanager"):
                file = tools / tool
                file.write_text("#!/bin/sh\nexit 19\n")
                file.chmod(0o755)
            pathfile = root / "github-path"
            env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk), GITHUB_PATH=str(pathfile))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step("Locate Android SDK tools")["run"]],
                                    env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 19, result.stdout + result.stderr)
            self.assertFalse(pathfile.exists())


if __name__ == "__main__":
    unittest.main()
