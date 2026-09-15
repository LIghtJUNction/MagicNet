# MagicNet file-backed state plane

MagicNet treats files as the durable device-state boundary. Runtime code may keep short-lived local variables while performing an operation, but a state that another process, a later invocation, WebUI, MCP, diagnostics, or crash recovery needs to observe must have one canonical file representation.

## Canonical state directory

Canonical machine snapshots live under:

```text
.state/machines/
  service.state
  transparent.state
  subscription.state
  subscription-refresh.state
  supervisors.state
  wifi.state
  hotspot.state
  dns.state
  mcp.state
  tailscale.state
  transactions.state
```

Each file is a small line-oriented record:

```text
schema=1
domain=service
lifecycle=running
process_count=1
selected_core=sing-box
state=running
transparent_phase=idle
```

The format intentionally stays dependency-free for shell readers and easy to parse from Rust. Values are bounded tokens, not free-form text.

## One state domain, one file

A state domain must have exactly one canonical `.state` file. Do not encode logical state in any of these forms for new code:

- directory existence alone;
- several unrelated marker files that callers must combine;
- a PID file plus a second status string plus a third error marker;
- duplicated Rust/WebUI enums that independently guess device state;
- human-oriented CLI output parsed back into a machine state.

A canonical domain file may contain several fields because configured state, observed state, transition phase, ownership, and readiness are different facts. A reader that needs one domain gets those facts from one file instead of reconstructing them from unrelated markers.

## Transactional publication

`magicnet-cli` reconciles all canonical machine records from one observation pass. It calculates the complete snapshot first, compares it with the previous files, and sends all changed records through the existing multi-file transaction primitive. The transaction stages and syncs replacements and rolls already-published files back if a later replacement fails.

This is a recoverable multi-file commit, not a claim that every file rename is simultaneously visible to lock-free readers. A reader that needs a cross-domain point-in-time snapshot should use the versioned machine interface rather than independently racing several `.state` files.

Normal control/human CLI commands reconcile before dispatch and again after dispatch so mutations leave a settled canonical snapshot. Internal bounded `/proc` reader subcommands bypass reconciliation so process discovery cannot recurse into another state reconciliation. `--json` machine requests also remain read-only and do not create or rewrite state files.

## Legacy files are compatibility inputs

The project already has durable artifacts such as:

- `.state/transparent-transaction/`;
- `.state/sing-box/subscription-status`;
- `.state/sing-box/subscription-transaction/`;
- supervisor PID/owner files;
- `.state/wifi-policy/last-state.conf`;
- hotspot route/offload ownership files;
- DNS leak-guard interface ownership.

During migration these remain recovery/ownership inputs. The reconciler projects them into `.state/machines/*.state`. They are not a license for new consumers to keep adding direct parsers.

New consumers must use the canonical state plane or the versioned `cli --json` machine interface. Existing writers can be migrated one domain at a time; once no recovery path needs a legacy file, it can be removed.

## State versus artifacts

Not every file below `.state` is a state machine.

Caches, validated checkpoints, selector selections, generated subscription work, eBPF probe reports, and transaction backups are artifacts. They may be needed to reconstruct or verify state, but their existence is not itself a public state unless the canonical domain file says so.

Transaction journals are the exception: they are durable recovery evidence. Their detailed backup payload may remain a directory, while the corresponding canonical domain file exposes only bounded facts such as `transaction_active=1` and `phase=old-stopped`.

## External truth

A file must not turn stale observation into truth. Process, cgroup, TC, interface, and kernel state originate outside MagicNet. Reconciliation verifies available external evidence and publishes a bounded result such as `running`, `stale`, `unknown`, or `pending`.

Unknown is a real state. A failed `/proc` read, ambiguous owner, or unavailable kernel evidence must not be rewritten as success.

## Privacy

Canonical state files are safe machine state, not debug dumps. They must never persist:

- subscription URLs;
- tokens, secrets, passwords, auth keys;
- SSID/BSSID values;
- raw failure reasons;
- arbitrary command output;
- complete user configuration.

Use booleans, counts, normalized modes, and bounded state tokens instead. For example Wi-Fi stores `has_ssid=1`, not the SSID itself.

## Desired, observed, and phase

Use explicit names when a domain needs more than one dimension:

- `configured` or `desired_*`: persisted user intent;
- `effective_*` or `observed_*`: verified runtime result;
- `state`: coarse lifecycle state;
- `phase`: current transaction/reconciliation phase;
- `*_owned`: whether MagicNet owns a resource that must later be restored;
- `*_pending`: an expected condition that is not ready yet.

Do not overload `state=running` to mean configured, process exists, dataplane is attached, and API is ready at the same time.

## UI state boundary

Vue-only interaction state such as a pressed button, an open dialog, editor dirtiness, or the foreground command queue is not device state and does not belong on Android storage. It may remain in memory.

The distinction is simple: if restarting/reloading WebUI may safely forget it, it is presentation state. If another process or a later CLI invocation must know it, it belongs in the file-backed state plane.

Background operations that outlive WebUI must have device-side evidence (journal, owner record, or log completion marker) and be projected back into a canonical state file.

## Migration rules

1. Do not add new ad-hoc files under `.state` for a new lifecycle state.
2. Extend the appropriate canonical domain file instead.
3. Keep values bounded and privacy-safe.
4. Publish each domain file atomically; for related multi-file changes use the recoverable module transaction instead of truncating files in place.
5. Persist a transaction phase before performing an irreversible/externally visible next step.
6. On recovery, reconcile journal + external truth and publish one canonical settled state.
7. Add regression tests for interrupted transitions, stale owners, unknown process state, and redaction.
8. Once all producers/consumers for a legacy state path are migrated, delete that compatibility path rather than maintaining two permanent truths.
