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

The workflow never commits back to the repository. Manual dispatch has two safe
release inputs:

- `release`: create/update a GitHub Release through `kam publish`.
- `prerelease`: mark that release as a prerelease.

Normal push and pull request runs only build and upload workflow artifacts.

## Local Customization

Keep this shared baseline generic. Put project-specific workflows in additional
files such as `.github/workflows/ranking.yml`; `kam sync workflow` preserves
extra workflow files.
