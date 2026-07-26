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

Manual dispatch supports these inputs:

- `bump`: optionally bump the module version before building. The choices are
  `none`, `patch`, `minor`, and `major`. A successful bump also refreshes
  `versionCode`, `module.prop`, and `update.json`, then commits the metadata
  back to the branch used to dispatch the workflow.
- `release`: create/update a GitHub Release through `kam publish`.
- `prerelease`: mark that release as a prerelease.

The workflow only commits back to the repository when a manual run selects a
version bump. Normal push, pull request, and non-bump manual runs never commit.

Normal push and pull request runs build and upload workflow artifacts. When
`KAM_PRIVATE_KEY` is available, the uploaded artifact also includes the module
signature sidecar.

## Local Customization

Keep this shared baseline generic. Put project-specific workflows in additional
files; `kam sync workflow` preserves extra workflow files.
