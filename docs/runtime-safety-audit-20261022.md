# Runtime safety audit — 2026-10-22

Baseline: `4d32c02b11428a4d2d4c3b9a4acd9ecf1e14c0a6` (v1.7.0).

This audit covers the 21 open issues, the current Rust CLI, shell lifecycle and
subscription transactions, hotspot ownership, configuration watching, WebUI
checks, installer components, and the failing quality/Android acceptance runs.
It supplements [the #392–#398 validation record](issue-392-398-validation.md).

## Confirmed defects

| Area | Reproduced failure | Correction and regression evidence |
| --- | --- | --- |
| Configuration ownership | A SIGSTOP/traced owner was considered dead even though the parent-death watchdog can resume it to roll back. A second writer could enter before rollback. | Preserve live `T`/`t` owners. The real-process regression verifies rejection while stopped, matching ownership after resume, and reclamation only after exit. |
| Stale lock reclamation | A reclaimer could pass its last owner check, pause, and then unlink a new owner's marker. This affects both configuration and subscription locks. | Serialize publication, stale recheck/removal, and release with a persistent private metadata flock. Shell and Rust subscription writers use the same guard. The protected operation does not retain the metadata guard. Deterministic pause-at-unlink fixtures cover the former race. |
| Malformed lock metadata | FIFO owner markers could block indefinitely; a FIFO at the new metadata guard path would also block its open. | Refuse nonregular/symlink metadata before reading or opening it. Preserve corrupt evidence and fail closed. Bounded fixtures distinguish prompt rejection from a timeout. |
| Native subscription decoding | A failed decoder's valid prefix reached the native parser. URL-safe input could also be truncated by the first standard decoder attempt. | Normalize and validate the complete Base64 input, check decoder success before filtering URI lines, and discard failed output. Native and Proxylink imports share the implementation. New fixtures failed in ten baseline subcases and pass with the change, including pinned KernelSU BusyBox. |
| Transaction recovery | A malformed local `generation-id` such as `../../../unrelated-data` could direct cleanup outside its generation directory. | Validate a bounded filename component before any recovery mutation. Preserve the journal and current data on invalid metadata. Tests prove unrelated data survives and a corrected journal can still recover. This is a local recovery/data-loss finding, not a demonstrated remote exploit. |
| Supervisor discovery | A failed `ps` with partial output could be treated as a complete inventory. | Preserve the existing unknown result on enumeration failure. Partial-output fixtures must not report a verified absence. |
| Supervisor shutdown | Orphan cleanup returned success immediately after SIGKILL without verifying exit. Stop-all also discarded hotspot cleanup failures. | Re-observe after escalation, preserve unknown/alive results, and propagate cleanup failure. Regression fixtures cover live survivors, failed observations, and retained route evidence. |
| Supervisor restart | `stop; start` ran startup after a failed stop and could hide the original failure. | All three supervisor restart targets use `stop && start`. A real CLI fixture tests both failed-stop/no-start and successful restart. |
| Repair command | A successful kernel recovery hid a failed configuration materialization. | Require successful materialization before disruptive recovery. A real CLI regression fails on the baseline and verifies both failure propagation and the normal successful path. |
| Hotspot status | Disabled intent could hide retained or corrupt ownership journals and interrupted installations. | Observe pending interfaces and report unknown, pending, or degraded according to evidence. Only a clean observation reports disabled. Foreign routes remain outside cleanup ownership. |
| Configuration watching | Editor snapshots and `config.json.bak` changed the fswatch snapshot even though generated `config.json` was excluded. | Use the existing private `.magicnet-staging` directory with held directory descriptors and same-filesystem rename. Exclude the exact generated backup. Real CLI + pinned fswatch replay changes from two false triggers to none while preserving the new config and old backup. |
| Configuration versus subscription writes | Editor save and template sync could overwrite configuration during a live subscription transaction or before recovery of a dead updater's journal. | Acquire the existing subscription writer lock after the lifecycle lock, and reject pending recovery before mutation. Live-owner and pending-journal regressions fail on the baseline, preserve config/backup/markers with the fix, and allow a subsequent save after release. |
| CI cancellation | SIGTERM could leave the isolated test process group running. | Kill and reap the group on SIGINT/SIGTERM, preserve cancellation exit status, and never cache an interrupted success. Tests include a child configured to exit zero on cancellation. |
| Browser CI budget | The six-viewport suite crossed the Actions step's ten-minute budget. | Keep the complete browser matrix, give Playwright an 18-minute suite deadline, and allow 20 minutes for the step and 30 for the job. |
| Android rollback evidence | Any CLI exit 1 could count as invalid-JSON rejection, including lock busy or payload permission failure. Early failures lost the failing operation. | Require the CLI's top-level validation error as well as the independent core rejection and positive control. Preserve bounded operation/kind/exit/output-count evidence and sanitized service observations. Cleanup failures cannot replace the primary error or turn an incomplete check into success. |

The metadata guard files are private synchronization inputs. They do not add
canonical state domains or change machine-interface schema 1. Persistent user
intent, runtime observations, and resource ownership retain their existing
separation.

## Verification and limits

The relevant regression groups are maintained in the existing quality gates:

```sh
bash scripts/quality-gate.sh rust
bash scripts/quality-gate.sh shell
bash scripts/quality-gate.sh components
bash scripts/quality-gate.sh webui-check
bash scripts/quality-gate.sh webui-browser
python3 scripts/test-android-device-simulation.py
python3 scripts/test-android-tun-proof.py
python3 scripts/test-android-network-benchmark.py
MAGICNET_KSU_BUSYBOX=/path/to/pinned/busybox python3 scripts/test-android-utf8.py
```

The subscription/parser/recovery audit passed 19 relevant test scripts. The
Clash suite ran 25 tests: 21 passed and four optional real-converter cases were skipped.
WebUI unit tests, type checking, and the production build passed; focused
browser checks exercised all six viewport sizes plus every page in light and
dark mode at the narrowest viewport. The complete browser matrix and exact
lockfile dependency versions are checked by the PR workflow.

Local Rust verification includes strict Clippy and all workspace tests.
Component verification includes Go formatting, vet, race tests, installer
identity/lifecycle checks, archive safety, and release gates. The local Go
toolchain is 1.27.2; CI pins 1.26.7. Real process tests require a coherent PID
namespace and `/proc` view and were run in isolated fixtures with that access.

The local host suite reached release integrity after passing lifecycle,
ownership, DNS, configuration, subscription, and WebUI cache regressions. It
cannot attest to recursive release-submodule integrity because the local
checkout does not initialize all unrelated build/rules gitlinks. The PR's
recursive checkout must supply that final coverage. No local optional prepared
routing-asset or real-provider network result is inferred from these fixtures.

The earlier Android run
[39716922145](https://github.com/LIghtJUNction/MagicNet/actions/runs/39716922145)
passed its app-UID TUN positive/reject/restore controls, then failed invalid
configuration rollback in 2.083 seconds. The lost command output prevents a
definitive diagnosis of that historical failure. The editor/watcher problem
was reproduced independently; the new bounded evidence will identify the
operation and failure class in subsequent AVD runs. No retries, longer sleeps,
disabled watchers, or relaxed network acceptance criteria were added.

No affected physical phone or tethered client was connected during this audit.
AVD success is not proof of OEM-specific networking, IPv6 hotspot connectivity,
public-network stability, or Android startup performance.

## Issue disposition

Issue comments record the final PR/CI evidence and disposition after integration.

| Issues | Audit conclusion |
| --- | --- |
| #392, #393, #394, #395, #397 | The specific code defects have targeted regression coverage; eligible for closure after integration and passing gates. Historical orphan recovery and device timing claims are explicitly outside that proof. |
| #396 | Fingerprint work was reduced in #399, but the reported total fork count and 35–37 second device startup have not been remeasured. Keep open. |
| #398 | Async/pending UI improvements exist; backend progress/cancellation, broader queue separation, and remaining UX requests are incomplete. Keep open. |
| #254 | Recovery safeguards now include corrupt-generation protection. The original zero-byte configuration cause and Android storage-failure acceptance remain unproven. Keep open. |
| #331 | The reported source transport timeout is not the Base64 parsing bug. Keep open pending transport evidence. |
| #335, #336, #337, #389 | Existing IPv6 exemption, graceful-stop, and return-route fixes have code/fixture coverage; the explicitly requested physical-device acceptance and remaining domain/DNS/TLS behavior are not established. Keep open. |
| #253, #305, #329 | OEM per-UID network policy is tracked separately from selector routing. Do not treat one device's recovery or current route tests as cross-OEM closure. |
| #324 | The supplied route-baseline failure does not establish a unique cause or verified resolution. Keep open. |
| #261 | The staged upstream TUN migration is a separate incomplete project. Keep open. |
| #281 | Repository rulesets were empty when checked. Source fixes do not enforce repository administration policy. Keep open. |
| #377, #381 | Public-network stability and custom-core Tailscale data-plane failures still require their original acceptance evidence. Keep open. |
