# MagicNet 源码拆分后的 CI 与发布流程更新

日期：2026-11-06

## 目标与调整范围

本次更新将源码构建与正式发布连成一条流程：`LIghtJUNction/magicnet-android` 保存实现并提供只读构建、质量检查和 Android 验收；`LIghtJUNction/MagicNet` 负责选择版本和源码、核验产物、发布 GitHub Release、更新稳定索引。

实际修改的仓库与审查入口：

| 仓库 | PR | 职责 |
| --- | --- | --- |
| MagicNet | [#443](https://github.com/LIghtJUNction/MagicNet/pull/443) | 发布入口、版本规划、发布快照、资产核验与上传恢复、稳定索引、配方和操作指南。 |
| magicnet-android | [#4](https://github.com/LIghtJUNction/magicnet-android/pull/4) | 固定源码构建接口、统一版本注入、Android 同版本验收、来源记录和源码工作流文档。 |

关联的规则库、配置库和 sing-box 构建职责已检查；此次没有发现需要因源码拆分而修改其独立发布流程的证据。

## 原问题与修复方式

旧主仓库发布任务要求稳定 `update.json` 与源码 `update.json` 完全相同。当主仓库仍指向已发布的 `v1.8.4`，源码声明版本已经为 `v1.8.5` 时，规划阶段报 `Root/source update.json differs`，导致构建尚未开始便失败。原失败记录见 [run 42231987180](https://github.com/LIghtJUNction/MagicNet/actions/runs/42231987180)。

新版分别验证稳定索引与源码自身元数据的一致性。稳定索引表示用户当前能下载的版本；源码元数据表示所选源码的版本基线。发布计划再明确决定本次实际打包的版本。这样，源码继续开发时不需要提前移动稳定用户的更新入口。

源码工作流原有的 bump 和发布入口也已移除。正式发布统一从主仓库发起，避免在源码仓库生成错误仓库地址的组件清单或进入已经不适用的发布逻辑。

## 如何发布

打开 [Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml)，点击 **Run workflow**，选择 **main**。

| 想做的事 | 填写方式 |
| --- | --- |
| 构建当前固定源码并下载产物 | `mode=build`、`bump=none`；其余按需填写。 |
| 验收下一个补丁版 | `mode=verify`、`bump=patch`。 |
| 发布下一个补丁版 | `mode=publish`、`bump=patch`。 |
| 发布下一个次版本或主版本 | `mode=publish`、`bump=minor` 或 `major`。 |
| 发布自定义版本，例如 1.9.0 | `mode=publish`、`bump=none`、`version=1.9.0`。 |
| 使用源码仓库最新 main | 加上 `source_ref=main`；留空则使用主仓库固定 gitlink。 |
| 手动设置 Android 版本码 | 填写正整数 `version_code`；留空自动选择或递增。 |
| 发布预发布版本 | `mode=publish`、`prerelease=true`；稳定更新索引继续保留。 |

`version` 接受 `X.Y.Z` 和 `vX.Y.Z`。自定义版本与 bump 互斥；预发布使用单独的布尔选项，不接受版本字符串后缀。发布时版本和版本码必须超过已公开版本，已有标签和资产不会被覆盖。

完整说明、CLI 示例与失败恢复见 [GitHub 发布指南](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/releasing.md)，另有 [Google Drive 副本](https://drive.google.com/file/d/1iQuIIRDhonXSaC5fJyq7_eo47SJ3uZPS/view?usp=drivesdk)。

以本次选定源码的 `v1.8.5 / 10613` 和当前稳定版 `v1.8.4 / 10612` 为例，`patch` 得到 `v1.8.6`，`minor` 得到 `v1.9.0`，`major` 得到 `v2.0.0`，自动版本码均为 `10614`。语义版本表达此次变化的级别，Android 版本码表达安装升级的先后顺序；两者由同一发布计划记录，但不是按同一公式编码。

## 全流程如何保证对应关系

1. 规划阶段将源码分支或标签解析为固定 SHA，并确定目标版本与 Android `versionCode`。
2. `publish` 在主仓库创建 `release/run-<run_id>` 快照，记录发布计划、源码 gitlink、更新索引和发行说明。
3. 源码构建与 Android 验收接收同一源码 SHA 和目标版本，使用同一个脚本注入元数据并验证结果。
4. 构建保留现有质量检查、组件检查、安装器检查和归档检查；测试目录等内容继续禁止进入最终模块。
5. 主仓库验证资产完整清单、版本、更新 URL、来源记录和校验和。
6. 发布任务先上传草稿，验证服务端文件的名称、大小和 SHA-256，再公开 Release。标签指向固定快照。
7. 公开成功后，从最新 main 创建小范围提交同步发行说明和稳定索引；预发布只同步发行说明。

`build-source.json` 中的源码 SHA 指版本注入前的固定基线，目标版本由发布计划单独记录。源码仓库无需额外写入令牌；正式发布使用主仓库的 `GITHUB_TOKEN`。

## 失败与重试

构建或验收失败会阻止公开发布。上传中断时，在原运行选择 **Re-run failed jobs**；任务核对运行、快照和原 artifact ID，只补齐缺失文件。GitHub 上传失败遗留的零字节 `starter` 占位项，仅能在身份一致的原草稿内按资产 ID 清理。内容不一致的已上传文件不能替换。

如果 Release 已公开而稳定索引同步失败，重跑失败的发布任务会先校验已公开资产，再继续同步。同步不会覆盖其他 main 变更，也不会回退更新索引。重新构建会生成新的 artifact ID，因此不能拿新构建接管旧草稿；原 Actions artifacts 保留 30 天。

## 验证记录

本地验证通过：主仓库元数据与归档回归 19 项，发布规划、草稿上传、错误恢复和索引同步回归 32 项；全部工作流 actionlint、Python 语法检查、recipkg check/pack/archive/build 通过。配方验证覆盖 8 个配方和 61 个 Markdown 文件。

源码侧验证包含版本注入 10 项、Android 发布门禁 8 项、实际工作流 shell 行为 8 项、发布工作流 42 项、缓存 8 项、组件工作流门禁 3 项、子模块 CI 3 项、模拟器工作流 26 项及模拟器修复 37 项。真实 GitHub CI 补充完整 Go 组件、模块构建、质量检查和 Android 验收。

针对发布模式强制重测与日常 CI 的环境差异，还在 `CI_TEST_FORCE=1 CI_TEST_CACHE=1` 下执行了缓存引擎、发布缓存和路由入口的 35 项现有回归，全部通过；相关测试能正确隔离继承的强制执行标志。

实际运行记录（以下六条运行最终均为 success；源码质量检查为第二个 attempt）：

| 验证 | 运行 |
| --- | --- |
| 主仓库配方与发布脚本 | [42243860897](https://github.com/LIghtJUNction/MagicNet/actions/runs/42243860897) |
| 主仓库完整发布前演练 | [42243861547](https://github.com/LIghtJUNction/MagicNet/actions/runs/42243861547) |
| 源码构建 | [42243823344](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42243823344) |
| 源码质量检查 | [42243823384](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42243823384) |
| Android / KernelSU | [42243823430](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42243823430) |
| 网络回归证据 | [42243823381](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42243823381) |

主仓库演练选择 `v1.8.6 / versionCode 10614`。[首轮执行](https://github.com/LIghtJUNction/MagicNet/actions/runs/42237503608) 发现可复用构建 runner 缺少 `mksh`：构建、组件、安装器和 Android 验收通过后，`test-fswatch-lifecycle.sh` 在完整质量门禁内明确失败，因而最终资产核验与发布均未执行。独立质量工作流原本已安装该工具，所以只跑源码日常 CI 无法暴露这个差异。

已通过源码提交 [`b989227`](https://github.com/LIghtJUNction/magicnet-android/commit/b989227b140a7627edff8b60ad87655cb09ac2d0) 补齐唯一已证实的缺失依赖，并通过主仓库提交 [`4cd4f9b`](https://github.com/LIghtJUNction/MagicNet/commit/4cd4f9b75e0927f8fa49563963e60fb7ec3a2ad3) 更新源码 gitlink 与两条可复用工作流的固定 SHA。测试要求保持完整。

第二轮完整运行于 **16:06:06 UTC 全部通过**：规划、构建、完整质量门禁、Android 模拟器及其汇总门禁、主仓库最终资产核验均为 success。`test-fswatch-lifecycle.sh` 已在 15:50:55 UTC 实际通过，用时 20.51 秒。`publish` 因为这是 PR 验证而正常跳过。

主仓库 PR #443 已合入 main，合并提交 [`b1041f2`](https://github.com/LIghtJUNction/MagicNet/commit/b1041f26b062a230bb152fcb6554dcbef55f03b7) 的文件树与受测版本完全相同。

源码浏览器 job 的首个 attempt 因 Azure Ubuntu 镜像下载 `fonts-noto-cjk` 超过时间预算而取消，失败发生在浏览器测试开始之前。只重跑该 job 及其依赖的最终质量门禁后，第二个 attempt 已全部成功：浏览器 job `127998258869`、最终质量门禁 `128004597501` 均为 success。已通过的构建、网络和 Android jobs 得以保留，没有为此次镜像下载问题修改产品代码或安装源。

源码 PR #4 已合入 main，合并提交为 [`467774c`](https://github.com/LIghtJUNction/magicnet-android/commit/467774c14e6e9107ad521ee3fe6fce337292941b)。该合并树与四组 PR CI 全部通过的审查版本完全相同；最终主分支另包含上述 `mksh` 依赖修复。

## 本次验证产物

[主仓库构建 artifact](https://github.com/LIghtJUNction/MagicNet/actions/runs/42243861547/artifacts/13519083778) 的 ID 为 `13519083778`，大小为 `142286196` 字节，保留至 **2026-12-06 16:05:25 UTC**。这是 `v1.8.6 / 10614` 的验证产物，尚未创建正式版本标签或 Release。预先试装可使用其中的 `MagicNet-full.zip` 离线完整包；版本对应的在线安装器下载地址会在正式发布后才可用。

服务端 artifact ZIP 的 SHA-256：

```text
4f0b22ecc93d40b0b9eb9c6620570e5a8150e4dc92d1276cff04d5e5f167bbf7
```

包内还有针对实际发行文件的 `SHA256SUMS`，其含义与外层 Actions artifact ZIP 的校验值不同。Android 验收报告 artifact ID 为 `13518366697`，发布计划 artifact ID 为 `13516868330`。

## 使用边界

所选源码须包含本次新增的版本注入脚本和构建接口；迁移以前的历史提交不能直接通过新入口回建。Android CI 的验收范围是 Android 15 / KernelSU / x86_64 模拟器的确定性生命周期测试；手动公网 benchmark、长时间联网观测、真实 arm64 设备与真实网络验收不计入本次结果，需要另行记录。

本次变更用于更新和验证发布能力，没有创建新的正式软件版本。实际 Release 的公开上传路径通过隔离回归测试验证；本次 GitHub 演练执行到发布前验收。
