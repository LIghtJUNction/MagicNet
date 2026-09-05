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

`exec.yml` builds the module. It runs on `push`, `pull_request`, and manual
`workflow_dispatch`.

Prepare a new version in a pull request: update `kam.toml`,
`src/MagicNet/module.prop`, and `update.json` together, including `version` and
`versionCode`. The workflow builds the committed
version and never commits or pushes version changes to the protected branch.

There are two ways to publish after review:

- Include `.github/release-request` in the version PR, with the exact version
  on one line, for example `v1.3.9`. Merging it into `main` requests a release
  only when that file changed in the triggering push's `before..sha` range.
  The file remains in the repository; later pushes that leave it unchanged
  do not request another release. Update it to the next exact version for
  the next release. The previous `patch` marker is no longer supported.
- Merge the version PR, then dispatch `exec.yml` on `main` with `release=true`.
  Set `prerelease=true` to mark a manually requested release as a prerelease.
  The `bump` input has been removed.

Pull requests and ordinary pushes build and upload workflow artifacts without
publishing a release. When `KAM_PRIVATE_KEY` is available, the uploaded artifact
also includes the module signature sidecar.

Release checks require matching committed version metadata,
a matching release-request version when used, and a new tag and release.
Publishing requires signing and successful artifact and installation checks.
The release tag targets the exact `GITHUB_SHA` that was built. Existing tags
or releases are rejected; release assets are never overwritten.

## quality.yml

`quality.yml` keeps code-level checks independent from packaging. It requires
Rust formatting, Clippy with warnings denied, the complete Rust workspace test
suite, and ShellCheck for both host Bash tooling and device-side POSIX shell.

## Local Customization

Keep this shared baseline generic. Put project-specific workflows in additional
files; `kam sync workflow` preserves extra workflow files.
