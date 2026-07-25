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

手动运行支持以下输入：

- `bump`：构建前按需提升模块版本，可选 `none`、`patch`、`minor` 和
  `major`。成功提升版本后会同时刷新 `versionCode`、`module.prop` 和
  `update.json`，并将这些元数据提交回启动工作流时选择的分支。
- `release`：通过 `kam publish` 创建或更新 GitHub Release。
- `prerelease`：将该 Release 标记为 prerelease。

只有手动运行并选择版本提升时，工作流才会向仓库提交。普通 push、PR 和未选择
版本提升的手动构建都不会提交。

普通 push 和 pull request 会构建并上传 workflow artifact；如果存在
`KAM_PRIVATE_KEY`，上传内容也会包含模块签名旁路文件。

## 本地自定义

共享基线只放通用逻辑。项目自己的 workflow 放到额外文件里，例如
`.github/workflows/ranking.yml`；`kam sync workflow` 会保留这些额外文件。
