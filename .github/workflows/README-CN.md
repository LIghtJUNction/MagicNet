# Kam Workflows

这里是 Kam 模块仓库共用的 GitHub Actions 基线。

## init.yml

`init.yml` 用于验证仓库。触发方式包括 `push`、`pull_request` 和手动
`workflow_dispatch`。

它会递归 checkout 子模块，使用 `MemDeco-WG/setup-kam@v3` 安装 Kam，然后运行：

```bash
kam validate
kam check
```

同时会对 `hooks/`、`src/` 和顶层 `kam.sh` 中存在的 shell 文件运行
`shellcheck`。

## exec.yml

`exec.yml` 用于构建模块。触发方式包括 `push`、`pull_request` 和手动
`workflow_dispatch`。

这个工作流不会自动向仓库提交。手动运行时只有两个安全发布输入：

- `release`：通过 `kam publish` 创建或更新 GitHub Release。
- `prerelease`：将该 Release 标记为 prerelease。

普通 push 和 pull request 只会构建并上传 workflow artifact。

## 本地自定义

共享基线只放通用逻辑。项目自己的 workflow 放到额外文件里，例如
`.github/workflows/ranking.yml`；`kam sync workflow` 会保留这些额外文件。
