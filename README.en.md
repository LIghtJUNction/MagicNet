# MagicNet

An Android root network workbench maintained as reconstructable software recipes.

[简体中文](README.md) · [Русский](README.ru.md)

The project and primary repository remain MagicNet. Recipes in `recipes/` are the primary input. [generated/magicnet-android/](generated/magicnet-android/) is a pinned Git submodule of the separate [magicnet-android source repository](https://github.com/LIghtJUNction/magicnet-android). The source repository and child directory share the same lowercase, hyphenated name. Source code is outside the recipe payload and is not a Recipkg dependency. Observation checkouts remain separate; the temporary android-reference directory has been removed.

Start with [the product recipe](recipes/magicnet/BUILD_PROMPT.md), [acceptance](recipes/magicnet/ACCEPTANCE.md), [provenance](recipes/magicnet/PROVENANCE.md), and [measured baseline](recipes/magicnet/PERFORMANCE.md). The full dependency closure is Markdown-only. Preserve existing Android root/arm64 behavior, explicit tun|ebpf modes and locales; the rebuilding agent chooses languages and redesigns visuals while retaining workflows.

Run `recipkg check recipes/magicnet`, pack into a temporary directory, check the archive, and use `recipkg build` to render the complete prompt. Delete temporary files after validation; retain an archive only when explicitly requested. These operations validate recipe delivery, not independent reconstruction. The v1.8.0 implementation continues from the existing software according to the updated recipes. See VERIFICATION for separate local, package and device evidence. Main tracks the source gitlink; historical release tags remain in MagicNet.

Keep secrets local, generated code outside recipe payloads, and recipkg in the original repository's GitHub topics when publishing. See LICENSE and the recipe's third-party attribution.

To fetch the complete project, use `git clone --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git`. In an existing checkout, run `git submodule update --init --recursive generated/magicnet-android`, then `cd generated/magicnet-android` and `kam build -j 2`. Preserve any existing local changes. Rust/cargo-ndk, Android NDK, Go, Node/npm, Java/d8 and KAM are required; see the [source build guide](generated/magicnet-android/docs/build.md). From the primary repository, the full local build output is `generated/magicnet-android/dist/MagicNet.zip`.

Source commit `0dca28dd984d82333707cbf4b222596934b4d847` has exactly the same Git tree and six nested submodule pins as the original v1.8.0 commit `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf`. The new repository starts from that clean snapshot; original history stays in MagicNet. Push authorized source changes before updating the primary repository's gitlink. Recipe version: 0.2.1; Android version: v1.8.0. [Release and installation notes](docs/releases/v1.8.0.md).
