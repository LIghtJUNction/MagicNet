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
  selectors.state
  app-policy.state
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

A state domain must have exactly one canonical `.state` file. Do not encode public logical state in any of these forms for new code:

- directory existence alone;
- several unrelated marker files that callers must combine;
- a PID file plus a second status string plus a third error marker;
- duplicated Rust/WebUI enums that independently guess device state;
- human-oriented CLI output parsed back into a machine state.

A canonical domain file may contain several fields because configured state, observed state, transition phase, ownership, and readiness are different facts. A reader that needs one domain gets those facts from one file instead of reconstructing them from unrelated markers.

Detailed recovery payloads and runtime evidence may still need their own files. Those files are implementation artifacts, not a second public state contract.

## Config is desired state

`.config` and `.state` have different ownership:

- `.config/`: desired/persistent user intent;
- `.state/machines/`: normalized observed/recoverable device state;
- other `.state/` files: migration inputs, transaction journals, caches, checkpoints, owner records, or raw runtime evidence;
- `.log/`: human diagnostic history.

A persistent user choice must not be hidden in `.state`. Selector choices therefore live at `.config/magicnet/selector-selections.json`. The previous `.state/sing-box/selector-selections.json` path remains a read-compatible migration source; the next successful selector save writes the `.config` path and removes the old file only when every legacy key/value has been preserved.

## Transactional publication

`magicnet-cli` reconciles all canonical machine records from one observation pass. It calculates the complete snapshot first, compares it with the previous files, and sends all changed records through the existing multi-file transaction primitive. The transaction stages and syncs replacements and rolls already-published files back if a later replacement fails.

This is a recoverable multi-file commit, not a claim that every file rename is simultaneously visible to lock-free readers. A reader that needs a cross-domain point-in-time snapshot should use the versioned machine interface rather than independently racing several `.state` files.

At the CLI boundary, known read-only queries, help, and rejected top-level commands do not trigger state publication. Control commands reconcile after dispatch, including failure paths that may have rolled back. There is no unconditional pre-dispatch scan. The explicit `cli state reconcile` command owns its publication and is not wrapped in two additional reconciliations. Internal bounded `/proc` readers bypass reconciliation so discovery cannot recurse. `--json` machine requests remain read-only and do not create or rewrite state files.

Long-running producers must publish when their internal observed state changes rather than waiting for process exit. The Wi-Fi watcher does this after each confirmed/reconciled policy application. Other maintenance loops already invoke ordinary CLI commands for each mutation and therefore pass through normal reconciliation.

## Durable state inventory

The repository's durable runtime files fall into three groups.

### Projected into canonical state

| Legacy/config evidence | Canonical domain | Meaning |
| --- | --- | --- |
| `.state/startup-error` | `service.state` | startup error presence only; raw error text is not copied |
| sing-box process discovery + selected core config | `service.state` | process/lifecycle/core state |
| `.state/transparent-transaction/`, eBPF capability/pending evidence, active sing-box config | `transparent.state` | configured/effective mode and transition phase |
| subscription status, update lock, subscription transaction | `subscription.state` | update phase/result/recovery status |
| subscription refresh schedule + owner/process identity | `subscription-refresh.state` | active/stale/unknown refresh owner |
| `.config/magicnet/selector-selections.json` with legacy `.state` fallback | `selectors.state` | selector store validity/count without node names |
| app mode + `.state/app-policy/*uids.list` | `app-policy.state` | policy mode and resolved UID counts |
| fswatch/Wi-Fi/kernel/hotspot supervisor PID/owner evidence | `supervisors.state` | supervisor lifecycle |
| Wi-Fi config + `.state/wifi-policy/last-state.conf` | `wifi.state` | policy and last confirmed effective decision |
| hotspot offload ownership + TUN route rule ownership | `hotspot.state` | disabled/waiting/active/shared state |
| `.state/dns-leak-guard.ifaces` | `dns.state` | owned DNS guard interface count |
| MCP config + `.state/magicnet-mcp.pid` | `mcp.state` | enabled/process/secret-presence state |
| sing-box Tailscale endpoint config + auth-material presence | `tailscale.state` | endpoint cardinality/configuration state |
| transparent/subscription/module-file transaction evidence | `transactions.state` | coarse transaction activity |

### Journals and ownership evidence

These files are intentionally retained because they contain information needed to recover or safely undo a mutation. Consumers should not use them as public status APIs.

- `.state/transparent-transaction/`: byte-exact transparent-mode rollback journal and phase;
- `.state/sing-box/subscription-transaction/`: subscription activation/rollback journal;
- `.state/sing-box/subscription-update.lock/`: updater ownership and crash detection;
- `.state/watchdog/*.pid` / refresh owner records: exact process ownership;
- `.state/hotspot/tether-offload.previous`: Android setting value that MagicNet must restore;
- `.state/hotspot/tun-rules.list`: exact policy rules MagicNet must delete;
- `.state/dns-leak-guard.ifaces`: exact interfaces whose owned rules require cleanup;
- `.state/app-policy/*uids.list`: resolved UID sets needed to remove stale managed UID boundaries.

A canonical record summarizes these without replacing the detailed rollback payload.

### Cache, checkpoint, and raw evidence

These are not state-machine contracts and must not gain public semantics merely because they live below `.state`:

- sing-box `last-good-*` validated recovery checkpoints;
- subscription `subscription-work`, generation staging, and `subscription-cache`;
- sing-box runtime fingerprint;
- raw eBPF probe report and shared-interface evidence;
- transparent mode-specific managed inbound snapshots;
- sing-box Tailscale engine state directory;
- bounded `/proc` query temporary files;
- installation/config staging files.

They may be deleted/rebuilt according to their owning subsystem's rules. Canonical state should expose only the bounded fact a caller actually needs.

## Legacy files are compatibility inputs

During migration, existing journals, PID/owner files, caches and probe reports remain recovery/ownership inputs. The reconciler projects relevant facts into `.state/machines/*.state`. They are not a license for new consumers to keep adding direct parsers.

New consumers must use the canonical state plane or the versioned `cli --json` machine interface. Existing writers can be migrated one domain at a time; once no recovery path needs a legacy file, it can be removed.

## State versus artifacts

Not every file below `.state` is a state machine. Caches, validated checkpoints, generated subscription work, eBPF probe reports, and transaction backups are artifacts. They may be needed to reconstruct or verify state, but their existence is not itself a public state unless the canonical domain file says so.

Transaction journals are the exception: they are durable recovery evidence. Their detailed backup payload may remain a directory, while the corresponding canonical domain file exposes only bounded facts such as `transaction_active=1` and `phase=old-stopped`.

## External truth

A file must not turn stale observation into truth. Process, cgroup, TC, interface, and kernel state originate outside MagicNet. Reconciliation verifies available external evidence and publishes a bounded result such as `running`, `stale`, `unknown`, or `pending`.

Unknown is a real state. A failed `/proc` read, ambiguous owner, or unavailable kernel evidence must not be rewritten as success.

## Privacy

Canonical state files are safe machine state, not debug dumps. They must never persist:

- subscription URLs;
- tokens, secrets, passwords, auth keys;
- SSID/BSSID values;
- selector/node names;
- raw UID lists;
- raw failure reasons;
- arbitrary command output;
- complete user configuration.

Use booleans, counts, normalized modes, and bounded state tokens instead. For example Wi-Fi stores `has_ssid=1`, not the SSID itself; selector state stores a selection count, not group/member names.

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

1. Do not add new ad-hoc files under `.state` for a new public lifecycle state.
2. Put persistent user intent in `.config`; put normalized observed/recoverable state in the appropriate canonical `.state/machines/*.state` file.
3. Keep canonical values bounded and privacy-safe.
4. Publish each domain file atomically; for related multi-file changes use the recoverable module transaction instead of truncating files in place.
5. Persist a transaction phase before performing an irreversible/externally visible next step.
6. On recovery, reconcile journal + external truth and publish one canonical settled state.
7. Long-running producers must republish after internal state changes.
8. Add regression tests for interrupted transitions, stale owners, unknown process state, migration, and redaction.
9. Once all producers/consumers for a legacy state path are migrated, delete that compatibility path rather than maintaining two permanent truths.
