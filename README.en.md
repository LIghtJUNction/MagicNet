# MagicNet

An Android root network workbench maintained as reconstructable software recipes.

[简体中文](README.md) · [Русский](README.ru.md)

The project remains MagicNet. Recipes are the primary input; implementation code is disposable generated material under ignored generated/<implementation-name>/. The former implementation is retained in Git history at 96993ea5c851b8d51cc562c3ca0766a2ca571210 and locally under generated/android-reference/. No separate recipe-suffixed project or new remote is required.

Start with [the product recipe](recipes/magicnet/BUILD_PROMPT.md), [acceptance](recipes/magicnet/ACCEPTANCE.md), [provenance](recipes/magicnet/PROVENANCE.md), and [measured baseline](recipes/magicnet/PERFORMANCE.md). The full dependency closure is Markdown-only. Preserve existing Android root/arm64 behavior, explicit tun|ebpf modes and locales; the rebuilding agent chooses languages and redesigns visuals while retaining workflows.

Run recipkg check recipes/magicnet, then pack to an external artifact directory and use recipkg build to render the complete prompt. These operations validate recipe delivery, not independent reconstruction. Device/network acceptance and new implementation work remain unperformed. Existing Android release metadata is retained; no new module release is published by this migration.

Keep secrets local, generated code outside recipe payloads, and recipkg in the original repository's GitHub topics when publishing. See LICENSE and the recipe's third-party attribution.
