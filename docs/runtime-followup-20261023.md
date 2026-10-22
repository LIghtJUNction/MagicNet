# Runtime repair follow-up — 2026-10-23

Reproductions started from `fc73db5da6d0e056a3242c2d1e718794fc90912c`
(the merged #401 audit). The branch incorporates the subsequent release metadata
commit `f7a44bae94fc9d4aa4546f77e585044a69b913df`; that commit changes four version
files and does not change these runtime paths.

This continues [the runtime safety audit](runtime-safety-audit-20261022.md).
It does not establish physical-device acceptance for the remaining issues.

## Restart arguments must be validated before stopping anything

The real baseline CLI returned Usage for `service restart typo`, but only after
stopping the fixture's live configuration watcher, deleting its PID marker,
executing both stop hooks, creating the lifecycle lock file, and rewriting
canonical state. Two new integration regressions failed on that exact binary.

One pure target validator now runs before quiescing the watcher or acquiring
the lifecycle lock. The internal restart path validates before stopping the
core, and the dispatcher's state-publication decision uses the same validator.
Rejected targets leave existing canonical state unchanged. Default restart,
`current`, `sing-box`, and `singbox` still enter the normal lifecycle and publish
state after both successful and failed startup.

## Recovery requires complete, trustworthy transaction evidence

The old generation reader used an unbounded first-line read and treated read
failure as missing legacy metadata. A generation FIFO blocked recovery; a
directory or injected read error was accepted. A FIFO in `had-config` was treated
as an absent marker, so recovery deleted an otherwise valid active config.
An empty journal and missing ownership markers with surviving backups also
caused active data and recovery evidence to be deleted.

Recovery now validates all ten metadata fields before changing active files:

- The journal root must be a real directory. Existing metadata must be readable,
  regular files without symlinks. Missing fields remain distinguishable from
  malformed fields.
- Generation, phase, and input mode are complete bounded tokens, with at most
  one terminal LF. Reads retain trailing bytes for validation and reject NULs,
  extra lines, oversized content, short reads, and I/O failures. Phase and mode
  use the existing token format rather than a newly restricted vocabulary.
- Presence markers must be empty. A surviving optional backup with a missing
  ownership marker is inconsistent and is rejected before any restoration.
- A configuration ownership marker and independently validated old config are
  required. Recovery no longer has a branch that deletes the active config
  because that marker is absent.

Damaged journals, active config, work data, source files, and staged generation
evidence remain available after rejection. Valid legacy journals can still omit
generation, phase, and input mode. Optional components can still be absent when
both their marker and backup are absent.

There is an intentional compatibility restriction: early versions could publish
a transaction without a config baseline. Such a journal is now preserved and
recovery fails; it is no longer interpreted as permission to remove the current
config. This does not prove the cause of the historical zero-byte file in #254,
whose requested on-device failure-recovery acceptance remains outstanding.

## Reuse successful hotspot cleanup within the same locked operation

Normal post-stop finalization cleaned hotspot routes in kernel cleanup, then
cleaned them again inside offload restoration. The new regression counted two
calls where one suffices. Finalization now reuses a successful cleanup only in
that same operation, while its lifecycle lock remains held and the core is
stopped. No persistent skip marker is introduced.

The normal complete stop retains its pre-stop cleanup and one post-stop cleanup
(three hotspot passes become two). The public offload-restore helper still
performs its own cleanup when called independently. Kernel inspection/flush
failure still attempts independent offload recovery; failed hotspot cleanup or
offload restoration retains the corresponding recovery evidence.

The locked Rust hotspot-disable and successful compensation paths also avoid a
second cleanup after offload restoration. Failed restoration still gets the
independent route-compensation attempt. The unlocked startup replay path retains
its extra cleanup because the same exclusion proof does not apply there.

## Keep status and log observations responsive during writes

Cross-review found that the eBPF observers were not actually read-only: machine
service/transparent status, human transparent status, and health called a shell
helper that replaced `probe.json` on success and deleted it on failure. A query
could therefore interfere with lifecycle recovery evidence. Four real-CLI
regressions failed on the old production paths because observation changed the
report's inode, mode, or contents.

Those callers now share a bounded Rust observer. It invokes the shipped core's
status command directly, limits each captured stream to 512 KiB and execution
to five seconds, validates the returned JSON in memory, and reports unavailable
evidence on launch, exit, timeout, truncation, or schema failure. It does not fall
back to an old disk report. Existing program ownership and actual attachment
checks remain necessary; a matching program name alone does not report an
attached dataplane. Lifecycle operations retain their report publisher.

The CLI regressions cover all four observation entry points with successful and
failed core replies, both with existing state and with no state directory (16
scenarios). Existing state remains byte-for-byte unchanged, including inode and
mode; observation does not create a new state directory. These fixtures do not
claim that real eBPF attachments were exercised on Android.

The separate health capability probe also had a capture-size defect. One
successful local TCP/UDP path reconstructed from the
[pinned probe source](https://github.com/LIghtJUNction/sing-box/blob/871b7a3440cd9c850f1b09ef3b4ada9babb4384b/common/ebpf/kernel_probe.go)
has 23 findings and about 5.5 KiB of
[formatted JSON](https://github.com/LIghtJUNction/sing-box/blob/871b7a3440cd9c850f1b09ef3b4ada9babb4384b/common/ebpf/kernel_probe_render.go),
exceeding the previous 4 KiB capture limit even with no error and no active
program entries. This is a source-derived example, not a device capture.
Only that probe now uses a 512 KiB limit; unrelated diagnostics retain
their smaller limit. Truncated output, timeout, and unsuccessful exit still fail
the capability check.

The WebUI previously used one serial queue for mutations, status refreshes, and
background log following. A held native callback prevented observers from even
reaching the device. Four new dispatch regressions failed before the split.

Reviewed status readers and the generated background-log command now use a
separate serial read queue. There is at most one active reader and one active
writer. Arbitrary shell commands, private payload operations, and generic JSON
requests retain the write default; JSON requests can include mutations.

Both queues preserve the existing separate waiting/execution budgets. A caller
timeout does not release an underlying native command's slot, and an expired
waiting entry never executes later. A completed read cannot release a write.
Background work with an unknown outcome continues to be reconciled.

The page also accepts a fresh runtime observation while a write is busy. Shared
output and progress still belong to the foreground operation, and an observation
superseded by a newer foreground owner is discarded. Failed observations clear
stale running/RSS data without replacing the running operation's feedback.

## Verification

The regression suite includes production functions, real isolated CLI processes,
and native callback fixtures; the browser bridge fixtures do not execute Android
commands. Tests verify both preservation on failure and successful control paths.

Commands used for the affected areas:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- \
  -D warnings -D clippy::dbg_macro -D clippy::todo -D clippy::unimplemented
cargo test --workspace --all-targets --all-features --locked
bash scripts/lint-shell.sh
bash scripts/test-subscription-transaction-journal-safety.sh
bash scripts/test-subscription-transaction-atomicity.sh
bash scripts/test-subscription-baseline-safety.sh
bash scripts/test-config-empty-recovery.sh
bash scripts/test-subscription-fetch-policy.sh
bash scripts/test-subscription-lifecycle.sh
python3 scripts/test-route-ownership.py
MAGICNET_TEST_SHELL=bash python3 scripts/test-route-ownership.py
python3 scripts/test-start-stop-rollback.py --all-shells
bash scripts/test-hotspot-routing.sh
cd webui && npm run check
npm run test:ui -- e2e/command-execution.spec.mjs --project=desktop --project=phone-390
```

Local Rust validation uses 1.99.1 and locked dependencies: 771 tests passed and
one existing Android/mksh-specific test remained ignored. WebUI validation
passed 320 tests, type checking, and the production build. The focused native
callback browser regression passed at desktop and phone-390 viewports, including
status refresh during held writes and preservation of foreground progress.
The quality workflow
installs the stable Rust toolchain; its action revision is pinned, not the Rust
version. Process/lock regressions run with a coherent PID and `/proc` namespace.
The subscription metadata parser was additionally exercised with official
BusyBox 1.35.0 ash and its file-reading applets, including NUL/newline boundaries
and denied permissions. This host compatibility check is separate from Android
and the module's shipped KernelSU BusyBox acceptance.

## Remaining issue scope

#398 receives read/write queue separation and successful-path hotspot cleanup
deduplication. A device-side progress/cancellation protocol, topology-change
latency, log-volume policy, and the broader requested device acceptance remain
open. #396 still needs startup/fork measurements on the reported device; fewer
cleanup calls are not a measurement of that device's startup or shutdown time.
#254 still requires its requested on-device recovery validation.
#331's reported connection timeouts still require device/network evidence;
fetch-policy regressions do not establish resolution of that transport failure.
