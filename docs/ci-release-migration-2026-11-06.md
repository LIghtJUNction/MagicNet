# 跨仓库 CI 与发布迁移 · 2026-11-06

主仓库 [PR #443](https://github.com/LIghtJUNction/MagicNet/pull/443) 与源码 [PR #4](https://github.com/LIghtJUNction/magicnet-android/pull/4) 已合入。MagicNet 负责版本选择、发布快照、资产验证、GitHub Release 与稳定索引；magicnet-android 提供固定源码构建及同版本 Android 验收。

现行操作以 [releasing.md](releasing.md) 为准；本文记录当次迁移。完整过程、旧失败与原始链接见[固定历史记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/docs/ci-release-migration-2026-11-06.md)。

## 修正的行为

- 稳定 `update.json` 与源码元数据分别验证，解决源码开发领先公开版时的 `Root/source update.json differs`；[原失败运行](https://github.com/LIghtJUNction/MagicNet/actions/runs/42231987180)保留。
- 源码 SHA 一次解析并冻结。构建与 Android 验收注入同一版本/code，来源记录区分源码基线与目标版本。
- `publish` 保存 `release/run-<run_id>` 快照；先上传草稿并核对名称、大小、SHA-256，再公开。原 run 重试绑定原 artifact，仅补缺失资产。
- 公开后从最新 main 同步稳定索引；预发布保留稳定索引。源码构建只读，主仓库使用 `GITHUB_TOKEN`。
- runner 补入完整质量套件所需 mksh；保留所有原有质量、安装、组件及归档门禁。

## 实际验证

本地通过主仓库资产 19 项、发布规划/恢复/同步 32 项、全部工作流 actionlint 与 Python 语法，以及八包/61 Markdown 的 check/pack/archive/build。源码版本注入、Android 门禁、工作流、缓存、子模块与模拟器夹具通过；CI 的真实构建与 Android 执行另列。

| 范围 | 成功运行 |
| --- | --- |
| 主仓库配方与发布脚本 | [42243860897](https://github.com/LIghtJUNction/MagicNet/actions/runs/42243860897) |
| 完整发布预览 | [42243861547](https://github.com/LIghtJUNction/MagicNet/actions/runs/42243861547) |
| 源码构建 | [42243823344](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42243823344) |
| 源码质量 | [42243823384](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42243823384)，第二个 attempt |
| Android / KernelSU | [42243823430](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42243823430) |
| 网络证据 | [42243823381](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42243823381) |

预览选择 v1.8.6 / 10614，规划、构建、完整质量、Android 与最终资产核验成功，publish 按 PR 条件跳过。源码质量首次浏览器 job 在字体下载阶段超时；同一候选仅重跑该 job 及最终门禁后成功，原成功 jobs 保留。

mksh 修复提交为 [b989227](https://github.com/LIghtJUNction/magicnet-android/commit/b989227b140a7627edff8b60ad87655cb09ac2d0)，主仓库 pin 更新为 [4cd4f9b](https://github.com/LIghtJUNction/MagicNet/commit/4cd4f9b75e0927f8fa49563963e60fb7ec3a2ad3)。主仓库合并 [b1041f2](https://github.com/LIghtJUNction/MagicNet/commit/b1041f26b062a230bb152fcb6554dcbef55f03b7)、源码合并 [467774c](https://github.com/LIghtJUNction/magicnet-android/commit/467774c14e6e9107ad521ee3fe6fce337292941b) 的树分别与受测审查版本一致。

## 产物与边界

[模块 artifact 13519083778](https://github.com/LIghtJUNction/MagicNet/actions/runs/42243861547/artifacts/13519083778)：142,286,196 字节，外层 ZIP SHA-256 `4f0b22ecc93d40b0b9eb9c6620570e5a8150e4dc92d1276cff04d5e5f167bbf7`，记录到期时间 2026-12-06 16:05:25 UTC。包内 `SHA256SUMS` 核验实际发行文件；Android artifact `13518366697`，计划 artifact `13516868330`。

这是 v1.8.6 / 10614 验证产物，当次未创建正式标签或 Release。Android 范围为 Android 15 / KernelSU / x86_64 模拟器生命周期；真实 ARM64 手机、真实订阅、公网 benchmark、持续负载另需验收。公开上传和重试逻辑使用隔离回归验证；本次 GitHub 演练执行到公开前门禁。旧源码须先具备版本注入脚本和新版构建接口，才能使用现行入口回建。

历史[发布指南副本](https://drive.google.com/file/d/1iQuIIRDhonXSaC5fJyq7_eo47SJ3uZPS/view?usp=drivesdk)保留；现行步骤使用仓库发布指南。
