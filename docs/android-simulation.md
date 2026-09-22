# Android / KernelSU simulation

The automatic `Android KernelSU Acceptance` workflow runs on pull requests,
merge groups and pushes to `main`. It has no path exclusions. `Android Simulation
Gate` fails if the harness or emulator job fails, is cancelled, or is skipped.
This adds a check; it does **not** silently change GitHub branch protection or the
signed-release workflow. Require this check in the repository's merge rules before
calling it a mandatory merge/release policy. Keep the existing CI Quality Gate.

## What runs

The host harness tests run first without a cached success. The device job builds
the current module, the exact pinned sing-box source, Android x86_64 CLI/core,
and an ordinary application-UID probe APK. The production ARM64 ZIP still goes
through the existing package checks. KAM validation previously in `init.yml` is
now run in this job before packaging; no KAM check was dropped.

A disposable Android 15 / API 35 x86_64 AVD boots its **stock kernel** with KVM.
After Android userspace is fully booted, the pinned official KernelSU v3.2.0
x86_64 `ksud` first extracts its own embedded BusyBox using `debug extract-binary`,
then verifies that its embedded KMI set contains the running stock KMI
and executes the upstream `late-load` LKM path. This keeps the stock kernel and
stock ramdisk/vendor modules paired while still using a real KernelSU kernel
interface, module manager, SELinux rules and module lifecycle. Automatic runs
request 2 GiB RAM; manual dispatch also offers 4 GiB, while the report records
the guest's observed `/proc/meminfo` separately. The driver requires an explicit
emulator serial, qemu identity, x86_64 ABI, API 35, SELinux Enforcing, a positive
KernelSU kernel version, and the real `u:r:ksu:s0` domain. It uses KernelSU
BusyBox with `ASH_STANDALONE=1`. It never enables permissive mode.

All bundled ABI-specific executables are replaced in a **separate test ZIP**, before
installation: CLI, sing-box, jq and yq, plus eCapture/Proxylink when present.
The extra payloads use verified release/source pins; missing replacements fail
preparation instead of silently removing installed tools. Other unexpected foreign-architecture ELF
files fail preparation instead of surviving until boot. Installer/lifecycle scripts
are not rewritten. The original ZIP remains untouched. The report records its
SHA-256, the fixture ZIP hash, the source commit and each replacement hash.
This does not validate ARM64 execution or claim that the test ZIP is a signed
release package. Fixture ZIPs are temporary and are not uploaded as releases.

The real `ksud module install` runs first. An offline standalone configuration is
seeded afterwards, before the first module boot. That configuration uses a local
hosts resolver and direct test routing: no free proxy node, subscription account,
public DNS or remote rule-set is required for the acceptance assertions. Build
inputs and the initial SDK/kernel downloads still require network access.

The driver checks twelve phases:

| Phase | Required evidence |
| --- | --- |
| Environment | Disposable emulator identity; valid ABI-specific ZIP |
| KernelSU bootstrap | Official v3.2.0 late-load against the running stock KMI; positive kernel interface and enforcing KSU domain |
| Install before first boot | Actual module installer; payload hashes at its destination |
| Cold boot | A new kernel boot ID; lifecycle-owned core in the KSU domain; process, API and TUN ready |
| Application-UID TUN controls | Marker delivery, rejection, delivery again, and config restoration |
| Invalid-config rollback | Malformed config rejected; active config unchanged; service still ready |
| Stop cleanup | No core, TUN, owned DNS/firewall rules or table-2022 routes remain |
| Restart idempotence | Two restarts, exactly one core each time, followed by app-UID controls |
| Upgrade preservation | Real reinstall checks the staged node, marker and policy before reboot, then checks the activated result; no re-seeding to hide data loss |
| Disable/reboot | Real KernelSU disable and reboot leave the module stopped |
| Enable/reboot | Real enable and reboot restore readiness and app-UID controls |
| Uninstall/reboot | Real uninstall and reboot remove active/staged module directories and owned networking |

Boot checks require the kernel boot ID to change; an old `sys.boot_completed=1`
cannot satisfy a reboot. All ADB operations and readiness loops have deadlines.
No manual move from `modules_update`, manual `service.sh` invocation, fake `su`,
or post-boot binary injection is used in this automatic path. Temporary Android
transfers use `/sdcard/Download/MagicNet/ci-simulation`; executables run from
`/data/adb`, not noexec shared storage. Never run this driver against a phone.

The app-UID controls reuse `android-tun-proof.py`. A random marker is served on
host loopback and exposed through `adb reverse`. The app connects to a sentinel
address through a UID-specific TUN override. A reject rule must prevent both the
response and server-side connection. Restoring the rule must restore delivery,
and restoring the original config must succeed. A timeout is not an acceptable
negative-control result. Root-shell connectivity is not application connectivity.

## Reports and cache boundaries

`artifacts/android-kernelsu/` contains `simulation.json`, `simulation-junit.xml`,
`simulation-summary.md`, separate TUN-control results for each phase and bounded
logcat/kernel/service diagnostics. Failed and unexecuted phases are explicit
failures, not skipped green tests. Artifact upload and emulator cleanup use
`always()`. Missing KVM/SDK/ADB or a failed boot is a failure, not certification.

Only dependencies, compiler outputs and a pristine **pre-boot** stock AVD are
cached. No dirty device snapshot or device-test success is cached. The official
KernelSU userspace is downloaded fresh and SHA-256 verified on every run; no
third-party replacement kernel is injected. The real DNS NAT job in
`network-regression.yml` also runs its packet checks each time against the
current host kernel instead of reusing a pass.

## Workflow cleanup

`init.yml` was removed after moving all its commands into the existing Android
build job. The old automatic `webui.yml` was replaced by manual-only
`webui-preview.yml`; Code Quality remains the single automatic WebUI check and
the source/preview artifacts remain available on demand. Runner public-endpoint
observations are manual-only. Unique installation-onboarding, uninstall-browser,
network-evidence, rules-release and signed module-release workflows are retained.

The optional `public_benchmark` input defaults to false. It runs the legacy public
proxy benchmark only after the offline simulation, writes to
`artifacts/android-public-benchmark/`, and cannot replace offline acceptance.
Public endpoint reachability and proxy quality are observations, not proof that
Google Play login or downloads work.

## Reproduce the host checks

```sh
python3 scripts/test-android-device-simulation.py
python3 scripts/test-android-simulation-workflow.py  # requires PyYAML
python3 scripts/test-android-device-simulation.py --check-core /path/to/built/sing-box
```

The first two commands test the **harness**, not a device. The full Android
workflow must actually complete before reporting device acceptance as passed.

## Remaining coverage limits

This fixture exercises one Android release, the official KernelSU v3.2.0
**late-load LKM** mode on x86_64, and a standalone TUN configuration. It does not
prove KernelSU built-in/early-boot mode, execute the shipped ARM64 binaries, cover
OEM netd/vendor policies, GMS/Play login/download, a real subscription, eBPF
forwarding or IPv6 packet forwarding. Existing host/network-namespace/eBPF tests are retained
and complementary, not relabelled as Android evidence. A matrix of real ARM64/OEM
runners is still needed for those claims. Reductions in installation-time surprises
come from moving these explicit lifecycle checks before merge, not from treating
one emulator as every Android device.
