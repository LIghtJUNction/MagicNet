# Android KernelSU network checks

The manual **Android KernelSU Acceptance** workflow installs the module into a
disposable Android 15/API 35 `google_apis` x86_64 emulator. The AVD keeps its
stock kernel/vendor modules paired; pinned official KernelSU v3.2.0 is activated
through its x86_64 late-load LKM path after Android userspace boots. It is not a
physical-phone, built-in/early-boot KernelSU, or authenticated Google Play test.

## What changed after the false-positive audit

The old benchmark ran BusyBox wget as the root adbd user. Production TUN excludes
UID 0, so those requests did not establish app/TUN capture. It also ignored the
corpus's expected status, allowed one domestic and one global success to hide
other failed services, and counted a timed-out download by its byte count alone.

Requests now originate in a separate, test-only Android APK, without root,
shared UID, account cookies or storage permissions. The APK uses Android's normal
TLS and hostname verification. The host rejects a missing or malformed result,
root identity, a nonzero ADB exit, a wrong HTTP status, redirected/body-bearing
204, partial response, exceeded byte budget, or any failed target/round. The old
80%/"any endpoint" gate is gone. Requested throughput failures also fail the run.
The retained `--strict-external` CLI flag cannot weaken this policy.

The actual Java request engine is executed against local HTTPS fixtures in PR and
release checks: trusted/untrusted certificates, error status, redirected 204,
HTTPS downgrade, premature EOF, known/unknown-length bodies, bounded throughput
and stalls. Test successes are not reused from the old host cache scope. CI also
builds and verifies the real test APK; the exact compiled fork checks both sentinel
route configurations.

## TUN path proof

Before public probes, the disposable AVD runs a positive/reject/positive control.
A host loopback server emits a fresh random marker. An adb reverse maps it to
**device loopback only**. The test application connects to `198.18.0.42`, not that
loopback address. A temporary rule must match the installed TUN inbound, the exact
destination/port **and the test app UID**, then override the destination to the
loopback fixture. Success requires the exact marker and one fixture connection.
The reject control must refuse the connection without reaching the fixture; the
second positive must recover. Root remains excluded throughout.

Configuration is saved through the existing private CLI payload/validated editor
and restarted through the normal module lifecycle. The original active config
must be restored and compared before a proof can pass. The helper refuses physical
phones and non-x86 emulator identities. A failed/interrupted restoration is a
failed test: discard the AVD, never publish/cache its mutated disk.

This proves **one test UID's TCP capture**, not every app's UID, UDP/QUIC, provider
compatibility, DNS privacy, IPv6, sleep/wake or network handover. A sentinel pass
cannot close the real-device Play/GMS issue.

## Installation, deadlines and reports

The full arm64 module is installed through KernelSU first; the AVD then receives
x86_64 CLI, core, jq and yq payloads. Each replacement utility is executed to detect
ABI/interpreter mistakes. The production arm64 artifacts are not modified by this
fixture. `ksud` is staged under `/sdcard/Download/MagicNet`, then copied to its
actual executable userspace destination; `/sdcard` is not used as executable storage.

All ADB calls, including `wait-for-device`, have deadlines. Exit diagnostics have
an overall budget and preserve the original test exit code. Process memory that
could not be read is `null`, not an invented zero. No custom corpus URL, config,
subscription token or account login is emitted by the benchmark report.

Reports contain the individual failures, the TUN controls/restoration result,
source commit, scope and explicit `not_tested` fields. The public subscription is
only an anonymous fixture. Public sites and free nodes may fail or reject CI;
that is reported as **FAIL/INCOMPLETE**, not converted into a successful acceptance.

The pristine AVD cache is saved before installation and never after mutation.
The workflow always stops/discards the emulator. Google Play search, images,
actual downloads, GMS and Wi-Fi/mobile transitions still require the affected
physical device and a known-working proxy path.
