# Application network-policy recovery

Related: #329, #253 and #305.

## What this changes

The v1.5.13 network-access commands only enumerate configured policies. They cannot
remove the restriction that the controlled experiment in #329 found ahead of
Android system DNS. A sing-box DNS success or TUN health check does not test that
policy layer. This change adds an explicitly confirmed, reversible recovery path
through the policy owner's framework API, not direct writes to a kernel map.

No device model, fixed application UID, random proxy port, map path, subscription,
Google node or package allowlist is embedded in the implementation. Packages and
shared identities are resolved at execution time. TUN/eBPF selection is untouched.

Supported semantics are deliberately limited:

- AOSP INetworkPolicyManager: remove POLICY_REJECT_METERED_BACKGROUND (1), preserving
  the known ALLOW_METERED_BACKGROUND bit (4). This is a user-confirmed change to the
  selected app's background-data preference, not a claim that Data Saver caused
  the foreground failure in #329.
- OplusNetworkingControlManager: clear a selected known reject_mobile (1),
  reject_wifi (2), or reject_all (4) policy through setUidPolicy. The API and exact
  setter shape must exist; this is capability detection, not a device-name test.
- Unknown values, absent interfaces, system/SDK-sandbox/isolated identities and
  incomplete shared identities are not modified. MIUI/HyperOS and other vendor
  firewalls are not claimed supported merely because AOSP enumeration succeeds.

## Use and authorization

Run from a root shell on the installed module. Read the complete packages array
before confirming: an Android shared UID changes every package in that array.
Do not bulk-repair all entries or select an entry solely because it is nonzero.
Only clear a restriction when the device owner intends that application to use
that network and the displayed configured policy explains the intended change.

```sh
cd /data/adb/modules/MagicNet
./cli --json network-access inspect
# Copy the reviewed entry's opaque candidate string; do not pass a numeric UID.
./cli network-access repair '<candidate>' --confirm
./cli network-access check '<candidate>'
# Restore that entry's original configured policy when necessary:
./cli network-access rollback '<candidate>' --confirm
```

There is no automatic policy mutation on install, boot, subscription update, core
restart or status inspection. Installing this version alone does NOT silently
remove existing user/OEM restrictions. Existing WebUI/MCP status and inspect
consumers remain read-only. `--json network-access repair/rollback/check` are not
advertised and remain rejected by the machine dispatcher, with no fall-through.

`repair_supported=false` continues to describe the machine mutation surface.
The additive `manual_repair_supported` field identifies reviewed human-CLI
candidates. The additive `recovery` summary exposes only counts/status; explicit
inspect also returns reviewed package names, candidate tokens and recorded phases,
not raw UIDs. `configured_verified=true` means API readback matched, never that
Play login, downloads, DNS or the actual data plane passed.

## Transaction, interruption and concurrency

The candidate is a digest of provider, UID, original policy and the complete
sorted package set. Fresh policy/identity observations are required before writes.
An exclusive nonblocking flock serializes MagicNet writers. The lock file is never
removed as a substitute for releasing the lock. Framework Binder setters offer
no atomic compare-and-set; optimistic checks do NOT eliminate races with an
external vendor service. A detected different policy or changed package identity
fails closed.

Before invoking a setter, MagicNet atomically persists a private mode-0600 journal
in a mode-0700 `.state/network-access-recovery` directory and syncs the file and
directory. The journal contains the original policy and identity needed for
rollback; it is not public canonical state or persistent intent to reapply. It is
bounded (128 identities, 64 KiB per record), rejects symlinks/hardlinks/unsafe
permissions, and is surfaced only through the network-access command family.
Do not upload these private journal files in issue reports.

The durable phases are prepared -> applied and rollback_prepared -> rolled_back.
A timeout, partial setter failure or response loss retains the prepared evidence.
A repeat call may reconcile an already-applied value without another setter call.
If an interrupted operation still shows its original value, it reports
interrupted_change rather than assuming the first setter never ran. Use an
explicit rollback to settle that journal before requesting a fresh change.

Successful repeated repairs/rollbacks are no-ops. Rollback only restores the
original when the current value is still the value this operation applied; a
new third-party policy is not overwritten. If a completed repair observes the
original restriction again, it reports restriction_reapplied. No endless
background clearing, controller disabling, global firewall flushing, SELinux
relaxation, netd ALLOW_MULTI or app-direct routing override is introduced.

## Verification and remaining scope

Java tests execute the real reflection bridge against simulated AOSP/Oplus
services, including writes/readback, rollback, missing services, shared UID scope,
user profiles, permission checks, malformed input and ignored writes. Rust tests
cover journal safety, state transitions, idempotence and conflict handling.
These are host regressions, not Android or Play Store acceptance.

The #329 controlled kernel-restriction experiment is prior evidence, not a test
of this new framework setter implementation. On-device verification must compare
app-identity system DNS and actual Play home/search/login/download before/after,
then foreground/background, IPv4/IPv6, core restart and network switching. Check
for controller reapplication using the same candidate. An API that returns success
but does not change state is an error; matching configured readback still cannot
prove actual kernel policy or application access.

Persistent prevention of a vendor controller reapplying restrictions is NOT
implemented here. Multiple OEM device acceptance is still required. Keep #329
open until that evidence exists, and do not label this release a universal or
permanent Play Store fix based on mock tests alone.
