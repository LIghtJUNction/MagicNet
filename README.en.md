# MagicNet

A transparent networking control plane for Android root/arm64: subscriptions, app/domain routing, DNS, TUN/eBPF and a multilingual web console.

[Main guide](README.md) · [Русский](README.ru.md) · [Source](https://github.com/LIghtJUNction/magicnet-android)

Recipe version: 0.3.20; current gitlink: `7c8faf8327a5249b83f721f0c1a64098ea92f576`; current Android release: [v1.8.5 / 10613](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.5). [Release and installation notes](docs/releases/v1.8.5.md).

The primary repository stores Markdown product contracts; `generated/magicnet-android/` pins the maintained implementation. Start with [requirements](recipes/magicnet/BUILD_PROMPT.md), [acceptance](recipes/magicnet/ACCEPTANCE.md) and [verification](recipes/magicnet/VERIFICATION.md). Independent reconstruction uses an empty implementation directory and the full recipe closure. Source, secrets and device state stay outside recipe archives.

Clone with `git clone --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git`. For an existing checkout, run `git submodule update --init --recursive generated/magicnet-android`. Follow the [source build guide](generated/magicnet-android/docs/build.md), then run `kam build -j 2` inside the source submodule. The [main guide](README.md#rebuild-from-the-recipe) provides recipe validation and prompt generation commands.

[Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) supports `build`, `verify` and `publish`, `patch/minor/major` bumps, exact versions and an optional `source_ref`. Build and Android acceptance use the same immutable source and version. Publication verifies uploaded assets before updating the stable index; prereleases preserve it. See [release instructions and recovery](docs/releasing.md).

Physical-device acceptance, real subscription connectivity, minimum Android/WebView versions and sustained mobile performance remain unverified. Historical v1.8.0 import and v1.8.1 release evidence retain their own identities in [provenance](recipes/magicnet/PROVENANCE.md) and [verification](recipes/magicnet/VERIFICATION.md). MagicNet uses the [MIT License](LICENSE); third-party licenses remain applicable.
