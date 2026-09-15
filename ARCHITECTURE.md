# MagicNet architecture

MagicNet separates its device runtime into a data plane, control plane, and
state plane. The detailed runtime design and its invariants live in
[`docs/next-gen-architecture.md`](docs/next-gen-architecture.md). The canonical
file-backed state contract lives in [`docs/state-plane.md`](docs/state-plane.md).

## Repository map

- `crates/magicnet-cli`: the single privileged Rust control-plane binary used by
  the WebUI, module scripts, and MCP. `main.rs` only starts the app and dispatches
  arguments; `app.rs` resolves trusted runtime configuration, `commands.rs`
  owns top-level registration, `process.rs` owns process lifecycle safety, and
  `mcp_server` owns the authenticated HTTP/MCP adapter used by `cli mcp serve`.
  Feature modules own their subcommands. `state.rs` reconciles legacy runtime
  evidence and external process/kernel facts into the canonical state plane.
- `src/MagicNet/lib/magicnet`: device runtime shell modules. These implement
  lifecycle, subscription, routing, DNS, and supervisor behavior.
- `sing-box`: pinned `LIghtJUNction/sing-box` source submodule. Build hooks
  compile this fork into the Android arm64 data-plane binary.
- `webui`: Vue user interface. It communicates through the CLI API contract.
- `hooks`: reproducible build and release hooks.
- `scripts`: policy, lifecycle, packaging, and regression tests.

## Dependency direction

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
 sing-box transparent dataplane
 (tun/magicnet0 or ebpf/cgroup+TC)
```

The CLI is the shared control boundary. MCP is a server mode of that same
binary, not a second privileged executable. New integrations should reuse the
CLI contract and must not execute a parallel set of privileged shell operations.

## State plane

Device lifecycle state is projected into one canonical file per domain below
`.state/machines/`. Normal control/human CLI invocations reconcile a complete
snapshot before and after dispatch. Each domain file is atomically replaced;
related changed files use the existing recoverable multi-file transaction so a
later replacement failure rolls earlier replacements back. Lock-free readers
that require a cross-domain point-in-time snapshot should use the versioned
machine interface instead of racing several files. `--json` remains read-only
and never rewrites the state plane.

Legacy journals, PID/owner files, caches and probe reports remain recovery or
observation inputs during migration. They are not new public state contracts.
New code must consume the canonical files or the versioned machine interface,
and old state paths should be deleted once their recovery users are migrated.

Presentation-only WebUI state that may safely disappear on reload stays in
memory; any operation that outlives WebUI must have device-side file evidence.

## Stable invariants

- The transparent data plane is an explicit sing-box `tun|ebpf` choice. `tun`
  remains the default and owns `magicnet0`; `ebpf` owns local cgroup programs and,
  only for confirmed downstream interfaces, shared TC programs. Release builds
  include `with_ebpf`; `auto`, TProxy, Redirect, and netd `ALLOW_MULTI` remain excluded.
- Mode changes are serialized and transactional: validate/probe the candidate,
  stop the previous owned process, start and verify the target, then commit; any
  failure restores the byte-exact previous mode/config and records rollback state.
- Configuration candidates are validated before activation and updates are
  transactional.
- Canonical runtime state is file-backed under `.state/machines`, privacy-safe,
  bounded, atomically replaced per domain, and explicit about
  configured/effective/phase distinctions. Unknown external evidence stays
  `unknown` rather than being guessed into a successful state.
- Module-managed files and processes are identified by exact owned paths.
- Packaged `bin/jq` is mandatory for JSON policy mutation; privileged runtime
  code fails closed instead of rewriting JSON with AWK or regular expressions.
- Subscription generation passes complete JSON arrays between stages and merges
  them structurally; legacy cached fragments are accepted only at the migration boundary.
- MCP is disabled by default and requires an independent secret. The server
  process is `bin/magicnet-cli mcp serve`; endpoint and secret are read from the
  validated private MCP configuration instead of being passed on argv.
- Runtime state belongs under `.config`, `.state`, and `.log`; callers must not
  redirect privileged Android execution through untrusted environment paths.

When a change crosses these boundaries, document the new ownership and add a
regression test covering failure and rollback behavior.
