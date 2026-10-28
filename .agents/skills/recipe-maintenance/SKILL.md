---
name: recipe-maintenance
description: Maintain MagicNet's primary Markdown recipes, dependency contracts, and honest acceptance records before regenerating implementation.
---

Read AGENTS.md and recipes/magicnet/BUILD_PROMPT.md. Update the owning component recipe and its acceptance cases when changing behavior, interfaces, dependencies, storage, or limits. Preserve source attribution and unknowns.
Keep generated implementation under ignored generated/<implementation-name>/; never copy implementation, binaries, secrets, hooks, or filesystem links into recipe payloads.
Run recipkg check recipes/magicnet, pack outside recipes, check the archive and render its complete build prompt. Inspect every archive member as UTF-8 Markdown, including recursive dependencies.
Record actual results in recipes/magicnet/VERIFICATION.md. Packaging is not implementation acceptance. Use local verification for normal changes; publish only within existing authorization, preserving the project name MagicNet and original remote.
