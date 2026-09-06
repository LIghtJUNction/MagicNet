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

Dispatch on `main` with `bump=patch`, `minor`, or `major` to prepare a version PR.
For example, `v1.3.9` becomes `v1.3.10`, `v1.4.0`, or `v2.0.0`, respectively.
All three metadata files (`kam.toml`, `src/MagicNet/module.prop`, `update.json`)
are updated together and `versionCode` increases by one. This run creates the PR
without building the module. With `bump=none`, the workflow builds the existing
committed version and can publish it when `release=true`.

With a bump, `release=true` adds a release request so merging the PR builds and
publishes it. `prerelease=true` is preserved in that request and requires
`release=true`. A version-only PR builds without publishing after merge.

Each target version uses a dedicated `automation/release-vX.Y.Z` branch. Repeated
requests update the same PR; do not edit that generated branch manually. Reruns
whose original commit is no longer the head of main fail and require a new
dispatch. Version updates never push directly to the protected branch.

PR creation uses `GITHUB_TOKEN` with job-scoped `contents: write` and
`pull-requests: write`. The repository must allow Actions to create pull requests.
On failure, the workflow verifies the pushed branch's complete tree and base commit.
A matching branch produces a warning and a summary link to create the PR manually;
a missing or mismatched branch still fails. This supports repositories that disable
Actions PR creation without changing their permissions. The version branch is only
prepared at this point; publishing still requires merging its release request. Bot-created
PR workflow runs may await approval by someone with write access. Approve pending
runs on the PR page, review, and merge normally; this workflow does not approve
or merge its own PRs.

There are two ways to publish after review:

- Include `.github/release-request` in the version PR, with the exact version
  on the first line, for example `v1.3.9`. Merging it into `main` requests a release
  only when that file changed in the triggering push's `before..sha` range.
  The file remains in the repository; later pushes that leave it unchanged
  do not request another release. Update it to the next exact version for
  the next release. An optional second line, `prerelease=true`, requests a
  prerelease. Single-line version markers remain supported; the previous `patch`
  marker is no longer supported.
- Merge the version PR, then dispatch `exec.yml` on `main` with `release=true`.
  Set `prerelease=true` to mark a manually requested release as a prerelease.
  Keep `bump=none`; the committed version tag must not already exist.

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
