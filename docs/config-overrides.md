# Persistent JSON configuration overrides

## Control contract

The override editor stores user intent separately from generated subscriptions.
The payload is a JSON object using JSON Merge Patch semantics: object keys merge,
arrays replace, and `null` removes a key. An empty object resets all overrides.
It is not a full replacement configuration. A complete configuration object is
accepted as a patch, subject to the managed-field checks below.

Managed transparent inbounds and the local management API remain owned by
MagicNet. A patch must not change their effective values. Switching `tun|ebpf`
continues to use the explicit, rollback-capable transparent-mode operation.
No shell fragments, JavaScript, or remote code are evaluated.

## Persistence and recovery

- `.config/magicnet/config-override.json` contains the saved draft schema, revision and patch.
- `.config/magicnet/config-override-active.json` contains the explicitly selected
  intent. The watcher and startup materialize only this version, so saving a
  draft does not activate it. Both files store user intent, not observations.
- A private materialization checkpoint records the pre-override base and last
  generated result. It is recovery evidence, never a public state interface.
- `.state/machines/overrides.state` is the sole canonical status projection.
  It contains validity, configured revision, materialized revision and pending
  status only; no JSON values, paths, domains, credentials or error text.
- Each materialization removes the previous patch using its checkpoint before
  applying the current patch. Unrelated edits and newly imported subscription
  values survive. A field changed by another writer becomes the new base for that field; reset
  preserves that newer value instead of restoring stale subscription data.
- Config, intent and checkpoint changes use the existing staged multi-file
  transaction. Files publish by atomic replacement; cross-file readers use the
  machine interface rather than assume multiple renames are jointly atomic.
- Materialization occurs after normal runtime helpers and before sing-box starts.
  Reset removes only override effects; subscription sources and other settings
  remain intact.

## Machine writes

This feature explicitly extends the previously read-only JSON dispatcher.
The first mutation family is `override`; unrelated JSON writes remain rejected.

- `override.status`: privacy-safe configured/materialized/running status.
- `override.inspect`: explicit private patch read, including revision.
- `override.preview`: validate a patch and return a redacted change summary.
- `override.set`: validate and persist a complete patch with expected revision.
- `override.reset`: persist an empty patch with expected revision.
- `override.apply`: select the expected saved revision and apply runtime config.

All calls use the schema-1 envelope and a single JSON value on stdout. Diagnostics
stay on stderr. Mutation inputs arrive from a bounded private payload file (MCP accepts the
same object in its authenticated tool arguments); secrets must not appear in command arguments or command previews.

Set/reset use optimistic concurrency: the caller supplies the revision returned
by inspect. Repeating an identical desired state succeeds without incrementing
its revision. A different stale write returns `override.conflict`. The operation
lock is bounded and returns `override.busy`; it never waits indefinitely.
Malformed input, protected fields, validation failure, persistence failure and
apply failure have distinct normalized error codes. Failed validation writes
nothing. An activation failure rolls back the configuration and checkpoint when their
revision and contents still prove ownership. Conflicting external changes stop
automatic rollback with `override.rollback_conflict` rather than overwrite them.
The saved intent remains pending; a failed-revision hold prevents an automatic
retry loop. It never reports a failed new configuration as running.

Saving and activating are distinct results. Configured and materialized settings
are not proof of a running process: running status requires the existing runtime
fingerprint and service readiness evidence. MCP and WebUI consume these same
commands and expose pending activation explicitly.


### Example

```json
{
  "log": { "level": "info" },
  "dns": { "cache_capacity": 8192 }
}
```

Read the revision, preview the patch, save with `expected_revision`, then apply.
The WebUI combines the last two actions in **Save and apply**; **Reset overrides**
saves an empty patch and applies it. Saving alone keeps a visible pending state.

Managed inbounds, the hotspot selector and discovered source rules, Clash API and cache-file settings cannot be changed by this
editor. Use their dedicated controls. Arrays are replaced in full, including
outbound arrays: a patch that pins an entire outbound list intentionally takes
precedence over newly imported nodes until it is changed or reset.

The backup export includes override intent. Private materialization checkpoints
are local recovery evidence and are not exported. Application preserves the
existing stopped/running intent; it does not start a deliberately stopped core.
