# 发布 MagicNet

统一入口是主仓库的 [Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml)。源码仓库 `magicnet-android` 提供构建和 Android 验收；安装包、组件、正式 Release 和稳定更新索引都属于 `LIghtJUNction/MagicNet`。

## 在网页上发布

打开入口，点击 **Run workflow**，选择主仓库 **main**。日常发布选择 `mode=publish`、`bump=patch`；需要使用源码仓库最新提交时填写 `source_ref=main`。点击运行后，工作流会完成版本规划、构建、完整质量检查、Android/KernelSU 模拟器验收、资产校验、草稿上传和公开发布。稳定版公开成功后，再同步主仓库 `update.json` 和三个 README 的当前发行版本、版本号与下载说明链接。

要指定版本，例如 `1.9.0`，选择 `bump=none`，在 `version` 填写 `1.9.0` 或 `v1.9.0`。`version_code` 留空即可自动计算。已有源码声明版本尚未发布时，也可以选择 `bump=none` 并留空 `version`，直接构建、验收并发布该版本。

| 参数 | 作用 |
| --- | --- |
| `mode=build` | 构建并校验完整安装包和组件，上传 Actions artifacts；默认选项。 |
| `mode=verify` | 在构建基础上执行全部发布质量检查和 Android/KernelSU 验收；不创建 Release。 |
| `mode=publish` | 全部门禁通过后创建 Release，稳定版随后同步更新索引。 |
| `bump` | `none / patch / minor / major`。递增以源码声明版本和已公开版本中较新的版本为基准。 |
| `version` | 可选自定义 `X.Y.Z` 或 `vX.Y.Z`；要求 `bump=none`，不接受前导零、预发布后缀或更旧的源码版本。 |
| `version_code` | 可选 Android 整数版本号，范围 `1..2147483647`；发行时必须大于已公开版本。 |
| `source_ref` | 留空使用主仓库固定 gitlink；可填写源码仓库的 `main`、分支、标签或完整 SHA。解析后固定为一个提交。 |
| `prerelease` | 将发布结果标为预发布；要求 `mode=publish`，不更新稳定用户的 `update.json`。 |

版本不变时默认沿用源码 `versionCode`；改变版本时默认使用源码与已公开版本中较大的 code 再加一。`build/verify` 以当前主仓库的稳定索引作为预览基线；`publish` 还会查询 GitHub 已公开版本，包含已经公开的预发布。已经使用的版本不会再次覆盖。

## 命令行示例

先使用有仓库权限的 GitHub CLI 登录。以下命令调用同一工作流，不需要额外配置跨仓库 PAT。

```bash
# 完整验收下一个补丁版，但不发布
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main \
  -f mode=verify -f bump=patch -f source_ref=main

# 发布下一个补丁版
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main \
  -f mode=publish -f bump=patch -f source_ref=main

# 自定义版本；versionCode 自动计算
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main \
  -f mode=publish -f bump=none -f version=1.9.0 -f source_ref=main

# 指定版本和 Android versionCode，先生成可下载产物
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main \
  -f mode=build -f bump=none -f version=1.9.0 -f version_code=10700
```

## 版本和源码如何对应

`publish` 首先在主仓库创建 `release/run-<run_id>` 固定快照。它包含本次 `release-plan.json`、目标 `update.json`、发行说明和源码 gitlink，父提交为启动工作流时的主仓库提交。正式版本标签指向这个快照；`main/update.json` 在发布前继续指向当前稳定版。

构建和 Android 验收检出相同的源码 SHA，通过同一个脚本在隔离工作区写入目标版本、code、官方更新 URL 和 KAM changelog 字段。源码仓库不需要为每次发行接收写入凭据。`build-source.json` 记录固定源码基线、配方快照及实际打包版本；源码 SHA 表示版本注入前的基线，目标版本来自发布计划。

选择 `source_ref` 只影响本次固定快照，不会悄悄移动主仓库 main 的 gitlink。源码仓库新功能合入后，可以按常规提交更新主仓库指针，也可以在发布界面明确选择 `source_ref=main`。同一次运行的重跑复用原快照，即使源码分支后来有了新提交，已选源码也不改变。

所选源码需要包含本次迁移引入的 `scripts/stamp-release.py` 和新版构建接口；迁移以前的历史提交不支持通过这个入口直接回建。

## 产物与验证

Actions 的构建 artifact 包含 `MagicNet.zip`、`MagicNet-core.zip`、`magicnet_installer.zip`、`MagicNet-full.zip`、全部组件 ZIP、组件清单、来源记录、更新索引和 `SHA256SUMS`。前三个核心入口的字节相同；完整包可离线安装。测试、fixture、benchmark、coverage 和 `node_modules` 目录继续由最终归档门禁拒绝。

主仓库涉及工作流、发布脚本或源码指针的 PR 会执行下一补丁版的完整验收预览，覆盖跨仓库调用和版本注入；普通 main push 执行轻量配方与发布脚本回归。源码仓库日常 CI 继续验证自己的实现。真实 arm64 手机和真实网络验收需要单独记录，模拟器结果按模拟器范围报告。

轻量检查也会运行 `bash scripts/check-workflows.sh`，用固定版本、固定 SHA-256 的 actionlint 检查仓库内全部 `.github/workflows/*.yml` 和 `*.yaml`。它检查 Actions 的字段、表达式上下文、任务依赖及可在仓库内解析的可复用接口；跨仓库固定 SHA 的接口还通过实际 PR 调用验证。已有 ShellCheck、Python 和产品测试继续各自执行。

权限使用 GitHub 支持的静态值：`plan_read` 处理 PR、`build` 和 `verify`，只有 `contents: read`；`plan_publish` 只处理显式 `publish`，使用 `contents: write` 创建快照。两者共用同一准备 action，`plan` 仅选择成功结果。构建和验收显式检查前置任务成功，避免另一规划任务被正常跳过时连带跳过整个构建。公开发行还必须同时确认计划、构建、Android 和最终资产验证全部成功。

## 失败后继续

构建或验收失败会阻止公开 Release。上传先使用草稿，并逐项核对服务端资产名称、大小和 SHA-256；完整资产检查通过后才公开。既有正式版本和已上传但内容不匹配的资产不会被覆盖。

如果上传中断，使用原运行的 **Re-run failed jobs**。工作流核对原运行、原 artifact ID 和固定快照，保留已经校验通过的资产，只补齐缺失文件，再验证完整清单。重新构建导致 artifact ID 改变时，会拒绝替换已有草稿，避免把两次构建拼成一个版本。

如果 Release 已公开但稳定索引同步失败，结果会明确显示“Release 已发布，索引同步失败”。重跑失败的发布 job 会先核对已公开资产，然后继续索引同步，不会重复创建版本。同步基于最新 main 的小范围提交，同时更新稳定索引和 README 的当前发行字段，保留历史版本说明、并发文档编辑及源码 gitlink，并拒绝把较新的稳定索引回退。即使 `update.json` 已同步，重跑仍会检查并补齐遗漏的 README 字段。

预发布始终保留稳定更新索引，公开成功后只同步发行说明，保证 changelog 链接可访问。正式发布及快照写入使用主仓库自带 `GITHUB_TOKEN`；源码构建和 Android jobs 只有读取权限。
