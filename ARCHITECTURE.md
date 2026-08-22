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
       sing-box magicnet0 TUN
```

The CLI is the shared control boundary. New integrations should reuse it and
must not execute a parallel set of privileged shell operations.

## Stable invariants

- The transparent data plane is sing-box `magicnet0` TUN only.
- Configuration candidates are validated before activation and updates are
  transactional.
- Module-managed files and processes are identified by exact owned paths.
- Packaged `bin/jq` is mandatory for JSON policy mutation; privileged runtime
  code fails closed instead of rewriting JSON with AWK or regular expressions.
- MCP is disabled by default and requires an independent secret.
- Runtime state belongs under `.config`, `.state`, and `.log`; callers must not
  redirect privileged Android execution through untrusted environment paths.

When a change crosses these boundaries, document the new ownership and add a
regression test covering failure and rollback behavior.
