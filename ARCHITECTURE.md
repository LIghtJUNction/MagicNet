# MagicNet architecture

MagicNet has one runtime architecture: a sing-box data plane, a shared CLI
control plane, and file-backed state. This document owns the overview; detailed
state and machine contracts live in [state-plane.md](docs/state-plane.md) and
[machine-interface.md](docs/machine-interface.md).

## Repository map

- `crates/magicnet-cli`: the privileged Rust binary used by WebUI, module scripts,
  and MCP. `main.rs` starts the app; `app.rs` resolves trusted configuration;
  `commands.rs` registers commands; `process.rs` owns process lifecycle safety;
  `mcp_server` implements `cli mcp serve`; `state.rs` reconciles runtime evidence.
- `src/MagicNet/lib/magicnet`: device lifecycle, subscription, routing, DNS, and
  supervisor shell modules.
- `sing-box`: the pinned `LIghtJUNction/sing-box` source submodule, built into the
  Android arm64 data-plane binary with the required `with_ebpf` feature.
- `webui`: Vue interface consuming the CLI contract.
- `hooks`: build and release hooks. `scripts`: policy, lifecycle, packaging, and
  regression checks.

## Data plane

```text
Android applications / confirmed tethered interfaces
                         |
                         v
          sing-box inbound (explicit choice)
       tun: magicnet0 / ebpf: cgroup + shared TC
                         |
                         v
              DNS and routing policy
                         |
                         v
       selector / urltest / direct / block
                         |
                         v
    physical network / configured userspace endpoint
```

The default `tun` mode routes traffic through the root-managed `magicnet0`
interface. MagicNet does not call `VpnService.establish()` or claim the Android
VPN slot. Bypass UIDs bypass both the TUN and MagicNet DNS capture; they return to
the native network or an external VPN path. This does not guarantee that two
independent VPN configurations can coexist without port or subnet conflicts.

The `ebpf` mode uses a `type: "ebpf"` inbound. Local traffic uses cgroup programs;
shared TC programs attach only to confirmed downstream interfaces. Its readiness
comes from capability and attachment evidence, not the presence of `magicnet0`.

Android/OEM tethering still owns hotspot DHCP and NAT. For TUN hotspot proxying,
MagicNet discovers the downstream interfaces, installs owned policy routing, and
disables tether hardware offload so traffic reaches the core. The watcher updates
interface-dependent state. Leaving proxy mode, stopping, or uninstalling must
remove owned rules and restore saved settings. In eBPF mode, shared TC attachment
is the capture boundary. MagicNet does not create the hotspot itself.

## Control plane

```text
WebUI / MCP / module entry scripts
               |
               v
        magicnet-cli contract
               |
               v
   module-owned shell/runtime state
               |
               v
      sing-box data plane
```

The CLI is the shared privileged boundary. MCP is a server mode of that binary,
not another privileged implementation. Integrations reuse its versioned contract
rather than parsing human output or building parallel shell control paths.
MCP is disabled by default and requires an independent secret; validated private
configuration supplies the endpoint and secret, not process arguments.

Subscription sources activate as either URLs or local input, not both. Writers
build a candidate, validate it, and activate it under the existing transaction.
Interrupted updates retain their journal for recovery. Selector changes use the
core API and persist user choices for replay after updates. App policies resolve
UIDs for the relevant Android user rather than using fixed device UIDs.

## State and storage

- `.config/` owns persistent user intent, including subscriptions, network/app/
  Wi-Fi policy, MCP settings, and `magicnet/selector-selections.json`.
- `.state/machines/*.state` owns bounded, privacy-safe `schema=1` observations,
  with one public canonical file per domain. Other `.state/` journals, PID/owner
  files, caches, and probe reports are recovery or observation inputs, not a
  second public state interface.
- `.log/` owns rotated logs. `bin/` holds release executables; module-root `cli`
  remains the entry to `bin/magicnet-cli`.

Normal control commands reconcile snapshots around dispatch. Read-only machine
status commands do not rewrite state. Explicit machine writes, such as the
[configuration override API](docs/config-overrides.md), follow their documented
validation, concurrency, and rollback contracts; `--json` alone never authorizes
an unsupported write.

Each canonical file is atomically replaced. Related changes use the recoverable
multi-file transaction: if a later replacement fails, earlier replacements roll
back. This is not simultaneous atomic visibility to lock-free readers. Use the
machine interface for a cross-domain snapshot. Unknown evidence stays `unknown`.
Move consumers and recovery dependencies before deleting an old state path.

Presentation-only WebUI state can remain in memory. An operation that outlives
WebUI must have device-side evidence.

## Failure boundaries

Only `tun|ebpf` are supported. Do not add `auto`, TProxy, Redirect, or netd
`ALLOW_MULTI`. Mode changes are serialized: validate the candidate, stop the
owned process, start and verify the target, then commit. Failure restores the
previous mode and configuration byte-for-byte and records rollback state.

Configuration activation requires structural validation and `sing-box check`.
Packaged `bin/jq` is mandatory for JSON mutation; do not replace it with AWK or
regular expressions. Subscription stages exchange complete JSON arrays and merge
them structurally. Legacy fragments belong only at the migration boundary.
Empty or ineligible proxy groups fail closed rather than select an unknown exit.

Processes and resources must be identified by exact ownership. Preserve graceful
shutdown and recovery evidence; never flush unrelated system rules. Runtime paths
must remain trusted. One-use Tailscale keys have an explicit erasure lifecycle.

Use `cli transparent status` and `cli health` for diagnosis. Do not invent
`cli ebpf status`, treat process survival as network success, or apply TUN-only
checks to eBPF. Changes to these boundaries need failure and rollback regressions.
