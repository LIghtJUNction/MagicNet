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

新版本通过 PR 准备：同步更新 `kam.toml`、`src/MagicNet/module.prop` 和
`update.json` 中的 `version` 和 `versionCode`。
工作流构建已提交的版本，不会自行提交或向受保护分支推送版本变更。

审查后可通过两种方式发布：

- 在版本 PR 中同时添加或更新 `.github/release-request`，内容为单行精确版本号，
  例如 `v1.3.9`。合并到 `main` 后，仅当该文件在本次 push 的 `before..sha`
  范围内发生变更时，才请求发布。文件会保留在仓库中；后续未修改它的 push
  不会重复请求发布。发布下一版时，将它更新为下一版的精确版本号。
  旧的 `patch` 标记不再支持。
- 合并版本 PR 后，在 `main` 上手动运行 `exec.yml`，选择 `release=true`。
  手动发布时可选择 `prerelease=true`，将 Release 标记为预发布。
  `bump` 输入已移除。

普通 push 和 pull request 只构建并上传 workflow artifact；如果存在
`KAM_PRIVATE_KEY`，上传内容也会包含模块签名旁路文件。

发布前会检查已提交的版本元数据是否一致；使用发布请求文件时，
其中的版本号也必须一致。目标 tag 和 Release 必须尚不存在。
发布要求签名成功，并通过产物内容及安装检查。Release 的 tag 指向实际构建的
`GITHUB_SHA`。已有 tag 或 Release 会被拒绝，发布资产不会被覆盖。

## quality.yml

`quality.yml` 将代码质量检查与打包流程分离。它会检查 Rust 格式、以警告即错误
运行 Clippy、执行完整 Rust workspace 测试，并分别检查主机 Bash 工具和设备端
POSIX shell。

## 本地自定义

共享基线只放通用逻辑。项目自己的 workflow 放到额外文件里；
`kam sync workflow` 会保留这些额外文件。
