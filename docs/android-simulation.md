# Android / KernelSU simulation

The automatic `Android KernelSU Acceptance` workflow runs on pull requests,
merge groups and pushes to `main`. It has no path exclusions. `Android Simulation
Gate` fails if the harness or emulator job fails, is cancelled, or is skipped.
GitHub branch protection remains a repository setting. Signed publication also
requires a successful push-triggered Android run and all three required jobs on
the exact main release commit; old commits and PR-only results are rejected.

## What runs

The host harness tests run first without a cached success. The device job builds
the current module, the exact pinned sing-box source, Android x86_64 CLI/core,
and an ordinary application-UID probe APK. The production ARM64 ZIP still goes
through the existing package checks. KAM validation previously in `init.yml` is
now run in this job before packaging; no KAM check was dropped.

A disposable Android 15 / API 35 x86_64 AVD is configured to boot with KVM and a pinned
API35/6.6 x86_64 kernel built from Android CI build 12525588 with KernelSU v3.2.0.
The workflow builds the complete virtual-device target from a fixed source manifest
and build recipe, verifies source identity and cached output hashes on every run,
and passes the resulting `bzImage` to the emulator. The SDK image must be API35
google_apis x86_64 revision 9; its properties and stock boot-file hashes are recorded. After Android userspace is fully booted,
official x86_64 `ksud` first requires a positive KernelSU kernel interface,
extracts its embedded BusyBox, reads the running KMI, and executes upstream
`late-load` only for userspace and lifecycle initialization. Automatic runs
request 2 GiB RAM; manual dispatch also offers 4 GiB, while the report records
the guest's observed `/proc/meminfo` separately. The driver requires an explicit
emulator serial, qemu identity, x86_64 ABI, API 35, SELinux Enforcing, a positive
KernelSU kernel version, and the real `u:r:su:s0` domain from pinned KernelSU v3.2.0. It keeps
KernelSU BusyBox `ASH_STANDALONE=1` semantics for normal applets, verifies the
BusyBox grep operations and byte-based awk list/user parsers, and separately
verifies `/system/bin/sed` on ASCII module metadata. Both BusyBox and system sed
can fault on UTF-8 character-set regexes in this x86 environment; selecting a
different executable alone does not fix that defect. Startup config shape/node
checks now use packaged jq, and list trimming/user-ID extraction avoids applying
those regexes to Unicode text. The harness also runs the real product parsers
against the unchanged, hash-verified KernelSU BusyBox on the host. It never
enables permissive mode or substitutes another root-manager binary.

The older build 11987101 kernel failed before installation with a `module_layout`
ABI mismatch. The matching 12525588 candidate reached Android `sys.boot_completed`
with SELinux Enforcing in [run 36558888264](https://github.com/LIghtJUNction/MagicNet/actions/runs/36558888264).
This establishes boot compatibility; the complete KernelSU/MagicNet lifecycle is
still required in the automatic acceptance workflow. The harness reports recognized
ABI failures and repeated early-init reboots from bounded emulator-log evidence;
unrecognized boot failures retain the existing deadline.

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

Only dependencies, compiler outputs and a pristine **pre-boot** SDK AVD are
cached. No dirty device snapshot or device-test success is cached. The official
KernelSU userspace is downloaded fresh and SHA-256 verified on every run.
The API35 kernel is built from pinned sources on cache misses; cache hits must
match the same source identity and output SHA-256 hashes. SDK image revision,
stock kernel and ramdisk hashes are checked on both AVD cache hits and misses. The real DNS NAT job in `network-regression.yml` runs
its packet checks each time against the current host kernel instead of reusing a
pass.

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

This fixture exercises one Android release, a pinned KernelSU v3.2.0
**API35 x86_64 kernel plus userspace late-load lifecycle** path, and a standalone
TUN configuration. It does not prove stock-kernel LKM injection, execute the
shipped ARM64 binaries, cover OEM netd/vendor policies, GMS/Play login/download,
a real subscription, eBPF forwarding or IPv6 packet forwarding. Existing host/network-namespace/eBPF tests are retained
and complementary, not relabelled as Android evidence. A matrix of real ARM64/OEM
runners is still needed for those claims. Reductions in installation-time surprises
come from moving these explicit lifecycle checks before merge, not from treating
one emulator as every Android device.
