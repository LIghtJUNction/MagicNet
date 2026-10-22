# Remaining issue repairs — 2026-10-23

This audit continues [the runtime follow-up](runtime-followup-20261023.md)
and [PR #402](https://github.com/LIghtJUNction/MagicNet/pull/402).
The initial regressions were reproduced against that PR's frozen head,
`d0ddff50c990d139fe2fca62f3502195cbb25a08`. Additional fault injection into the
first recovery-order repair exposed the journal-validation defects described
below. The patch incorporates the subsequent #402 merge and unrelated upstream
release/workflow and Bun lock updates.

## Interrupted transparent recovery must honor cleanup and stop failures

The recovery helper previously stopped the core before detaching interception,
ignored both stop and cleanup failures, restored configuration, and removed its
journal anyway. A surviving core could therefore use a different mode from the
restored files, or failed cleanup could leave traffic targeting a dead listener.
The startup preamble also implemented its own incomplete stop/cleanup sequence.
Real CLI `config apply`, `transparent set`, and service-start recovery reached
these paths. The new fixture failed 70 subcase assertions on the old code,
including commands returning success after a stop failure and deleting the
evidence needed for retry.

Recovery now stops the hotspot watchdog, runs the existing bounded network
cleanup, confirms core shutdown, and only then restores configuration and state.
Each preparatory failure returns immediately. The startup preamble delegates to
that same sequence. Cleanup and stop failures preserve the active config, mode,
and complete journal and do not start a replacement core or generate a candidate.
Cleanup may already have removed some network resources before a later cleanup
step fails; this is not a claim that every side effect is rolled back.

Failure during the subsequent file restoration retains the journal for retry.
Some files may already have been restored at that point. The change does not
claim atomic visibility or automatic rollback of the entire multi-file restore.

The regression executes production recovery, startup, network-stop preparation,
and configuration writers with isolated process/network and I/O fault fixtures.
It covers current and legacy journals, watchdog failure, each cleanup failure,
core-stop failure, mode/config/state write failures, journal-removal failure,
successful retry, and recovery followed by restart. The initial cleanup/stop
regression set covers 57 shell subcases across sh, bash, and BusyBox ash, plus
17 cases invoking the real CLI. Journal validation extends that set as described
below. A Rust integration target supplies the built CLI to all CLI cases; the
host shell gate also registers the Python suite. These tests are not
physical-device networking acceptance for #336 or #337.

## Validate the whole transparent journal before any recovery side effect

Correct stop ordering alone did not make damaged journals safe. The transparent
recovery path still used unbounded `cat` for metadata and checked some required
backups only after stopping the core and restoring earlier files. FIFO metadata
blocked recovery; a late snapshot marker FIFO blocked after mode/config changes.
Missing config or eBPF backups also failed only after earlier side effects.
Soft links, NULs, extra trailing newlines, and contradictory presence markers
could be accepted, sometimes allowing journal removal or deletion of active
files despite surviving backups.

The startup preamble and Rust CLI also detected interrupted transactions with a
directory-only test. A file, FIFO, or dangling symlink at the journal path could
therefore bypass recovery entirely. A symlink to a directory was followed.

The repair validates all inputs used for restoration before watchdog shutdown,
cleanup, core shutdown, or file restoration: a real journal directory, bounded complete
metadata tokens, expected marker values, and consistent readable regular backup
files without symlinks. Every existing journal entry reaches validation through
the CLI and startup gates; the Rust gate also propagates inspection errors
instead of treating them as absence.

Legacy journals without eBPF snapshots remain supported only when all eBPF
snapshot metadata and backups are absent. The
[snapshot-format introduction](https://github.com/LIghtJUNction/MagicNet/commit/0ce299597c3b61ef993774666b2bd87a6fe6fcc4)
and its [direct parent](https://github.com/LIghtJUNction/MagicNet/blob/a0160cc37adbb4a14098c9ce3a77159823009a5f/crates/magicnet-cli/src/service.rs)
show the writer moving from no snapshots to staging the complete snapshot set
and version before publishing the directory with rename. Partial snapshot
evidence without its version is not a valid legacy format in that transition.
Valid explicit absence markers for the old mode/config still restore absence.
This does not require a config baseline when the transparent transaction
legitimately started without one, and does not change the separate subscription
journal compatibility policy from #402.

The validator restricts recovery tokens without introducing required
`phase`/`target-mode` fields or a new content policy for byte-exact backups.
Legacy detection explicitly enables glob expansion inside its subshell, so a
caller using `set -f` cannot hide surviving snapshot evidence. New regressions
cover root types, all eight metadata files, all five backups, explicit absence,
bare tokens, empty backups, read/stat failures, and both globbing states.

Prevalidation cannot guarantee that later I/O will succeed. A later restore
failure still preserves the journal for retry rather than claiming the entire
multi-file operation was atomic.

## Validate route-ledger file type before the prepared-state shortcut

`magicnet_kernel_route_state_begin` inspected an existing ledger with `grep`
before checking its file type. A FIFO blocked the operation. A symlink to a
prepared ledger, or a dangling symlink, could be replaced by a newly written
ledger, discarding the original recovery entry.

The function now recognizes dangling links and requires any existing ledger to
be a readable regular file without a symlink before reading it. Invalid entries
return status 2 and remain available for diagnosis. Three regressions first
failed on the old implementation, then passed while checking inode, file type,
link target, target contents, and absence of kernel writes. The timeout helper
also terminates the fixture's process group so the old FIFO reproduction cannot
leave a blocked child behind.

This is a confirmed defect in the route-baseline path discussed in #324. The
original report contains `stage=route-baseline exit=2` but no evidence that its
ledger was one of these abnormal types, so the original device failure still
requires separate verification.

## Preserve every validated download address and handle IP literals

The Rust HTTPS downloader added a separate curl `--resolve` argument for each
address of the same host and port. Repeated entries replace that authority's
address set, leaving only the last candidate. A local real-curl reproduction
returned connection error 7 when that final address was unreachable; a single
entry containing both candidates succeeded. Reversing the old entries also
succeeded, confirming the replacement behavior rather than a generic network
failure.

The downloader now validates the complete resolved set before constructing one
entry containing all IPv4 and bracketed IPv6 addresses. Sorting and deduplication
remain deterministic. Empty sets or any disallowed address reject the entire
request before spawning curl.

The same helper previously generated an IPv6 host in `--resolve` for a valid
public IPv6 literal URL. The locally installed curl rejected that argument with
error 49. Public IP literals need no DNS override, so both literal families now
use the already validated URL directly. Private literal URLs are still rejected
before a child process starts. HTTPS-only requests, TLS validation, disabled
proxies, and refusal to follow redirects retain their existing policy.

Four new unit tests cover single/multiple A and AAAA answers, dual-stack sets,
deduplication, mixed private/public answers, empty sets, and public/private IP
literals. An isolated real-CLI fixture verifies five argument/refusal cases on
the old and new binaries. Its curl stub deliberately returns timeout 28 after
capturing arguments, and its DNS shim rejects every hostname except a synthetic
fixture domain. The real-curl controls only use loopback HTTP and `file:`.
These checks establish argument construction and rejection behavior, not a
successful public HTTPS download.

This Rust helper serves community blocklist and WebUI-panel downloads. The shell
subscription downloader already uses one complete address entry and bypasses
DNS overrides for IPv6 literals. Consequently this fix does not establish
resolution of the original subscription connection timeout in #331.

## Keep cached test results tied to their actual inputs

The Rust integration tests execute the transparent-recovery Python fixture and
read production shell modules. The previous Rust cache scope covered crates and
the default config but omitted those inputs, so changing them alone could reuse
an earlier successful test result. The scope now includes the exact Python
fixture and the production `magicnet` shell-module directory, also covering the
existing eBPF observation and subscription tests that read those modules.

The host start/stop regression also reads Rust `service.rs` and `commands.rs`.
Those two exact inputs now invalidate the host scope. Fingerprint regressions
change each external input independently and require a different cache key;
the unrelated WebUI and broader crate trees are not added to these scopes.

## Verification

The final patch passed the following local checks with locked dependencies:

| Check | Result |
| --- | --- |
| Rust workspace, all targets and all features | 776 passed; one existing Android/mksh-specific test ignored |
| Rust formatting and strict Clippy | Passed |
| Transparent recovery fault suite | 12 methods, 551 subcases passed: 486 shell cases and 65 real-CLI cases |
| Route ownership suite | 59 passed in each of sh, bash, and BusyBox ash |
| Existing start/stop rollback suite | 15 passed |
| Isolated real-CLI download arguments/refusal | 5 cases passed |
| CI cache fingerprints | 21 tests passed, including 11 external-input mutation cases |
| Complete ShellCheck and source sanity checks | Passed |

The 65 real-CLI transparent recovery cases are also run inside one of the 776
Rust tests; they are not an additional 65 Rust tests. Local Rust is 1.99.1.
BusyBox host compatibility uses the official 1.35.0 binary. GitHub's quality
workflow installs stable Rust, and Android acceptance exercises the separately
shipped KernelSU environment. The local checks do not replace either CI or
device-specific issue acceptance.

Representative commands:

```sh
cargo fmt --all -- --check
cargo clippy --offline --locked --workspace --all-targets --all-features -- \
  -D warnings -D clippy::dbg_macro -D clippy::todo -D clippy::unimplemented
cargo test --offline --locked --workspace --all-targets --all-features
bash scripts/lint-shell.sh
python3 -B scripts/lint-source.py
python3 -B scripts/test-ci-test-cache.py
MAGICNET_RECOVERY_TEST_CLI=/path/to/built/magicnet-cli \
  python3 -B scripts/test-transparent-recovery.py
python3 -B scripts/test-route-ownership.py
MAGICNET_TEST_SHELL=bash python3 -B scripts/test-route-ownership.py
MAGICNET_TEST_SHELL=busybox python3 -B scripts/test-route-ownership.py
python3 -B scripts/test-start-stop-rollback.py
```

## Remaining issue acceptance

All 16 issues below remained open when their bodies and existing evidence were
reviewed. A local fix or an emulator pass does not by itself satisfy an issue
that expressly requires affected-device or external-network evidence.

| Issue | Current boundary and next evidence needed |
| --- | --- |
| [#253](https://github.com/LIghtJUNction/MagicNet/issues/253) | Verify Play search, images, and downloads on the affected device through the selected Google outbound; distinguish provider behavior from OEM UID restrictions. Do not override the user's outbound choice with forced direct routing. |
| [#254](https://github.com/LIghtJUNction/MagicNet/issues/254) | #402 hardens subscription recovery metadata. The historical zero-byte cause and requested on-device failure/recovery validation remain unproven. |
| [#261](https://github.com/LIghtJUNction/MagicNet/issues/261) | The pinned core already supports the Go TUN stack. Migration still requires coordinated configuration/smoke-check changes, hotspot return-path review, and Android A/B evidence. |
| [#281](https://github.com/LIghtJUNction/MagicNet/issues/281) | The API still reports no rulesets and an unprotected main branch. Server-side PR/review/CI requirements and force-push/deletion protection must be enabled and their allow/deny behavior verified. A source patch does not activate them. |
| [#305](https://github.com/LIghtJUNction/MagicNet/issues/305) | Obtain complete same-device Play/GMS failure and success samples with actual outbound and DNS context; the old report is incomplete. |
| [#324](https://github.com/LIghtJUNction/MagicNet/issues/324) | Abnormal route-ledger handling is fixed here. Reproduce the reported route-baseline failure with the actual device and ledger context before assigning its root cause. |
| [#329](https://github.com/LIghtJUNction/MagicNet/issues/329) | Oplus has user-confirmed recovery. Other OEM adapters, reboot/network reassertion, and real app-UID DNS/networking remain to be checked. Policy readback is not effective DNS evidence. |
| [#331](https://github.com/LIghtJUNction/MagicNet/issues/331) | The Rust downloader defects fixed here affect other callers. Verify the original subscription endpoint, device, and connection timeout separately. |
| [#335](https://github.com/LIghtJUNction/MagicNet/issues/335) | Existing interface-scoped IPv6 bypass and hook ordering require a hotspot client with routable IPv6, plus TCP/UDP checks after reboot and reconnect. Link-local alone is insufficient. |
| [#336](https://github.com/LIghtJUNction/MagicNet/issues/336) | Recovery now honors the shared cleanup/stop contract. Repeat stop/start on the affected device and check app IP traffic, system DNS, and module-owned rules/routes. |
| [#337](https://github.com/LIghtJUNction/MagicNet/issues/337) | The issue explicitly leaves physical-device repeated lifecycle and networking acceptance unchecked. The new host regressions do not complete that checkbox. |
| [#377](https://github.com/LIghtJUNction/MagicNet/issues/377) | Empty `adb reverse` handling is already fixed. Successful public preparation/TLS, a 600-second app-UID window, and raw latency/resource evidence are still required. |
| [#381](https://github.com/LIghtJUNction/MagicNet/issues/381) | Fork/official TUN and WireGuard differences are verified, but causation is not. Need controlled core A/B with DISCO, TSMP, and ADB evidence before changing the pin. |
| [#389](https://github.com/LIghtJUNction/MagicNet/issues/389) | Actual UID-0 return-route inspection already exists. Verify DNS answers and TLS destinations separately; route readiness does not prove domain access. |
| [#396](https://github.com/LIghtJUNction/MagicNet/issues/396) | #402 reduces repeated successful-path cleanup. Measure startup/shutdown time and fork count on the reported realme/APatch configuration. |
| [#398](https://github.com/LIghtJUNction/MagicNet/issues/398) | #402 separates status reads from writes and reduces duplicate cleanup. Device progress/cancellation, topology latency, log policy, and broader device acceptance remain. |

For #261, the pinned fork's
[go.mod](https://github.com/LIghtJUNction/sing-box/blob/871b7a3440cd9c850f1b09ef3b4ada9babb4384b/go.mod)
uses `sing-tun v0.9.7-0.20261002083955-3f8acd9da65b`. Its
[TUN inbound](https://github.com/LIghtJUNction/sing-box/blob/871b7a3440cd9c850f1b09ef3b4ada9babb4384b/protocol/tun/inbound.go)
and the dependency's
[stack selection](https://github.com/SagerNet/sing-tun/blob/3f8acd9da65b/stack.go)
include Go support, with an empty stack or `go` selecting `NewGo`. MagicNet still
explicitly emits `mixed`, its package/orchestrator checks require `mixed`, and
hotspot address mapping assumes the existing mixed/system behavior. Removing
one configuration field would leave those contracts inconsistent.
