# Android simulation fixture repair (#344)

This repair is limited to the host-side CI harness. It does not relax production
installation, disable KernelSU/SELinux checks, or certify device acceptance.

## CLI compatibility entry

The raw KAM archive can contain a dereferenced `cli` executable instead of the
tracked `cli -> bin/magicnet-cli` symlink. The x86_64 fixture now handles that
specific entry. A symlink must target exactly `bin/magicnet-cli`; an executable
copy must be byte-for-byte identical to the source canonical executable before
replacement. Unknown binaries, alternate targets and path/type mismatches still
fail. A symlink is stored uncompressed for BusyBox unzip. Every alias replacement
is recorded separately in `.ci-fixture.json`; the production ZIP is unchanged.
Input ZipInfo objects are copied before writing so ZIP entry order cannot corrupt
subsequent source reads or the alias comparison.

The production module also ships `bin/ecapture` and `bin/proxylink`. The fixture
requires matching x86_64 replacements for every bundled helper and records each
replacement hash. It does not omit these installed components to make the test
pass. Payload preparation uses the reviewed eCapture release digest and the
production Proxylink source revision. Their actual capture/proxy operation is
outside this standalone TUN lifecycle test.

## Upgrade contract

Earlier lifecycle and TUN tests keep their direct-only offline config. Immediately
before the upgrade, the harness saves a validated configuration containing a
credential-free loopback SOCKS canary via the existing CLI payload API. The route
selection is not changed. This provides a valid `server` node to the real
installer's node-migration path rather than weakening the installer to accept
non-migratable standalone data.

After real ksud installation and reboot, the harness verifies the node's type,
tag, endpoint, port and SOCKS version, the actual network-policy file, the private
migration marker and removal of the standalone marker. It does not re-seed any
configuration after reboot. Core readiness and the separate ordinary-app UID
TUN controls must still pass. The canary is migration data, not a listening proxy;
no proxy-connectivity success is inferred from its preservation. Regenerated
production policy may initiate background public probes, but those outcomes are
not counted as offline acceptance evidence.

## Resources and tests

Reports separate requested AVD RAM from observed `/proc/meminfo` MemTotal. A 2048
MiB request is not labelled as a measured 2 GiB device if the emulator raises it.
The pinned fixture also requires the observed Android SDK to be API 35.

```sh
python3 scripts/test-android-simulation-fixes.py
python3 scripts/test-android-simulation-fixes.py --check-core /path/to/sing-box
```

The first command exercises host-side archive and orchestration regressions, not
Android. The second validates initial and upgrade JSON with an actual built core.
Both commands are wired into the existing uncached harness/core-check steps.
A full Android/KSU job is still required before concluding that #344 is resolved.

## Pinned KernelSU x86_64 AVD kernel

An earlier CI revision mixed a KernelSU GKI with an SDK image whose vendor
modules were built for a different kernel and exposed a real `module_layout`
mismatch. Replacing that with a stock-kernel LKM late-load also proved invalid:
KernelSU v3.2.0 x86_64 requires kernel-side syscall-hardening compatibility
patches, so an arbitrary stock AVD kernel is not a valid late-load target.

The fixture now downloads the API35/6.6 x86_64 KernelSU v3.2.0 kernel built for
Android CI build 11987101, verifies the release archive SHA-256 and its
`build-info.txt`, then boots the emulator with that pinned `bzImage`. Official
`ksud` verifies that a positive KernelSU kernel interface already exists before
running upstream `late-load` to initialize userspace, `modules_update`, SELinux
policy, service and boot-completed stages. Every reboot repeats only this
userspace lifecycle activation; the harness never injects an LKM into the stock
kernel or manually substitutes `service.sh` for KernelSU lifecycle ownership.

This proves the pinned API35 x86_64 KernelSU-kernel path. Stock-kernel LKM
injection, ARM64 and OEM kernels remain explicit coverage gaps.
