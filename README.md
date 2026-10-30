<div align="center">
  <img src="icon.png" width="112" alt="MagicNet icon">
  <h1>MagicNet</h1>
  <p><strong>A transparent networking control plane for rooted Android.</strong></p>
  <p>Subscriptions · app and domain routing · DNS · TUN/eBPF · sing-box-compatible runtime · web console</p>

  [![Android release](https://img.shields.io/badge/Android-v1.8.1%20%2F%2010609-111111?style=flat-square&logo=android)](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.1)
  [![Recipe](https://img.shields.io/badge/recipe-0.3.3-111111?style=flat-square)](recipes/magicnet/BUILD_PROMPT.md)
  [![License](https://img.shields.io/github/license/LIghtJUNction/MagicNet?style=flat-square)](LICENSE)
  [![Last commit](https://img.shields.io/github/last-commit/LIghtJUNction/MagicNet?style=flat-square)](https://github.com/LIghtJUNction/MagicNet/commits/main)

  [English](README.en.md) · [Русский](README.ru.md) · [Download](https://github.com/LIghtJUNction/MagicNet/releases) · [Rebuild](#rebuild-from-the-recipe) · [Evidence](recipes/magicnet/VERIFICATION.md)
</div>

## Pick the path you need

| Goal | Entry point |
| --- | --- |
| Install and use MagicNet | [Releases](https://github.com/LIghtJUNction/MagicNet/releases) and [v1.8.1 installation notes](docs/releases/v1.8.1.md) |
| Rebuild the product with a code agent | [`recipes/magicnet/`](recipes/magicnet/) and the commands below |
| Work on the maintained implementation | [`generated/magicnet-android/`](generated/magicnet-android/) or the [source repository](https://github.com/LIghtJUNction/magicnet-android) |
| Audit claims and limitations | [Verification](recipes/magicnet/VERIFICATION.md), [performance](recipes/magicnet/PERFORMANCE.md) and [provenance](recipes/magicnet/PROVENANCE.md) |

MagicNet separates the **product contract** from the **generated implementation**. The recipe says what must exist and how it is accepted; the source submodule is one concrete implementation; Releases contain the installable Android artifacts.

## What it controls

MagicNet is designed for rooted Android devices that need one place to manage network behavior:

- multiple subscription sources, cached state and per-source diagnostics;
- app, domain, Wi-Fi and hotspot routing policies;
- custom groups, selectors, exits and DNS behavior;
- Tailscale integration and transactional network recovery;
- TUN/eBPF boundaries with sing-box-compatible behavior;
- a multilingual web console for configuration and status;
- signed, verifiable component delivery and root-module packaging.

Changes are previewed before they are applied. Private subscriptions, credentials, device identities and raw local logs are not part of the public recipe or release source.

## Current state

| Layer | Current state |
| --- | --- |
| Published Android package | [`v1.8.1 / 10609`](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.1) |
| Recipe | `0.3.3` |
| Fixed implementation commit | `0952cb01b001e41e1074c2e5f4a731a4ad42b222` |
| Unreleased implementation work | process handoff, PID validation, log-memory fixes, frontend refinement, per-source conversion guards and bounded subscription observation |

The fixed source commit contains work newer than the published Android package. A successful recipe check proves that the rebuild materials are complete; it does **not** prove that an APK/module was built, installed on a device or validated against real traffic. Those claims are recorded separately in [`VERIFICATION.md`](recipes/magicnet/VERIFICATION.md).

Recipe `0.3.3` adds the [core lifecycle contract](recipes/magicnet-packet-engine/CORE_LIFECYCLE.md): fixed upstream synchronization, handshake failure cleanup, and complete registration cleanup when flow attachment overlaps closure. It retains the subscription and recovery requirements from recipe `0.3.2`; fixed source identities and measured results are tracked in the verification record.

## Install the published software

Use the [Releases page](https://github.com/LIghtJUNction/MagicNet/releases) for the lightweight installer, offline package, components and checksums. The release notes document the exact scope that was built and tested.

To obtain the repository together with its fixed implementation:

```bash
git clone --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init --recursive generated/magicnet-android
```

A local implementation build currently uses the source repository's pinned Rust, Go, Node, Java and Android toolchain contracts:

```bash
cd generated/magicnet-android
kam build -j 2
```

See the [implementation build guide](generated/magicnet-android/docs/build.md) before treating a local archive as a release artifact.

## Rebuild from the recipe

Requirements: Git, the Recipkg CLI, and a code agent capable of implementing and validating rooted Android software.

```bash
recipkg check recipes/magicnet

set -eu
recipe_tmp="$(mktemp -d)"
trap 'rm -rf "$recipe_tmp"' EXIT

recipkg pack recipes/magicnet \
  -o "$recipe_tmp/magicnet-0.3.3.recipe.tar.gz"
recipkg check "$recipe_tmp/magicnet-0.3.3.recipe.tar.gz"
recipkg build "$recipe_tmp/magicnet-0.3.3.recipe.tar.gz" --lang zh-CN
```

`recipkg build` produces a complete implementation prompt. It does not call a model or build the software itself. Give the full generated prompt to the implementation agent, then require it to execute every item in [`ACCEPTANCE.md`](recipes/magicnet/ACCEPTANCE.md) and record real results in [`VERIFICATION.md`](recipes/magicnet/VERIFICATION.md).

Do not hand `.env` files, subscriptions, credentials, device state or raw private logs to the agent or include them in a recipe archive.

## Contract map

```text
recipes/magicnet/                   product requirements and acceptance
recipes/magicnet-control-plane/     CLI, JSON schema, MCP and file-state contract
recipes/magicnet-network-runtime/   subscriptions, processes and recovery transactions
recipes/magicnet-packet-engine/     TUN/eBPF and sing-box compatibility
recipes/magicnet-routing-policy/    selectors, DNS and routing order
recipes/magicnet-web-console/       web workflows, i18n and visual requirements
recipes/magicnet-module-delivery/   root module, components and trusted updates
recipes/software-quality/           shared design, code and performance bar
generated/magicnet-android/         fixed implementation submodule
```

The repository keeps the implementation as a fixed Git submodule so recipe history and generated source history remain independently auditable.

## Development and release

Product behavior changes begin in the relevant recipe, interface and acceptance documents. The implementation is then changed and verified in its own repository. Only after the source commit is pushed should this repository update the submodule pointer.

The release workflow is [Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml):

```bash
# Build artifacts without publishing a release
gh workflow run release.yml \
  --repo LIghtJUNction/MagicNet \
  --ref main \
  -f mode=build
```

`mode=publish` is the explicit publication path. Build, quality and emulator gates use one implementation SHA; failed gates do not publish. Emulator success still does not substitute for arm64 hardware and real-network validation.

Local lightweight checks:

```bash
python3 scripts/check-recipes.py
python3 scripts/test-release.py
```

## Evidence and limits

- [`SOURCE_AUDIT.md`](recipes/magicnet/SOURCE_AUDIT.md) records which fixed source was inspected.
- [`PERFORMANCE.md`](recipes/magicnet/PERFORMANCE.md) distinguishes measured baselines from targets and unknowns.
- [`PROVENANCE.md`](recipes/magicnet/PROVENANCE.md) labels documentation, source evidence, measurements, inference and unknowns.
- [`VERIFICATION.md`](recipes/magicnet/VERIFICATION.md) separates recipe checks, source tests, package checks and device validation.

<details>
<summary>Historical source anchors</summary>

The initial observed source was fixed at `96993ea5c851b8d51cc562c3ca0766a2ca571210`. The source state after code PRs #420–#423 and README PR #416 was fixed at `ae4de1ce4d77f1a2a4c8d9656da8101c472fa3a0`. The v1.8.0 import baseline `0dca28dd984d82333707cbf4b222596934b4d847` has the same complete Git tree as the original `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf` source tag.

These anchors preserve auditability; they are not claims that every later recipe requirement has already been independently rebuilt and device-tested.

</details>

## License

MagicNet is released under the [MIT License](LICENSE). Third-party implementations, rules and tools retain their own licenses as recorded by the recipe's provenance and external prerequisite documents.
