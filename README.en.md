# MagicNet

A transparent networking control plane for Android root/arm64: subscriptions, app/domain routing, DNS, TUN/eBPF and a multilingual web console.

[Main guide](README.md) · [Русский](README.ru.md) · [Source](https://github.com/LIghtJUNction/magicnet-android)

Recipe version: 0.3.35; current gitlink: `75da8b3064350dd335844da1957cd45b6c347f9c`; current Android release: [v1.9.1 / 10619](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.9.1). [Release and installation notes](docs/releases/v1.9.1.md).

The primary repository stores Markdown product contracts; `generated/magicnet-android/` pins the maintained implementation. Start with [requirements](recipes/magicnet/BUILD_PROMPT.md), [acceptance](recipes/magicnet/ACCEPTANCE.md) and [verification](recipes/magicnet/VERIFICATION.md). Independent reconstruction uses an empty implementation directory and the full recipe closure. Source, secrets and device state stay outside recipe archives.

Clone with `git clone --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git`. For an existing checkout, run `git submodule update --init --recursive generated/magicnet-android`. Follow the [source build guide](generated/magicnet-android/docs/build.md), then run `kam build -j 2` inside the source submodule. The [main guide](README.md#rebuild-from-the-recipe) provides recipe validation and prompt generation commands.

[Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) supports `build`, `verify` and `publish`, `patch/minor/major` bumps, exact versions and an optional `source_ref`. Build and Android acceptance use the same immutable source and version. Publication verifies uploaded assets before updating the stable index; prereleases preserve it. See [release instructions and recovery](docs/releasing.md).

A locally built `v1.9.1 / 10619` candidate from source [`5169e071`](https://github.com/LIghtJUNction/magicnet-android/commit/5169e07155a47d16f3c5e610a8aa368cc2d08b02) has been checked on one ARM64 phone: upgrade with configuration retention, HTTPS from an ordinary app UID with a real subscription, navigation across 14 pages, a physical tap opening Zashboard with local node data, and a 10-second cellular interruption followed by 180 seconds of observation. Application HTTPS recovered after the interruption, while the strict proxy probe retained an endpoint-specific degraded result. This device evidence belongs to that candidate; the newer gitlink above has separate CI evidence.

broader OEM coverage, minimum Android/WebView versions and sustained mobile performance remain open. [Verification](recipes/magicnet/VERIFICATION.md) separates these limits from completed source, emulator and device checks. Historical v1.8.0 import and v1.8.1 release evidence retain their own identities in [provenance](recipes/magicnet/PROVENANCE.md).

MagicNet uses the [MIT License](LICENSE); third-party licenses remain applicable.
