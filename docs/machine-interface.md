# Machine interface

MagicNet keeps two CLI surfaces on purpose:

- Human CLI: concise text intended for Termux, recovery and manual debugging.
- Machine CLI: versioned JSON intended for WebUI, MCP, Android managers and automation.

The machine interface is read-only today. Use either `cli --json <command...>` or `cli <command...> --json`. Clients should query `cli --json capabilities` instead of assuming that every MagicNet version supports the same commands.

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

The bundled WebUI and CLI are released together. DNS and network policy reads
therefore use the shared schema-1 decoder without human-text fallback. They
validate the payload before changing UI state; malformed, unsupported or
conflicting responses remain visible failures. Native bridge diagnostics may
surround a single response, but multiple JSON objects or a failed execution
cannot be promoted to success. Refreshes retain foreground ownership checks so
late results cannot overwrite a newer operation.

The remaining subscription, Wi-Fi and service status migration is tracked in
#273. Do not discard private editor fields or lifecycle reconciliation evidence
just to remove the old reads: machine status intentionally does not expose the
same data as manual diagnostics.

## Mutation safety

`--json` currently does not make existing mutation commands machine APIs. A request such as `cli --json service start` must fail with a structured `machine.unsupported_command` error and must never fall through to the normal dispatcher.

A future machine mutation API needs its own contract for idempotency, concurrency, validation, rollback and stable error codes before it is added to capabilities.
