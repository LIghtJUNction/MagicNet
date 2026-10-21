# Issues #392–#398: hotspot lifecycle fixes and validation

Baseline: `968ddb65f4c7ad01bc26d74471e00e71392cb74f`.

## Scope and resulting behavior

| Issue | Change | Boundary |
| --- | --- | --- |
| [#392](https://github.com/LIghtJUNction/MagicNet/issues/392) | Mark inherited descriptors above stderr close-on-exec at CLI entry. Use `close_range(CLOSE_RANGE_CLOEXEC)` when available and enumerate actual open descriptors on older kernels. | Rust-owned files already have close-on-exec. The reproduced failure is a launcher-provided descriptor reaching a runtime shell. This patch does not identify or kill arbitrary historical lock holders. |
| [#393](https://github.com/LIghtJUNction/MagicNet/issues/393) | Check the effective hotspot policy before materializing configuration during enable, disable, reconciliation, and rollback. Skip full apply when the policy is already current. | A genuine topology or effective policy change can still require a full apply. Indeterminate discovery remains an error rather than a fast-path success. |
| [#394](https://github.com/LIghtJUNction/MagicNet/issues/394) | Serialize route mutation with the existing configuration lock. Observe and journal exact duplicate ingress rules for journal-owned interfaces before cleanup. Report observed and duplicate counts and reject false readiness. | Unowned interfaces, different tables, extra selectors, and ambiguous priority collisions are not blanket-deleted. Canonical machine readiness uses the same duplicate check without changing schema 1. |
| [#395](https://github.com/LIghtJUNction/MagicNet/issues/395) | Exclude generated configuration and fixed materializer outputs from fswatch. Place PID-suffixed materializer files in a private, excluded `.magicnet-staging` directory beside the target. | Editable source, subscription, and route-intent inputs remain watched. The underlying kamfw snapshot algorithm is unchanged. |
| [#396](https://github.com/LIghtJUNction/MagicNet/issues/396) | Batch rule fingerprint checksums in groups of at most 32 and remove redundant pipeline processes while preserving the fingerprint format. | This is a bounded reduction in one hot path. It does not establish an end-to-end Android startup speedup or resolve the entire process-creation issue. |
| [#397](https://github.com/LIghtJUNction/MagicNet/issues/397) | Serialize hotspot watchdog status, orphan recovery, launch, PID publication, and stop. Retain a verified healthy loop and remove only verified extra loops. | The short-lived parent owns the lifecycle lock; detached workers do not inherit it. Unknown process identity still prevents destructive recovery. |
| [#398](https://github.com/LIghtJUNction/MagicNet/issues/398) | Run hotspot toggles as existing background tasks; show pending service actions and elapsed time; separate queue-wait and execution budgets; remove the early refresh; continue slow polling after the quick tracking window; keep read-only refresh available. | Completion evidence releases conflicting writes. A tracking timeout alone does not authorize another write. Backend progress events, cancellation, separate read/write queues, broader stop deduplication, and the remaining enhancement requests are outside this patch. |

## Reproduced regressions

- **Inherited locks:** the new process-lifecycle fixture passes launcher descriptors
  9 and 256 to the real CLI. On the baseline, the runtime shell sees the lock;
  after this patch, it does not. Separate descriptor tests cover a forced
  `close_range` fallback, descriptors above a reduced soft limit, preserved
  standard streams, and handles intentionally retained inside the CLI.
- **Duplicate route rules:** baseline checks fail for false-ready status,
  residual historical ingress rules, and missing serialization. The patched
  ownership tests verify cleanup scope and preserve foreign rules and recovery
  evidence on failure.
- **Generated configuration:** the real pinned kamfw snapshot implementation
  ignores fixed and dynamic generated outputs while detecting representative
  editable inputs. Custom exclusions cannot remove mandatory generated-output
  exclusions. A symlinked staging directory is rejected.
- **Watchdog startup:** four concurrent baseline starts leave four loops with
  one published PID. The patched fixture leaves one loop and also covers
  duplicate recovery, missing PID recovery, start/stop races, decoy processes,
  unknown identity, and descriptor inheritance. Host `sh` and BusyBox ash checks
  verify that the parent holds the lock until the launcher finishes; the latter
  specifically guards against ash optimizing away the final subshell.
- **Fingerprint process count:** 65 literal rule paths require 65 rule checksum
  invocations on the baseline and at most three after batching. The test compares
  the complete old and new fingerprints, includes spaces/quotes/glob characters
  in filenames, and retains failure-propagation coverage.
- **WebUI:** fixtures cover pending startup, asynchronous hotspot success and
  failure/retry, read-only refresh during work, queue expiration before dispatch,
  a full execution budget after dispatch, and automatic recovery when a task
  completes after the quick polling window.

## Validation commands

These checks passed in the host environment used for this patch:

```sh
bash scripts/quality-gate.sh rust
python3 scripts/lint-source.py
bash scripts/lint-shell.sh
python3 scripts/test-route-ownership.py
bash scripts/test-hotspot-watchdog-lifecycle.sh
bash scripts/test-supervisor-start-policy.sh
bash scripts/test-supervisor-pid-safety.sh
bash scripts/test-supervisor-orphan-prefilter.sh
python3 scripts/test-supervisor-zombie.py
bash scripts/test-hotspot-routing.sh
bash scripts/test-route-apply-safety.sh
bash scripts/test-transparent-mode-config-safety.sh
bash scripts/test-ebpf-transparent-mode.sh
bash scripts/test-dataplane-policy-pins.sh
bash scripts/test-config-permissions.sh
sh scripts/test-runtime-fingerprint-safety.sh
python3 scripts/test-android-probe.py
(cd webui && npm run check)
git diff --check
```

The route ownership suite passed 49 cases with host `sh` and 49 with BusyBox
ash. The focused Rust hotspot suite passed 27 tests. WebUI passed 314 unit tests,
type checking, and its production build; browser fixtures at 320 px and 390 px
passed 16 initial scenarios plus six focused pending-state/refresh/retry cases.
The final wording adjustment also passed its 13 affected tests, type checking,
and a production build. The Android Java probe suite passed seven tests using
the installed OpenJDK 17 compiler and local TLS fixtures.

Real process tests require a coherent PID namespace and `/proc` view. They ran
outside the executor's restricted PID sandbox, using isolated local fixtures.

## Validation limits

- `bash scripts/test-host.sh` passed through the lifecycle, route, locking,
  fingerprint, DNS, rollback, subscription, and WebUI cache checks, then stopped
  at `test-release-integrity.sh`: this checkout lacks initialized unrelated
  build/rules submodules. The full host suite and `scripts/pre-commit.sh` are
  therefore not claimed as passing. The initial Java tool lookup failure was
  resolved using the real compiler already installed in OpenJDK 17.
- `scripts/fake-magisk-smoke.sh` was attempted. Its 12 curl-fixture tests passed,
  then setup stopped because no host `sing-box` executable is installed. The
  complete fake-Magisk smoke and prepared routing/DNS asset checks are not
  claimed as passing.
- The network-namespace route test could not run: `unshare -n true` is denied by
  the host even outside the executor sandbox. No host routes were modified to
  work around that restriction.
- No Android device was connected for this patch. Device startup timings,
  tethered-client connectivity, long-running toggle tests, and recovery of the
  reported six-hour historical lock holder still require device verification.
- The optional generic kamfw fswatch install-contract test fails on both the
  baseline and patched tree because its mock BusyBox executes a descriptor-10
  close with dash. It is excluded from the maintained host suite and was left
  unchanged; the pinned snapshot behavior relevant to this patch is tested
  separately.
