<div align="center">
  <img src="icon.png" width="112" alt="MagicNet icon">
  <h1>MagicNet</h1>
  <p>A transparent networking control plane for rooted Android.</p>

  [![Android release](https://img.shields.io/badge/Android-v1.8.5%20%2F%2010613-111111?style=flat-square&logo=android)](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.5)
  [![Recipe](https://img.shields.io/badge/recipe-0.3.20-111111?style=flat-square)](recipes/magicnet/BUILD_PROMPT.md)
  [![License](https://img.shields.io/github/license/LIghtJUNction/MagicNet?style=flat-square)](LICENSE)

  [English](README.en.md) · [Русский](README.ru.md) · [Download](https://github.com/LIghtJUNction/MagicNet/releases) · [Evidence](recipes/magicnet/VERIFICATION.md)
</div>

MagicNet manages subscriptions, app/domain/Wi-Fi/hotspot routing, DNS, selectors and Tailscale through a multilingual web console and CLI. It supports explicit `tun|ebpf` modes, defaults to TUN, and packages a sing-box-compatible runtime for Android root/arm64 with Magisk, KernelSU or APatch.

## Start here

| Goal | Entry point |
| --- | --- |
| Install and use MagicNet | [Releases](https://github.com/LIghtJUNction/MagicNet/releases) and [v1.8.5 installation notes](docs/releases/v1.8.5.md) |
| Build the maintained implementation | [Source repository](https://github.com/LIghtJUNction/magicnet-android) and [build guide](generated/magicnet-android/docs/build.md) |
| Rebuild from requirements | [Product recipe](recipes/magicnet/BUILD_PROMPT.md) and [acceptance](recipes/magicnet/ACCEPTANCE.md) |
| Publish a version | [Release guide](docs/releasing.md) |

## Current state

| Layer | Current state |
| --- | --- |
| Published Android package | [`v1.8.5 / 10613`](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.5) |
| Recipe | `0.3.20` |
| Fixed implementation commit | `e8b4bb76dcb54e5d242c20ffcebae96d588c98a8` |
| Fixed sing-box core | `d850ff0ff68e11a71aa8207627e0a826cb52808f` / `1.15.0-alpha.13` |

The recipe defines required behavior; the pinned source provides the maintained implementation; Releases provide installable artifacts. [Verification](recipes/magicnet/VERIFICATION.md) records source tests, package checks and Android emulator results separately. Physical-device acceptance, real subscription connectivity and sustained mobile performance remain open; see [performance](recipes/magicnet/PERFORMANCE.md) and [Issue tracking](recipes/magicnet/ISSUE_TRIAGE_2026-11-06.md).

## Build the maintained implementation

```bash
git clone --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init --recursive generated/magicnet-android
cd generated/magicnet-android
kam build -j 2
```

Follow the [build guide](generated/magicnet-android/docs/build.md) for the pinned Rust, Go, Node, Java and Android toolchains. The complete local package is `generated/magicnet-android/dist/MagicNet.zip` relative to the primary repository.

## Rebuild from the recipe

Install Git and the Recipkg CLI, then render the complete requirements for an implementation agent:

```bash
set -eu
recipkg check recipes/magicnet
recipe_tmp="$(mktemp -d)"
trap 'rm -rf "$recipe_tmp"' EXIT
recipkg pack recipes/magicnet -o "$recipe_tmp/magicnet.recipe.tar.gz"
recipkg check "$recipe_tmp/magicnet.recipe.tar.gz"
recipkg build "$recipe_tmp/magicnet.recipe.tar.gz" --lang zh-CN
```

`recipkg build` renders a prompt. The agent must implement the product and execute [ACCEPTANCE.md](recipes/magicnet/ACCEPTANCE.md). Independent reconstruction starts with an empty implementation directory and the complete Markdown dependency closure; its permitted external assets are defined in the recipe. Keep `.env`, subscriptions, credentials and private device data outside source, archives and prompts.

The eight packages cover the product, control plane, network runtime, packet engine, routing policy, web console, module delivery and shared quality requirements. [DEPENDENCIES.md](recipes/magicnet/DEPENDENCIES.md) maps their responsibilities.

## Development and release

Update affected recipes, interfaces and acceptance cases with behavior changes. Verify and push source changes before updating the primary repository's gitlink. [Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) supports `build`, `verify` and `publish`, version bumping and exact versions; [releasing.md](docs/releasing.md) owns the inputs and recovery procedure.

Local checks:

```bash
python3 scripts/check-recipes.py
python3 scripts/test-release.py
python3 scripts/test-release-plan.py
python3 scripts/test-check-recipes.py
```

## Sources and license

[SOURCE_AUDIT.md](recipes/magicnet/SOURCE_AUDIT.md) records inspected source; [PROVENANCE.md](recipes/magicnet/PROVENANCE.md) retains attribution and historical anchors, including the v1.8.0 import. MagicNet uses the [MIT License](LICENSE); third-party components retain their own licenses.
