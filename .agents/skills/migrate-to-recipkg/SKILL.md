---
name: migrate-to-recipkg
description: Turn an existing software project into a Markdown-only Recipkg recipe with recursive dependencies, observable acceptance criteria, and a discoverable recipe repository.
---

# Migrate software to Recipkg

[简体中文](SKILL.zh-CN.md)

## Inputs and boundaries

Use the software directory, Git repository, or observable product; behavior to preserve; target environments; and a recipe output location. A recipe preserves requirements, interfaces, dependencies, and acceptance conditions for a future rebuild. Keep implementation source, binaries, generated output, and installation scripts out of its payload. Writing a recipe is not rebuilding software.

## Resolve choices before changing the layout

Read the conversation and project materials first. Ask only for consequential missing information, grouping questions together. While waiting for required answers, inspect material without creating repositories or changing their layout.

1. **Language preferences:** retain the source language or select languages suitable for the target platforms. Record the preference and whether the rebuilding agent may choose another language.
2. **Product intent:** identify problems to solve, behavior to preserve, requested changes, non-goals, and constraints.
3. **Design and interaction:** for visual products, establish references, identity, hierarchy, density, color, typography, and motion where known. Avoid generic AI dashboards. CLI/API products still need readable output, errors, and documentation.
4. **Internationalization:** preserve current languages or specify additional locales, right-to-left support, formatting, time zones, and translation maintenance. Mark unknowns explicitly.
5. **Target platforms:** identify applicable desktop, mobile, browser, server, or embedded environments, including known minimum versions and architectures.
6. **Performance:** identify important workloads, devices, latency, throughput, memory, network, or distribution-size constraints. Do not invent targets; record unknown budgets and real baselines when measurement is in scope.
7. **Repository layout:** use a separate migration workspace with the original repository pinned as a `source/` submodule by default, or retain an established same-repository layout with `recipes/<package-name>/`. Existing conventions or user choices take precedence. The source checkout is observation material, never a recipe dependency or archive payload.

Before adding a source submodule, verify its remote and reviewed commit. Preserve local work; resolve the observation scope when uncommitted source affects it. Do not overwrite an existing output directory.

## Procedure

1. Read applicable project instructions, README, licensing, build metadata, interfaces, and acceptance evidence. Record the observation version and scope; distinguish observations, assertions from tests/docs, inferences, and unknowns.
2. Generate an observation checklist with `recipkg extract <target> --lang en` or `--lang zh-CN`. The CLI only prints a task; actually inspect authorized source or products.
3. Reuse a valid recipe, or create a scaffold with `recipkg init <output> --name <package-name>`. Complete `RECIPE.md`, `BUILD_PROMPT.md`, and `ACCEPTANCE.md` with behavior, interfaces, environment, language/platform choices, design direction, quality constraints, and measurable acceptance conditions.
4. Describe necessary components as recursively complete recipes. Distinguish dependencies from operating systems, compilers, accounts, datasets, remote services, and references. Source-only repositories are not recipe dependencies. Use `recipkg search [keywords]` for candidates, then inspect the recipe and pin a reviewed source.
5. Define success, failure, boundary, and integration checks. For UI products include important states, narrow layouts, and accessibility. Record performance workloads, environments, commands, and methods only when measured; keep unperformed checks unverified.
6. GitHub repositories publishing Recipkg recipes must carry the `recipkg` topic. When publication is authorized, use `gh repo edit <owner/repo> --add-topic recipkg` or available tooling, preserve existing topics, and read back the result. For local-only repositories record this publishing requirement. Topics enable discovery, not validation or trust.
7. Ensure every payload file is UTF-8 `.md` without implementation source, binaries, filesystem links, or execution hooks. Run `recipkg check <output>`, package complete dependencies with `recipkg pack <output> -o <archive>`, check the archive, and render its full build prompt. Write archives outside the source directory.

## Deliverable

Provide the recipe directory and optional archive, source version, languages/platforms/layout, preserved behavior, recursive dependencies, external prerequisites, inference, and unperformed checks. Preserve attribution and licensing. Successful packaging proves structural delivery, not successful independent reconstruction.

## Generated source layout

Treat recipes as the primary input. Place generated implementation source under `generated/`, with no extra implementation-name directory; when independently versioned, use this directory itself as a pinned source submodule of the recipe repository. Keep observation checkouts separate. Create remotes and push only within existing publication authorization; otherwise complete local work and record its unpublished state.

Keep the original project and primary repository name; do not append `-recipkg`. Independently managed source repositories use lowercase, hyphenated names.
