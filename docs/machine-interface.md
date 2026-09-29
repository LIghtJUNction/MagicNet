# Machine interface

MagicNet keeps two CLI surfaces on purpose:

- Human CLI: concise text intended for Termux, recovery and manual debugging.
- Machine CLI: versioned JSON intended for WebUI, MCP, Android managers and automation.

Status commands are read-only. The separately designed `override` family also supports bounded, versioned mutations (see [configuration overrides](config-overrides.md)). Use either `cli --json <command...>` or `cli <command...> --json`. Clients should query `cli --json capabilities` instead of assuming that every MagicNet version supports the same commands.

## Envelope

Successful responses use one JSON object on stdout:

```json
{
  "schema": 1,
  "ok": true,
  "command": "service.status",
  "data": {}
}
```

Unsupported or invalid machine requests also keep stdout parseable:

```json
{
  "schema": 1,
  "ok": false,
  "command": "machine.error",
  "error": {
    "code": "machine.unsupported_command",
    "message": "unsupported machine command"
  }
}
```

The process still exits non-zero for an error. Consumers should therefore preserve both the JSON body and exit code. Machine-mode logs and diagnostics belong on stderr; stdout must not contain banners or progress lines around the JSON object.

## Capabilities

```sh
/data/adb/modules/MagicNet/cli --json capabilities
```

The response advertises the schema, supported commands and protocol features. This is the compatibility boundary for separately updated components.

Current schema-1 status commands:

```text
service.status
core.status
supervisor.status
transparent.status
dns.status
network.status
network-access.status
network-access.inspect
sub.status
wifi.status
machine.capabilities
```

Examples:

```sh
/data/adb/modules/MagicNet/cli --json service status
/data/adb/modules/MagicNet/cli --json transparent status
/data/adb/modules/MagicNet/cli --json dns status
/data/adb/modules/MagicNet/cli --json network status
/data/adb/modules/MagicNet/cli --json sub status
/data/adb/modules/MagicNet/cli --json wifi status
```

## Readiness semantics

A running process is not proof that the proxy is ready.

`service.status` therefore reports three layers independently:

- `core.sing_box.process_state`: whether the owned sing-box process can be proven running, stopped or unknown.
- `api.ready`: whether the local sing-box control API is responding.
- `readiness.dataplane`: whether the selected transparent dataplane is actually present.

`readiness.overall` is true only when both the API and dataplane are ready. Unknown evidence stays `null`; it is never promoted to ready.

The service lifecycle is derived from those signals:

```text
stopped
unknown
reconfiguring
ready
not_ready
running_unknown
```

For TUN, dataplane readiness requires the configured TUN interface to exist in sysfs. For eBPF, MagicNet refreshes the active-program report and reuses the kernel attachment inspector to verify required cgroup/TC attachments. `transparent.status` exposes the normalized result without returning interface names or other unnecessary network identifiers.

## Privacy boundary

Machine status is intentionally more restrictive than manual diagnostics. Stable status responses must not include subscription URLs or credentials, raw failure reasons that may echo provider data, SSID/BSSID values, tokens, passwords or other unnecessary identifiers.

Where the UI only needs to know whether data exists, return a boolean. Where it needs magnitude, return a count. Return raw values only when the value is itself required to perform the user-visible operation and is safe for a stable control-plane contract.

Examples already enforced in schema 1:

- Subscription status reports source type, configured count, update/transaction state, lifecycle counters and whether a reason exists; it does not expose the URL or reason text.
- Wi-Fi status reports connection/match state and list counts; it does not expose SSID or BSSID text.
- Network status separates `configured` policy from the values materialized in the effective sing-box configuration.
- Service PID inspection distinguishes `running`, `stopped` and `unknown`; an inspection failure is not treated as a running service.
- Transparent status reports attachment states and interface counts, not shared-interface names.

## Compatibility

Human output remains a compatibility surface for users and old components. New code should not add new regular-expression parsing of human status output when an equivalent JSON command exists.

For components that can be updated independently, the migration pattern is:

1. Probe `--json capabilities`.
2. Use the advertised machine command.
3. Validate `schema`, `ok` and `command` before consuming `data`.
4. Fall back to the old human command only when supporting an older installed MagicNet version is a product requirement.
5. Keep the fallback covered by a regression test, then remove it when the minimum supported module version includes the machine command.

The bundled WebUI and CLI are released together. DNS, network policy and service
status reads therefore use the shared schema-1 decoder without human-text
fallback. They validate the payload before changing UI state; malformed,
unsupported or conflicting responses remain visible failures. Native bridge
diagnostics may surround a single response, but multiple JSON objects or a
failed execution cannot be promoted to success. Refreshes retain foreground
ownership checks so late results cannot overwrite a newer operation.

The overview reads service and transparent state from one `service.status`
response instead of combining separately timed commands. A failed or malformed
refresh clears previous live state to unknown. Process existence remains
separate from readiness, and interface counts respect the machine privacy
boundary. This command-level snapshot is not an atomic observation of every
underlying operating-system probe.

The bundled subscription and Wi-Fi pages now use explicit schema-1 inspectors,
not the human `sub list` / `sub status` / `wifi status` parsers. The existing
`sub.status` and `wifi.status` commands remain redacted for diagnostics and MCP
status resources. Their privacy boundary has not been relaxed.

### Explicit private inspectors

`cli --json sub inspect` and `cli --json wifi inspect` are read-only local
configuration inspections, advertised separately in `capabilities.private_commands`.
They are **not** safe diagnostic payloads. `sub.inspect` includes the configured
subscription URLs, user agent, filters and provider quota metadata. `wifi.inspect`
includes configured SSID/BSSID lists and current network identifiers needed by
the Wi-Fi editor. An authenticated generic MCP CLI call may explicitly request
these just as it could request the existing private human configuration commands;
no automatic MCP status resource calls them.

The WebUI always reads inspectors quietly without command capture or reactive
stdout, validates the complete envelope, and only then updates editor/state
models. Errors show a sanitized machine error code, never raw inspector output.
Generic issue reports continue to request redacted `sub.status`.

`sub.inspect` shares the exact lifecycle projection used by `sub.status`; it
adds `configuration` and `source_usage` only for this explicit request. Provider
usage is selected by SHA-256 of the configured URL, not list position. Pending
transactions suppress uncommitted usage; detected generation or URL changes
reject the snapshot. This is change detection, not an OS-wide atomic snapshot.
The cache includes separate source/provenance counts; refresh counters summarize
at most the last 200 lines of the bounded refresh-log tail, not lifetime totals.

Update and schedule ownership are independently verified with PID start time
(and the exact script/owner marker for the scheduler). An empty newly-created
update lock is pending during its five-second initialization grace, not running.
Stale locks and stored `result=running` without a live owner report interrupted
or recovery-pending. Failed process inspection reports unknown. No read deletes
locks or recovers transactions.

`wifi.inspect` uses the same bounded live detection and decision primitives as
the policy watcher. Failure to detect a network is an error, not a confirmed
disconnect. Detected policy/list edits during probing reject the observation.
On failed refresh the WebUI retains editable configuration, clears live identity
and quota displays, and reports unknown rather than keeping an old green state.

## Mutation safety

`--json` currently does not make existing mutation commands machine APIs. A request such as `cli --json service start` must fail with a structured `machine.unsupported_command` error and must never fall through to the normal dispatcher.

A future machine mutation API needs its own contract for idempotency, concurrency, validation, rollback and stable error codes before it is added to capabilities.


## Configuration override commands

Capabilities now set `read_only=false` and enumerate `mutation_commands`.
This is not permission to run arbitrary existing CLI writes with `--json`:
only the override family has machine write semantics. Unsupported JSON requests
still cannot fall through to the human dispatcher.

```sh
cli --json override status
cli --json override inspect
cli --json override preview-file "$PRIVATE_PAYLOAD_PATH"
cli --json override set-file "$PRIVATE_PAYLOAD_PATH"
cli --json override reset-file "$PRIVATE_PAYLOAD_PATH"
cli --json override apply-file "$PRIVATE_PAYLOAD_PATH"
```

The payload path must be a private regular file created by `cli webui payload`
under `.tmp/webui-payload/`. Preview takes `{ "patch": {} }`; set additionally
requires `expected_revision`; reset and apply take only `expected_revision`.
The manual `cli --json override apply` shorthand explicitly selects the latest
saved draft. MCP and WebUI always use the revision-checked form. Payload
size is bounded to 4 MiB. MCP takes the same JSON properties directly over its
authenticated endpoint and calls the same implementation.

`override.inspect` is private and contains the patch. Other override responses
contain only revision numbers, counts and booleans. `running_revision=null`
means the override interface has no independent process-generation attestation;
clients must check service readiness and must not equate saved with running.
`activation_blocked` identifies a failed revision held after rollback. Background
watchers do not retry that revision; an explicit apply releases the hold.

Mutations publish `.state/machines/overrides.state` after completion or failure.
Readers remain side-effect free. Unlike the old observation-only contract,
`--json` itself is no longer a blanket reason to skip reconciliation: the exact
registered override write commands are recognized.

## Application network-policy observations

`cli --json network-access status` reports capability-detected provider counts.
`cli --json network-access inspect` additionally exposes installed package names
for configured restrictions and their shared package identity. Treat inspection
as private device metadata; do not include it in public support bundles.

The Android provider covers explicitly rejected metered-background policies.
The Oplus provider enumerates the platform networking-control policy list.
An absent API is `unsupported`; a failed query, missing bridge or malformed
response is `unknown`, with a null provider count. `known_restriction_count`
counts only successfully observed entries, not a complete-device verdict.
`configured` is distinct from `effective=not_probed`: these calls do not prove
application DNS success, actual packet filtering, or website usability.

Both commands are read-only. `repair_supported=false`; machine mutations are
rejected before the human dispatcher. Automatic repair, rollback and prevention
of policy reapplication are tracked in [issue #329](https://github.com/LIghtJUNction/MagicNet/issues/329).

## Tailscale lifecycle observation

`cli --json tailscale status` reports configured `enabled`, `resumable`,
`logout_pending`, nullable `local_identity`, an optimistic `revision`, and observed
`core`. It is read-only and does not imply online authorization. See
[tailscale.md](tailscale.md#disable-resume-and-sign-out) for the separate human CLI
mutations and their concurrency, rollback, and local-logout contract.
