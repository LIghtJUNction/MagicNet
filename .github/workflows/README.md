# Kam Workflows

This directory contains the shared workflow baseline used by Kam module
repositories.

## init.yml

`init.yml` validates the repository. It runs on `push`, `pull_request`, and
manual `workflow_dispatch`.

It checks out submodules, installs Kam with `MemDeco-WG/setup-kam@v3`, then
runs:

```bash
kam validate
kam check
```

It also runs `shellcheck` over shell files under `hooks/`, `src/`, and the
top-level `kam.sh` when they exist.

## exec.yml

`exec.yml` builds the module on `push`, `pull_request`, and manual
`workflow_dispatch`.

Dispatch on `main` with `bump=patch`, `minor`, or `major` to update all three
metadata files (`kam.toml`, `src/MagicNet/module.prop`, `update.json`) and increase
`versionCode` by one. The workflow commits directly to `main`, then builds that
exact commit in the same job. It does not create a version branch or PR.
For example, `v1.3.9` becomes `v1.3.10`, `v1.4.0`, or `v2.0.0`, respectively.
With `bump=none`, the workflow builds the existing committed version.

Select `release=true` to publish after the same run passes its signing, artifact,
and installation checks. `prerelease=true` requires `release=true`. Leave release
unchecked to bump and build without publishing. A failed build does not roll back
a committed version: after fixing the failure, use `bump=none` to retry that
unpublished version instead of incrementing it again.

### Direct-push permissions

The bump step uses `RELEASE_TOKEN` when configured, otherwise `GITHUB_TOKEN`.
MagicNet's current main ruleset requires a PR and allows repository administrators
to bypass that rule. The ordinary `GITHUB_TOKEN` cannot bypass it. For this ruleset,
configure the `RELEASE_TOKEN` Actions secret with a repository-scoped token owned
by an authorized administrator and with Contents read/write permission. Never put
the token in workflow source. This workflow does not weaken branch protection.

The push is fast-forward only. A stale checkout, a concurrent update of `main`,
or a rejected push fails before compilation; there is no force push, automatic
rebase, or fallback PR. Version commits include `[skip ci]` to avoid a duplicate
push build when using `RELEASE_TOKEN`; the dispatch job continues with the new
`RELEASE_COMMIT_SHA`. Tags and metadata verification use that SHA, not the
original dispatch SHA. Existing tags/releases are rejected and never overwritten.
Publishing requires the `KAM_PRIVATE_KEY` signing secret; a bump with release
enabled checks its presence before changing metadata.

For compatibility, a changed `.github/release-request` in a main push can still
request publication. Its first line must equal the committed `vX.Y.Z`, with an
optional second line `prerelease=true`. An unchanged marker never republishes.
The direct bump preserves this marker convention when release is requested, but
publication no longer depends on a separate push run or a PR merge.

Ordinary pushes and pull requests build and upload artifacts without publishing.
When `KAM_PRIVATE_KEY` is available, artifacts include the signature sidecar.

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
disabled so it cannot overwrite a freshly installed Rust toolchain. Android
standard libraries are installed normally without deleting toolchain directories;
only the module's required `aarch64-linux-android` Rust target is installed.
The first run populates the new namespaces; real speedups depend on later hits.

## quality.yml

`quality.yml` keeps code-level checks independent from packaging:

- Rust: formatting, Clippy with warnings denied, and workspace tests using locked dependencies and all targets/features.
- Shell: `bash scripts/lint-shell.sh` checks host tooling and first-party device scripts, including sourced runtime fragments. `bash scripts/test-host.sh` runs fixture-based regressions.
- WebUI: `npm ci` installs locked dependencies; `npm run check` runs tests, Vue component type checking with `vue-tsc`, and the build. After Chromium installation, `npm run test:ui` covers phone, landscape and desktop layouts, modal focus, keyboard clearance and draft retention. Browser fixtures do not access a device.

Local `scripts/pre-commit.sh` reuses these entrypoints and passes
`--with-routing-assets` to include the routing/DNS integration tests that require
a host sing-box binary and prepared rule sets. The CI fixture suite excludes
those two checks. Device, packaging, and installation checks remain separate.

## Local Customization

Keep this shared baseline generic. Put project-specific workflows in additional
files; `kam sync workflow` preserves extra workflow files.
