# MagicNet Workflows

MagicNet keeps code quality, packaging and real-device simulation separate.
See [Android simulation](../../docs/android-simulation.md) for the acceptance
phases, safety boundaries, cache policy and remaining coverage limits.

## android-kernelsu-acceptance.yml

This runs on every pull request, merge group, push to `main` and manual dispatch.
Uncached harness checks precede an Android 15 x86_64 AVD booted with a
SHA-256-pinned API35/6.6 KernelSU v3.2.0 kernel. Official x86_64 `ksud` then
requires that kernel interface to be active and uses upstream `late-load` for
userspace/lifecycle initialization after each boot. The automatic path uses a
local fixture, real KernelSU installation/reboots and app-UID TUN controls.
`Android Simulation Gate` rejects failed or unexecuted jobs. Its required-check
status in branch protection must be configured separately.

The former `init.yml` was removed. Its `kam validate`, `kam check`, release-workflow,
subscription-usage and artifact-signature tests now run in the Android build job
before packaging. The Code Quality shell lint remains in place.

## exec.yml

`exec.yml` builds the module. It runs on `push`, `pull_request`, and manual
`workflow_dispatch`.

Dispatch on `main` with `bump=patch`, `minor`, or `major` to commit a version bump
directly to `main`. For example, `v1.3.9` becomes `v1.3.10`, `v1.4.0`, or
`v2.0.0`, respectively. All three metadata files (`kam.toml`,
`src/MagicNet/module.prop`, `update.json`) are updated together and `versionCode`
increases by one. The workflow then explicitly dispatches the build for the new
commit because a `GITHUB_TOKEN` push does not start another `push` run.

With `bump=none`, the workflow builds the existing committed version and can
publish it when `release=true`.

With a bump, `release=true` adds a release request before the direct commit, so the
follow-up build publishes it. `prerelease=true` is preserved in that request and
requires `release=true`. A version-only bump builds without publishing.

Reruns whose original commit is no longer the head of `main` fail and require a
new dispatch.

There are two ways to publish after review:

- Include `.github/release-request` in the version commit, with the exact version
  on the first line, for example `v1.3.9`. Pushing it to `main` requests a release
  only when that file changed in the triggering push's `before..sha` range.
  The file remains in the repository; later pushes that leave it unchanged
  do not request another release. Update it to the next exact version for
  the next release. An optional second line, `prerelease=true`, requests a
  prerelease. Single-line version markers remain supported; the previous `patch`
  marker is no longer supported.
- Dispatch `exec.yml` on `main` with `release=true` to publish the current version.
  Set `prerelease=true` to mark the release as a prerelease.
  Keep `bump=none`; the committed version tag must not already exist.

Pull requests and ordinary pushes build and upload workflow artifacts without
publishing a release. When `KAM_PRIVATE_KEY` is available, the uploaded artifact
also includes the module signature sidecar.

Release checks require matching committed version metadata,
a matching release-request version when used, and a new tag and release.
Publishing requires signing and successful artifact and installation checks.
The release tag targets the exact `GITHUB_SHA` that was built. Existing tags
or releases are rejected; release assets are never overwritten.

### Build caches

Go module downloads and compiled packages are cached with keys covering the Go
version, NDK, module lockfiles, fork revision, and build-script inputs. A new fork
revision restores compatible previous entries and saves an updated cache after a
successful job, avoiding a permanently frozen cache keyed only by `go.sum`.

Rust caches include registry/git dependencies and `target/`. Module and quality
jobs have separate namespaces; keys include the compiler, lockfile/configuration,
and workspace sources, plus the NDK for Android builds. Restore prefixes retain
compatible dependency outputs across source and lockfile changes. Cargo still
checks fingerprints; the workflow never skips compilation based only on a cache hit.

`cargo-ndk` is pinned and cached in its own install directory; exact hits skip
`cargo install`. Node/npm and Bun download caches cover either WebUI package
manager. Tests, type checks, packaging, signatures, and smoke tests still run.
No final release ZIP or signing key is included in these new caches.

Only Kam's own cache is enabled in setup-kam. Its whole-`~/.rustup` cache is
disabled so it cannot overwrite a freshly installed Rust toolchain. The release
build installs its required `aarch64-linux-android` target; the AVD job also
installs `x86_64-linux-android`. The first run populates the new namespaces;
real speedups depend on later hits.

## quality.yml

`quality.yml` keeps code-level checks independent from packaging:

- Rust: formatting, Clippy with warnings denied, and workspace tests using locked dependencies and all targets/features.
- Shell: `bash scripts/lint-shell.sh` checks host tooling and first-party device scripts, including sourced runtime fragments. `bash scripts/test-host.sh` runs fixture-based regressions.
- WebUI: `npm ci` installs locked dependencies; `npm run check` runs tests, Vue component type checking with `vue-tsc`, and the build. After Chromium installation, `npm run test:ui` covers phone, landscape and desktop layouts, modal focus, keyboard clearance and draft retention. Browser fixtures do not access a device.

Local `scripts/pre-commit.sh` reuses these entrypoints and passes
`--with-routing-assets` to include the routing/DNS integration tests that require
a host sing-box binary and prepared rule sets. The CI fixture suite excludes
those two checks. Device, packaging, and installation checks remain separate.

## On-demand previews and network observations

`webui-preview.yml` replaces the duplicate automatic `webui.yml` check. It exports
source and built preview artifacts on manual dispatch; Code Quality owns automatic
WebUI tests. Public endpoints in `network-regression.yml` are observed only on
manual dispatch. Its real DNS NAT packet tests run without cached passes.

`public_benchmark=false` is the default for Android dispatch. Enabling it adds the
legacy public-proxy observation after offline acceptance; it does not substitute
for lifecycle or app-UID proof. Installation-onboarding, uninstall-browser,
network-evidence and rules-release workflows retain their distinct checks.

## Local customization

These are the MagicNet-specific workflows, not an unmodified shared baseline.
Review `kam sync workflow` changes so it does not reintroduce the removed
standalone validation or duplicate automatic WebUI jobs.
