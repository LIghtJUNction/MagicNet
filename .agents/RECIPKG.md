# Shared Recipkg skills / 共享技能

This project pins eleven shared skills from their individual canonical GitHub repositories. The reviewed integration baseline is [Recipkg d41ccb6](https://github.com/recipkg/recipkg/commit/d41ccb6). See [the upstream catalog](skills/migrate-to-recipkg/PROJECT_SKILLS.md) for repositories and responsibilities.

```sh
git submodule update --init --recursive
recipkg --version
```

Use the separately installed Recipkg CLI for recipe checks and prompt generation. Shared skills are project development instructions, not runtime dependencies or recipe payload. Update skills in their own upstream repositories, inspect the changes, check out reviewed commits, and explicitly commit this project's gitlinks. Keep project-specific instructions in their existing files.

`generated/` is a container for source checkouts. New independently versioned source uses pinned child submodules at `generated/<source-repository-name>/`, with lowercase, hyphenated repository names. Existing local observation material and unfinished source work remain governed by the project's preservation rules.

本项目通过 11 个独立上游仓库的固定提交子模块复用 Recipkg 技能，不逐项目复制或新建技能仓库。先检查本地修改和上游差异，再更新子模块指针；已有项目自定义技能保持原文件。配方仅分发 UTF-8 Markdown，Git 元数据、源代码和用户数据不进入归档。源码独立仓库通过 `generated/` 下的子目录子模块接入；保留现有观察材料和未完成源码工作。结构检查与提示词生成通过不等于软件已经重建或上线。

## Local verification · 2026-10-28

All eight MagicNet recipes passed `recipkg check`. The root recipe was packed, its complete Markdown-only archive checked, and its Chinese build prompt rendered outside the project. All eleven shared skill gitlinks match the reviewed canonical commits.
