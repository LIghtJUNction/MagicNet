# Android / KernelSU simulation

The automatic `Android KernelSU Acceptance` workflow runs on every pull request,
merge group and push to `main`. `Android Simulation Gate` fails if either the
harness or device job fails, is cancelled or is skipped. This check is not a
branch-protection or release-policy change: configure it as required separately.
The existing CI Quality Gate and signed-release checks remain independent.

## Environment and artifact identity

The device job builds the reviewed module and pinned sing-box, plus Android
x86_64 CLI/core and an application-UID probe APK. The ARM64 module still passes
its existing package checks. The separate AVD ZIP contains matching x86_64
executables for CLI, sing-box, jq and yq, and for eCapture/Proxylink when bundled.
The additional tools are not removed to evade architecture checks. eCapture uses
the same release's Android amd64 asset, pinned by SHA-256; Proxylink builds from
the exact revision declared by the production build hook, with CGO disabled.
Unknown foreign ELF files and missing replacements fail fixture preparation.

KAM can package the top-level `cli` symlink as a regular ELF copy. The fixture
replaces that copy only when its original bytes equal `bin/magicnet-cli`.
An actual symlink must point exactly to `bin/magicnet-cli`. Mismatched copies,
escaping links or special files fail; arbitrary same-name files are not repaired.
ZipInfo records are copied before writing so output offsets cannot corrupt later
reads from the source ZIP. Build-only `.local/state` downloads are excluded using
the production packager's rule, with a hash recorded for every excluded member.
The original archive and installer/lifecycle scripts are not modified. Reports
record the original and fixture ZIP hashes, source commit, replacements and aliases.

A disposable Android 15 / API 35 x86_64 AVD boots a real KernelSU kernel under KVM.
The driver requires an explicit emulator serial, qemu identity, x86_64 ABI,
SELinux Enforcing, positive KernelSU version and the real `u:r:ksu:s0` domain.
KernelSU BusyBox uses `ASH_STANDALONE=1`; permissive mode is never enabled.
Automatic runs request 2048 MiB; manual dispatch can request 4096 MiB. The emulator
may raise its allocation. `provenance.memory` separates `requested_emulator_mib`
from `observed_guest_memtotal_kib`; guest MemTotal is not configured VM RAM.

The actual `ksud module install` runs before an offline standalone configuration
is seeded for first boot. That configuration uses a hosts resolver, direct routing
and no public proxy, subscription credential or remote rule set. SDK/build asset
downloads still require network access. Transfers use
`/sdcard/Download/MagicNet/ci-simulation`; execution uses `/data/adb`.
Never run the driver against a phone.

## Required phases

| Phase | Evidence |
| --- | --- |
| Environment | Disposable identity, ABI-correct fixture and observed memory |
| KernelSU bootstrap | Userspace install, reboot, positive kernel version, enforcing KSU domain |
| Install before first boot | Real module installer and installed payload hashes |
| Cold boot | Changed kernel boot ID; lifecycle-owned core; process/API/TUN ready |
| App-UID TUN controls | Marker delivery, rejection, delivery again and original config restoration |
| Invalid-config rollback | Same-path valid control, malformed config rejection, unchanged active config and readiness |
| Stop cleanup | No core, TUN or owned DNS/firewall/table-2022 state |
| Restart idempotence | Two restarts with exactly one core each, then app-UID controls |
| Upgrade preservation | Actual staged and activated node fields and user setting survive reinstall/reboot |
| Disable/reboot | Real KernelSU disable and no active module networking |
| Enable/reboot | Real enable, readiness and app-UID controls |
| Uninstall/reboot | No active/staged module or owned networking |

A boot-completed flag from the previous boot cannot satisfy reboot checks.
All ADB operations and readiness loops have deadlines. The automatic path never
moves `modules_update` manually, invokes `service.sh` instead of booting, injects
binaries after first boot or uses fake `su`.

The TUN controls reuse `android-tun-proof.py`: a random host-loopback marker is
exposed by `adb reverse`; an ordinary app UID reaches it only through the sentinel
TUN override. Rejection must prevent both the response and server connection;
a timeout is not an acceptable negative control. The positive case and original
configuration must then be restored. Root-shell connectivity does not count.

## Upgrade fixture contract

Production upgrades import nodes with a `server` field into the newly shipped
template. A direct-only standalone configuration has no migratable node and is
intentionally rejected. Before reinstall, the fixture adds one credential-free
loopback SOCKS node through the existing private payload/save API, leaving the
initial direct routing policy unchanged. A readback confirms that the save worked.

The actual installer must produce a staged configuration containing exactly one
node with the original type, tag, loopback address, port and SOCKS version, plus
the user setting stored in `.config/magicnet`. After a real reboot, both are checked
again in the active module. No configuration is re-seeded after installation to
conceal loss. Missing staging, changed fields, lost settings or failed readiness
fail the phase. The node is metadata for migration, not a running proxy server;
`upgrade-migration.json` explicitly reports `node_transport_tested=false`.
The app-UID TUN proof runs separately after migration.

The upgraded configuration belongs to the production template, not the original
hosts-only fixture. Background Android traffic may attempt public DNS or proxy
connections; public connectivity is not used as migration/TUN evidence.

## Reports and caches

`artifacts/android-kernelsu/` contains `simulation.json`, `simulation-junit.xml`,
`simulation-summary.md`, per-stage TUN results, `upgrade-migration.json` on successful
migration and bounded diagnostics. Failed and unexecuted phases are failures,
not green skips. Cleanup and artifact upload use `always()`.
Only dependencies, compiler outputs and a pristine pre-boot AVD are cached; no
mutated VM or device-test success is cached. Cached kernel/ksud bytes are rehashed.
Real DNS NAT tests also send packets against the current host kernel every run.

KAM validation formerly in `init.yml` is preserved in the Android build job.
Automatic WebUI checks stay in Code Quality; `webui-preview.yml` is manual-only.
Onboarding, uninstall-browser, network-evidence and release workflows retain their
unique checks. Public endpoint observations and the optional Android public proxy
benchmark remain manual-only and cannot replace device acceptance.

## Reproduce and interpret results

```sh
python3 scripts/test-android-device-simulation.py
python3 scripts/test-android-simulation-fixes.py
python3 scripts/test-android-simulation-workflow.py
python3 scripts/test-android-simulation-fixes.py --check-core /path/to/built/sing-box
```

Workflow tests require PyYAML. These commands test harness behavior and config
syntax, not Android execution. The full Actions device job must actually complete
before reporting acceptance passed. One Android release/x86_64 kernel does not
establish ARM64 execution, OEM netd policies, Play/GMS login/download, real proxy
quality, eCapture capture behavior, Proxylink conversion, Android eBPF forwarding
or IPv6 packet forwarding. Existing host and namespace tests remain complementary.
