# MagicNet

Build artifacts through [Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) on main. The default mode=build uploads the installer, offline module, components and checksums; mode=publish requires an explicitly prepared new software version, synchronized update.json files and release notes. Existing versions are never overwritten. Builds and Android acceptance use the same pinned implementation commit; all gates and uploaded asset digests must pass before a draft becomes public. These workflow checks do not establish arm64 device or real-network acceptance. Routine main pushes do not start this heavy build; PRs run lightweight recipe checks.

![Software and dependencies become a recipe for rebuilding software](https://raw.githubusercontent.com/recipkg/recipkg/main/assets/recipkg-cover.png)

An Android root network workbench maintained as reconstructable software recipes.

[简体中文](README.md) · [Русский](README.ru.md)

The project and primary repository remain MagicNet. Recipes in `recipes/` are the primary input. [generated/magicnet-android/](generated/magicnet-android/) is a pinned Git submodule of the separate [magicnet-android source repository](https://github.com/LIghtJUNction/magicnet-android). The source repository and child directory share the same lowercase, hyphenated name. Source code is outside the recipe payload and is not a Recipkg dependency. Observation checkouts remain separate; the temporary android-reference directory has been removed.

## Independent rebuild candidate

The `rebuild/recipe-0.3.1` branches contain a new implementation generated from an empty directory and a fresh context: a Go controller, native ES modules WebUI and Android Java bridge, with the explicitly approved pinned core and rule data. This branch pins source commit `b22f9f280ddaf729da47078c13838a73e6d89294`. The candidate software is **v1.8.1 / versionCode 10609**; the recipe version is **0.3.1**. Host tests, failure recovery, package checks and Android cross-compilation are recorded separately from actual Android device and network acceptance in [VERIFICATION.md](recipes/magicnet/VERIFICATION.md).

The actual frozen input is 335,805 bytes, 8 recipe packages and 53 Markdown files, SHA-256 `502e160a363ffdc6e60477261ac15b74884b07f37de78af69558b0806f8e717a`. The M40 release contract arrived on main after that input was frozen. The current recipe retains M40, but a newly rendered prompt is not the prompt used for this candidate. Integration must adapt and pass those release gates before merging the new implementation into the production release flow. No official Android release or device deployment is claimed.

To build this candidate, initialize `generated/magicnet-android`, enter that directory, then run `python3 scripts/fetch-build-inputs.py`, `bash scripts/build.sh all` and `python3 scripts/verify-package.py`. The complete offline package is `dist/MagicNet-full.zip`; the candidate's online components have not been published as official Release assets. See the [new implementation README](generated/magicnet-android/README.md).

Start with [the product recipe](recipes/magicnet/BUILD_PROMPT.md), [acceptance](recipes/magicnet/ACCEPTANCE.md), [provenance](recipes/magicnet/PROVENANCE.md), and [measured baseline](recipes/magicnet/PERFORMANCE.md). The full dependency closure is Markdown-only. Preserve existing Android root/arm64 behavior, explicit tun|ebpf modes and locales; the rebuilding agent chooses languages and redesigns visuals while retaining workflows.

Run `recipkg check recipes/magicnet`, pack into a temporary directory, check the archive, and use `recipkg build` to render the complete prompt. Delete temporary files after validation; retain an archive only when explicitly requested. These operations validate recipe delivery, not independent reconstruction. The v1.8.0 implementation continues from the existing software according to the updated recipes. See VERIFICATION for separate local, package and device evidence. Main tracks the source gitlink; historical release tags remain in MagicNet.

Keep secrets local, generated code outside recipe payloads, and recipkg in the original repository's GitHub topics when publishing. See LICENSE and the recipe's third-party attribution.

## Existing implementation on main

For the existing implementation, use a fresh `git clone --branch main --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git`, enter `MagicNet/generated/magicnet-android` and run `kam build -j 2`. Preserve any existing local changes. The existing implementation requires Rust/cargo-ndk, Android NDK, Go, Node/npm, Java/d8 and KAM; see its [pinned build guide](https://github.com/LIghtJUNction/magicnet-android/blob/b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7/docs/build.md). These requirements do not apply to this branch's new Go build.

Source commit `0dca28dd984d82333707cbf4b222596934b4d847` has exactly the same Git tree and six nested submodule pins as the original v1.8.0 commit `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf`. At candidate delivery, main retains source `b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7`, including unreleased subscription fixes and the concurrent release workflow changes; original history stays in MagicNet. Push authorized source changes before updating the primary repository's gitlink. Current released Android version: v1.8.0. [Release and installation notes](docs/releases/v1.8.0.md).

Recipe 0.3.0 extracts the pinned v1.8.0 source for issue #426: complete multi-source transactions, stable identities, duplicate-name handling, batch diagnostics, UI readback, VLESS Encryption preservation and installer aliases. See [the source audit](recipes/magicnet/SOURCE_AUDIT.md). Recipe check/pack/build needs only the complete Markdown closure, not the old product submodules. The source-build instructions above compile the existing release; independent reconstruction starts from an empty implementation directory and the recipe. Recipe 0.3.1 clarifies the exact rule-data source, the full node-identity target and integration responsibilities for an independent build. The unreleased source fixes, independent reconstruction, and device validation are recorded separately; no new Android release is implied.
