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

在 `main` 上手动运行工作流时，可通过 `bump` 自动准备版本 PR：

| 输入 | 行为 |
| --- | --- |
| `none` | 构建当前已提交版本；勾选 `release` 可直接发布该版本 |
| `patch` | 补丁号加一，例如 `v1.3.9` → `v1.3.10` |
| `minor` | 次版本号加一并清零补丁号，例如 `v1.3.9` → `v1.4.0` |
| `major` | 主版本号加一并清零其余两位，例如 `v1.3.9` → `v2.0.0` |

选择升级时，工作流同步更新 `kam.toml`、`src/MagicNet/module.prop` 和
`update.json`，将 `versionCode` 加一，然后创建版本 PR，本次运行不执行模块构建。
同时勾选 `release` 会写入发布请求，PR 合并后自动构建并发布；`prerelease`
也会保存在请求中，且要求同时勾选 `release`。仅升级版本的 PR 合并后只构建。

同一目标版本使用固定的 `automation/release-vX.Y.Z` 分支，重复运行会更新
同一个 PR；不要手动编辑该自动化分支。若主分支已前进，旧运行重跑会拒绝操作，
请重新从 `main` 发起工作流。版本更新始终通过 PR，不直接推送受保护分支。

自动创建 PR 使用内置 `GITHUB_TOKEN`，需要 `contents: write`、
`pull-requests: write`（工作流已声明），以及仓库允许 Actions 创建 PR。
若创建失败，检查原始错误与 `Settings → Actions → General → Allow GitHub Actions
to create and approve pull requests`；工作流摘要提供恢复链接，不会自动修改设置。
机器人创建的 PR 检查可能等待批准，请由有写权限的成员在 PR 页面批准并正常合并。
工作流不会自动批准或合并 PR。

审查后可通过两种方式发布：

- 在版本 PR 中同时添加或更新 `.github/release-request`，首行为精确版本号，
  例如 `v1.3.9`。合并到 `main` 后，仅当该文件在本次 push 的 `before..sha`
  范围内发生变更时，才请求发布。文件会保留在仓库中；后续未修改它的 push
  不会重复请求发布。发布下一版时，将它更新为下一版的精确版本号。
  预发布可增加第二行 `prerelease=true`；省略时为正式发布。
  旧的单行版本标记继续兼容，旧的 `patch` 标记不再支持。
- 合并版本 PR 后，在 `main` 上手动运行 `exec.yml`，选择 `release=true`。
  手动发布时可选择 `prerelease=true`，将 Release 标记为预发布。
  此时 `bump` 保持 `none`，且当前版本标签必须尚不存在。

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
