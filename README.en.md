# MagicNet

An Android root network workbench maintained as reconstructable software recipes.

[简体中文](README.md) · [Русский](README.ru.md)

The project remains MagicNet. Recipes are the primary input; implementation code is disposable generated material under ignored generated/<implementation-name>/. The former implementation remains in Git history; the temporary android-reference directory has been removed. No separate recipe-suffixed project or new remote is required.

Start with [the product recipe](recipes/magicnet/BUILD_PROMPT.md), [acceptance](recipes/magicnet/ACCEPTANCE.md), [provenance](recipes/magicnet/PROVENANCE.md), and [measured baseline](recipes/magicnet/PERFORMANCE.md). The full dependency closure is Markdown-only. Preserve existing Android root/arm64 behavior, explicit tun|ebpf modes and locales; the rebuilding agent chooses languages and redesigns visuals while retaining workflows.

Run recipkg check recipes/magicnet, then pack to an external artifact directory and use recipkg build to render the complete prompt. These operations validate recipe delivery, not independent reconstruction. The v1.8.0 implementation continues from the existing software according to the updated recipes; this is not a claim of independent reconstruction. See VERIFICATION for separate local, package and device evidence. Source snapshots live in version tags in this same repository; main stays recipe-first.

Keep secrets local, generated code outside recipe payloads, and recipkg in the original repository's GitHub topics when publishing. See LICENSE and the recipe's third-party attribution.

To build a released implementation, clone this repository with `--branch v1.8.0 --single-branch` into an unused `generated/magicnet-android/`, initialize its submodules, and follow that tag’s build guide. Use `kam build -j 2` with Rust/cargo-ndk, Android NDK, Go, Node/npm, Java/d8 and KAM installed. Recipe version: 0.2.0. [Release and installation notes](docs/releases/v1.8.0.md).
