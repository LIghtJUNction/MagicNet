# Contributing to MagicNet

Thanks for improving MagicNet. Keep changes focused and preserve the runtime
invariants described in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Development setup

Install Rust with `rustfmt` and `clippy`, Node.js/npm or Bun, ShellCheck, `jq`,
Python 3, and [Kam](https://github.com/MemDeco-WG/Kam). Detailed build and local
simulation instructions are in [`docs/build.md`](docs/build.md) and
[`docs/local-simulation.md`](docs/local-simulation.md).

## Before opening a pull request

Run the focused checks while iterating:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
scripts/kam-test.sh quick
```

Run the complete repository regression before a substantial change or release:

```bash
scripts/pre-commit.sh
```

If a device-facing path changes, also run the nearest test under `scripts/` and
the fake-Magisk smoke test. Include the exact commands and results in the pull
request description.

## Change boundaries

- Register new top-level CLI commands in
  `crates/magicnet-cli/src/commands.rs`; keep feature behavior in its own
  module.
- Reuse the CLI for WebUI and MCP operations. Do not add a second privileged
  execution path.
- Keep the transparent implementation on sing-box `magicnet0` TUN. Do not
  restore removed TProxy, eBPF, or automatic transport promotion paths.
- Treat the module directory, subscription inputs, secrets, and backup data as
  trust boundaries. Validate before writing or executing.
- Add a regression test for every fixed bug and for failure/rollback paths in
  stateful operations.

Never commit `.env`, subscription URLs, authentication secrets, passwords, or
device logs containing private configuration.
