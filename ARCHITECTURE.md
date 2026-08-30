# MagicNet architecture

MagicNet separates its device runtime into a data plane, control plane, and
state plane. The detailed runtime design and its invariants live in
[`docs/next-gen-architecture.md`](docs/next-gen-architecture.md).

## Repository map

- `crates/magicnet-cli`: privileged control-plane entrypoint used by the WebUI,
  module scripts, and MCP server. `main.rs` only starts the app and dispatches
  arguments; `app.rs` resolves trusted runtime configuration, `commands.rs`
  owns top-level registration, and `process.rs` owns process lifecycle safety.
  Feature modules own their subcommands.
- `crates/magicnet-mcp-server`: optional authenticated HTTP/MCP adapter. It
  delegates device operations to the CLI instead of creating another control
  path.
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

The CLI is the shared control boundary. New integrations should reuse it and
must not execute a parallel set of privileged shell operations.

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
- Module-managed files and processes are identified by exact owned paths.
- Packaged `bin/jq` is mandatory for JSON policy mutation; privileged runtime
  code fails closed instead of rewriting JSON with AWK or regular expressions.
- Subscription generation passes complete JSON arrays between stages and merges
  them structurally; legacy cached fragments are accepted only at the migration boundary.
- MCP is disabled by default and requires an independent secret.
- Runtime state belongs under `.config`, `.state`, and `.log`; callers must not
  redirect privileged Android execution through untrusted environment paths.

When a change crosses these boundaries, document the new ownership and add a
regression test covering failure and rollback behavior.
