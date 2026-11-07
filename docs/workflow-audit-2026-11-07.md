# MagicNet 工作流逐项审计与修复

日期：2026-11-07。审计按当前默认分支与实际集成分支的 Git tree 逐文件进行。

本轮修复主仓库发布工作流的权限解析错误，并检查源码与三个直接关联仓库的全部现行工作流。最初共有 25 份 workflow；sing-box 新增一份全量检查工作流后共有 26 份。所有 26 份均通过固定版本的 Actions 语义检查。首次完整预览发现 ADB 成功测试与超时负例共用 1 秒预算的问题，已在源码修复并更新主仓库固定点；源码最终提交的质量、构建、证据及 Android 四条流水线全部成功；主仓库完整预览的构建、强制完整质量检查、Android 验收与最终资产校验全部成功。修复已通过 PR #445 合并 main。sing-box 的代码修复已经提交，但该 fork 的 Actions 被 GitHub 暂停，线上验证需要维护者重新启用。

报告按以下顺序给出证据：审计范围和提交、已修复问题、逐文件结果、实际验证、仍需执行的动作。当前正式 Android 发行版仍是 [v1.8.4 / 10612](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.4)；本轮没有创建新软件 Release。

## 1. 范围与提交

| 仓库 | 审计分支 | 当前 workflow 数量 | 本轮提交 |
| --- | --- | ---: | --- |
| MagicNet | main（PR #445 已合并） | 2 | [e1c27da](https://github.com/LIghtJUNction/MagicNet/commit/e1c27dab4e6458b14068c438f69b9885bbfee344)、[1aac2d9](https://github.com/LIghtJUNction/MagicNet/commit/1aac2d9c4ca74fdbfee9c2223aec454e7c779888)、[913d662](https://github.com/LIghtJUNction/MagicNet/commit/913d66280ac55e1c868b330c33da6f9f29db8e05)，[PR #445](https://github.com/LIghtJUNction/MagicNet/pull/445)，合并 [3e2e604](https://github.com/LIghtJUNction/MagicNet/commit/3e2e604683ab9e0b5309a1b5ed2c4fc4fba7e2ce) |
| magicnet-android | main | 9 | [2d93733](https://github.com/LIghtJUNction/magicnet-android/commit/2d93733170d892d1370214483fbe380d202cc0e7)、[3a86022](https://github.com/LIghtJUNction/magicnet-android/commit/3a86022b3eaf3a6299fa19394e4b2f6eea28b1a8)、[af3930b](https://github.com/LIghtJUNction/magicnet-android/commit/af3930bd9860344688efa62684afdd7ba4ba25f5) |
| MagicNetRules | main | 3 | [693f1b0](https://github.com/LIghtJUNction/MagicNetRules/commit/693f1b08ffffe57aaa93058c9e58c362d2f3a3b1) |
| MagicSingBox | main | 1 | [f04f3d0](https://github.com/LIghtJUNction/MagicSingBox/commit/f04f3d0812b612e0b079209e18f6a4b55e6be158) |
| sing-box | testing（也是默认分支） | 11 | [57c00b5](https://github.com/LIghtJUNction/sing-box/commit/57c00b534308d42c8ea1cbb7ce4f473289f038bd)、[5604500](https://github.com/LIghtJUNction/sing-box/commit/5604500d0b894af3b6fbc3c48a4ee71c1ff0e167) |

主仓库新增的 release-plan composite、原 recipe-check composite，以及源码的 test-cache composite 也已检查。工作流检查覆盖事件、路径过滤、权限、表达式上下文、job 依赖、可复用输入输出、本地脚本路径及最近运行记录。GitHub 的 Actions 历史目录还可能保留已删除工作流的记录，本报告计数采用当前 Git tree 中的文件。

源码审计开始时，main 与主仓库固定 gitlink 都是 `b989227b140a7627edff8b60ad87655cb09ac2d0`。本轮源码改动涉及 CI 门禁、触发路径及 ADB 成功测试预算。最终源码固定点为 `af3930bd9860344688efa62684afdd7ba4ba25f5`，tree `60a573d8a4d7e349f70801edbf3b3882e8a9dd8a`；主仓库 gitlink 与构建、Android 可复用接口均使用该 SHA。显式 `source_ref=main` 仍可选取源码最新提交，解析后固定本次构建身份。

## 2. 已修复的问题

### 2.1 发布工作流在创建 job 之前被拒绝

主仓库 [c9a6323](https://github.com/LIghtJUNction/MagicNet/commit/c9a632341928a6d2d03a60709f075ee2abf62105) 将 `permissions.contents` 改成按事件选择 read/write 的表达式。GitHub 对该字段只接受静态权限值，因此 [42326404967](https://github.com/LIghtJUNction/MagicNet/actions/runs/42326404967) 在加载工作流时失败；同期 Recipe checks 仍成功，因为旧检查没有验证 Actions 语义。该约束见 [GitHub permissions 文档](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions)。

修复把条件放在 job 的 `if` 中：`plan_read` 处理 PR、build、verify，固定 `contents: read`；`plan_publish` 处理显式 publish，固定 `contents: write`。两者调用同一个 composite，避免版本规划出现两套实现。只有发布规划持久化 checkout 凭据。

`plan` 汇合结果时要求恰好一个规划成功、另一个正常跳过。构建、Android、资产验证和发布显式检查各自所需的成功结果，避免 GitHub 的 skipped 依赖沿链传播。公开发行必须同时具备 plan、build、android、verify 四项 success；失败、取消或异常跳过均不能公开 Release。GitHub 的依赖传播规则见 [needs 文档](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds)。

### 2.2 发布后 updater 与 README 会失去一致性

新的配方检查要求 README 的当前发行版本与根 `update.json` 一致，旧 `sync-index` 却只同步 updater 和说明。这会使一次稳定版发布后，下一次 recipe-check 失败。

现在同步从最新 main 的 Git tree 读取三个 README，只更新当前发行徽章、Published Android package 行、安装说明及英俄当前发行子句，并与 updater、发行说明一起提交。历史版本说明、并发文档编辑和源码 gitlink 保留。推送发生非快进冲突时重新读取最新 main；即使 updater 已经同步，重跑仍会补齐 README。更高版本/code 不会被回退；预发布只同步发行说明，稳定 updater 和 README 保持原始字节。

候选 release snapshot 的 updater 表示待构建目标，README 的稳定版说明仍来自触发提交。实际流程在生成候选快照前检查配方，公开成功后才更新 main 的已发布状态。

### 2.3 所有仓库补齐工作流语义检查

五个仓库均接入 actionlint 1.7.12，并自动枚举 `.github/workflows/*.yml`、`*.yaml`。工具来自固定官方归档，每次执行都验证 SHA-256：

`8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8`

来源：[官方归档](https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz)、[官方 checksums](https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_checksums.txt)。缓存只保存已校验归档，使用时重新校验；不接受任意二进制覆盖参数，也没有按错误类别忽略规则。已有 ShellCheck 和 Python 检查继续由各自代码门禁负责。

主仓库由 recipe-check 调用，源码由既有 CI infrastructure job 调用，规则和配置仓库接入原有验证 job，sing-box 新增 workflow-checks。实际故障注入确认，动态 permissions、不存在的 needs、空工作流目录均会失败。

sing-box 使用的 `ubuntu-26.04` 和 `xcode-27` 已列于 [GitHub 当前 runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。actionlint 1.7.12 对 Ubuntu 26.04 的标签目录较旧，因此只为该精确标签增加配置，没有禁用 runner 检查。

### 2.4 子模块路径触发遗漏

源码 `network-regression.yml` 原先只有 `src/MagicNet/.config/sing-box/**`。这个目录是 mode 160000 gitlink；只更新子模块提交时，Git 记录的是不带尾斜杠的路径。现在 push、PR 两处都增加精确 gitlink 项。六个固定子模块的相关路径过滤已逐项核对，install/uninstall 的 kamfw、rules-release 的 rules 与配置入口原本就有精确路径。修复后网络回归 [42328535683](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42328535683) 已成功。

### 2.5 规则仓库的清理触发条件

`MagicNetRules/clean-history.yml` 原先在修改自身并推送 main 时自动重写历史，且缺少 `expected_main` 时回退到当前 SHA。现在只允许手动触发，并要求显式填写已审阅的提交。此次添加 lint 的 helper 放在 `.github/`，避开该仓库 `scripts/**` 的自动规则发行触发范围；本轮 push 只产生 CI 运行。

### 2.6 sing-box 的 fork 构建与发行边界

删除了 lint/test 并发键中不存在的 `inputs.build`，以及 Linux artifact 名中未定义的 `matrix.legacy_go`。普通 fork push 保留实际 Linux/Android binary、Android library、Linux desktop 等无需发行证书的构建。DEB/RPM 打包与签名拆开；普通 fork CI 中，原始 binary 矩阵与 Linux 客户端的 artifact 增加 `-unsigned` 后缀；手动发行仍要求有效签名配置，缺失时明确失败。

GitHub Release 上传前增加精确的依赖状态核验：全部 10 个 needs 必须符合此次构建选择，所选为 success，未选为 skipped。缺失、失败、取消、异常跳过或空构建不能进入 checkout、artifact 下载、attestation 和上传步骤。Google Play 独立路径也会先验证所需签名配置。

Linux 包的 Release 事件直接使用 `github.event.release.tag_name`，通过环境变量传入并校验版本，不再从同提交的其他标签推断发行身份。Fury 上传整个 job 限于上游仓库，缺 token 或 HTTP 错误明确失败。Docker 镜像改为当前仓库的小写 GHCR 路径，只有实际推送的两个 job 获得 `packages: write`；Docker 和 Linux 发行触发仍是手动或 Release 事件。

### 2.7 完整质量门禁暴露的 ADB 测试误报

首次完整预览的生产构建流程进入质量门禁后，`test_successful_boot_still_works` 返回 1；Android 15 / KernelSU 独立验收成功。失败根因已在本地复现：成功与超时测试共用 1 秒预算，Bash 的整数 `SECONDS` 在 `wait-for-device` 后跨越秒边界，即使实际只经过 8–11 毫秒，也会在查询设备启动状态前耗尽预算。控制启动时点的无 trace 复现为 6/6 失败。

源码 af3930b 只改 `scripts/test-android-adb.py`：正常成功路径使用 5 秒预算，生产默认 300 秒及其脚本字节保持；新增相同 1.2 秒延迟在旧 1 秒预算失败、新 5 秒预算成功的对照。6 项测试由实现者和独立复核分别通过；秒边界成功检查复验 6/6 通过。原断连、超时 124、原始错误码 37、非法预算 64 等负例继续执行。主仓库同步 gitlink 与两个 reusable 引用后重新运行全部发布预览。

## 3. 逐文件检查表

本表的“通过”指当前文件的 Actions 语义、引用与条件审查通过。线上执行证据另列，避免把静态检查、旧提交成功和本轮成功混为一谈。

### MagicNet：2 份

| 文件 | 检查结果 | 运行证据 |
| --- | --- | --- |
| `recipes.yml` | 触发范围、只读权限、merge queue 和本地 action 有效；原 action 新增全部 workflow 语义检查。 | 最终候选 [42330605857](https://github.com/LIghtJUNction/MagicNet/actions/runs/42330605857) 与合并后 main [42333424597](https://github.com/LIghtJUNction/MagicNet/actions/runs/42333424597) 均成功。 |
| `release.yml` | 修复静态权限、规划汇合与严格发布依赖；完整的自定义版本/bump/构建/验收/Release 参数保留。 | 原预览 [42328103256](https://github.com/LIghtJUNction/MagicNet/actions/runs/42328103256) 通过规划与 Android，但因 ADB 测试预算失败；修复后 [42330606044](https://github.com/LIghtJUNction/MagicNet/actions/runs/42330606044) 完整预览全部成功，真实验证 v1.8.6 / 10614 与固定源码 af3930b。 |

### magicnet-android：9 份

| 文件 | 检查结果 | 执行证据 |
| --- | --- | --- |
| `exec.yml` | 固定 SHA、只读 reusable 输入、版本注入、质量条件与 artifact_id 输出有效。 | 最终 af3930b 的 [42330416074](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416074) 成功；模块 artifact `13557362435`，142,283,983 bytes。 |
| `android-kernelsu-acceptance.yml` | 固定源码、目标版本、harness 和严格最终 gate 有效。 | 主仓库 [42330606044](https://github.com/LIghtJUNction/MagicNet/actions/runs/42330606044) 已用 af3930b、v1.8.6 / 10614 实跑 Android 15 / KernelSU 与最终 Android gate，全部成功；证据 artifact `13557792885`。源码独立 [42330416075](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416075) 也全部成功，证据 artifact `13557474000`。 |
| `quality.yml` | 修复只检查自身的覆盖缺口；CI infrastructure 及最终 gate 的依赖保留。 | 最终 af3930b 的 [42330416104](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416104) 全部 7 个 job 成功，包含全量 lint 和最终 CI Quality Gate。 |
| `install-onboarding.yml` | 两个 job 的目录、脚本、kamfw 与浏览器依赖有效；精确匹配 kamfw gitlink。 | 最近成功 [42222163721](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42222163721)，该成功提交与当前文件 blob 一致。 |
| `network-regression-evidence.yml` | host core、WebUI、SDK AVD 的初始化、脚本和只读权限有效。 | 最终 af3930b 的 [42330415990](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330415990) 成功；WebUI、AVD storage、core memory 三组 evidence artifacts 均已上传。 |
| `network-regression.yml` | 已补配置 gitlink 精确路径，保留 offline probe、真实 DNS NAT 和仅手动的公网观察。 | 当前 [42328535683](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42328535683) 成功；push 不运行手动公网观察。 |
| `rules-release.yml` | 精确规则/config 路径、固定规则下载和完整性验证有效；此处是只读集成测试。 | 最近成功 [42222163638](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42222163638)，成功版本与当前 workflow blob 一致。 |
| `uninstall-farewell.yml` | kamfw、venv、Playwright、临时服务及路径有效。 | 最近成功 [42157478380](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42157478380)，成功版本与当前 workflow blob 一致。 |
| `webui-preview.yml` | 手动入口、WebUI 工作目录、npm 检查与 artifact 路径有效。 | 查询到的 171 条历史运行没有此入口记录；本轮只确认语法、引用和路径。 |

### MagicNetRules 与 MagicSingBox：4 份

| 仓库 / 文件 | 检查结果 | 执行证据 |
| --- | --- | --- |
| MagicNetRules / `ci.yml` | 新增全量 workflow 门禁，原编译、规则测试、干净目录检查保留。 | 本轮 [42328028522](https://github.com/LIghtJUNction/MagicNetRules/actions/runs/42328028522) 成功。 |
| MagicNetRules / `release.yml` | 路径、定时触发、构建后发布和权限有效。 | 最近可见定时 [42319614447](https://github.com/LIghtJUNction/MagicNetRules/actions/runs/42319614447) 成功；本轮没有触发发行。 |
| MagicNetRules / `clean-history.yml` | 修复自动触发与目标 SHA 回退，只允许明确的手动请求。 | 静态校验通过；本轮没有执行历史重写。 |
| MagicSingBox / `validate-config.yml` | 新增全量 workflow 门禁，保留配置生成与策略回归。 | 本轮 [42328041668](https://github.com/LIghtJUNction/MagicSingBox/actions/runs/42328041668) 成功。 |

### sing-box：11 份

该仓库本轮全部文件均通过 actionlint 与逐项代码审查，但 GitHub 暂停 fork 运行，以下条目均没有新提交的线上执行结果。

| 文件 | 结论 |
| --- | --- |
| `build.yml` | 修复 fork push 的签名依赖，保留真实构建；增加手动发行签名配置检查和精确 needs 结果门禁。 |
| `docker.yml` | 修复 GHCR 目标归属和最小 packages 写权限，保留手动/Release 触发。 |
| `lint.yml` | 删除未定义的 inputs.build，保留全部平台 lint 矩阵。 |
| `test.yml` | 删除未定义的 inputs.build，保留 Go/操作系统测试矩阵。 |
| `linux.yml` | 删除未定义的 legacy_go；版本绑定事件 tag；签名与 Fury 条件明确。 |
| `android-ebpf.yml` | 手动只读构建及 artifact 上传路径有效。 |
| `ebpf-verifier.yml` | PR/手动入口、验证脚本及失败日志保存有效。 |
| `inbound-benchmark.yml` | 输入、诊断保留及最终原始 outcome 检查有效；中间 continue-on-error 不会把最终失败改成成功。 |
| `kick-mirror.yml` | 当前仓库 workflow 调度与 testing 引用有效。 |
| `mirror-upstream-issues.yml` | 上游读取、当前仓库写入目标与权限匹配。 |
| `workflow-checks.yml` | 新增全仓库 workflow 检查，覆盖 GitHub 配置变更与手动验证。 |

## 4. 本轮实际验证

| 验证项目 | 结果与范围 |
| --- | --- |
| 主仓库 Actions 语义 | 当前 2 份通过；原动态权限表达式可以稳定复现失败。 |
| 最终候选计划 | 新 PR 预览的实际规划日志固定源码 af3930b，目标 v1.8.6 / 10614；稳定 updater 仍为 v1.8.4 / 10612。 |
| 发布与资产回归 | 37 项 release-plan、19 项 release、4 项 live-pin 测试全部通过。 |
| 发布后同步 | 临时真实 Git 仓库验证非快进冲突、并发 README/gitlink 保留、历史段落保留、部分同步恢复、同版重跑、预发布字节不变和版本不回退。同步后重新 clone，再执行 live-pin 校验通过。 |
| 配方完整性 | recipkg check、pack、归档再次 check、完整 build 提示词通过：8 包、61 个 Markdown 文件。 |
| 规划汇合 | 实际执行当前 shell 的 25 组状态组合，只放行 success/skipped 及其反向。GitHub PR 中只读规划成功，可写规划正常跳过，后续构建、Android 实际启动。 |
| 源码本地回归 | 第一批 125 项现有 CI/质量/Android/缓存相关测试通过；第二批路径修复的 46 项相关测试通过。 |
| ADB 预算回归 | 修复前秒边界 6/6 误报；修复后 6/6 成功；6 项测试及 1.2 秒受控延迟对照通过，生产脚本字节未改。 |
| MagicSingBox | 33 项原有测试、生成配置一致性及真实 CI 通过。 |
| sing-box 发行依赖 | 13 组有效分支/构建类型组合通过；231 个已选 job 状态异常、未选 job 意外成功及空构建反例被拒绝。代码另严格检查完整的 needs 键集合。 |
| sing-box 版本及签名 | 4 个合法事件标签通过、8 个非法标签拒绝；缺密钥时实际签名脚本在签名/上传前失败。 |

本轮没有执行真实软件公开发布、商店上传、Docker 发布、Fury 上传或历史清理。主仓库发布与重试逻辑使用隔离 Git 和假 GitHub API 回归；sing-box 本轮新增的版本选择、依赖结果门禁及 GPG/Google Play 配置缺失检查有动态测试。Fury、Docker、Apple/Windows 签名发行、历史重写与 Issue 镜像等入口只作语法和代码审查。实际模块构建、Android/KernelSU 模拟器和资产验证由主仓库完整预览提供证据。模拟器结果不等同于 Android arm64 真机或真实公网验收。

### 4.1 完整预览与合并的最终证据

[完整预览 42330606044](https://github.com/LIghtJUNction/MagicNet/actions/runs/42330606044) 的 7 个执行 job 全部成功；发布规划与公开发布两个 job 按 PR 条件正常跳过。`CI_TEST_FORCE=1` 强制执行完整质量检查；实际日志中 ADB 回归在 02:59:03 UTC 开始，02:59:07 UTC 通过（4.32 秒、退出码 0）。构建、模拟器和最终资产验证使用同一源码与目标版本。

最终资产校验输出：

```json
{
  "recipe_sha": "d2956b7e4e0b285a18e5907dd4cbda0c33d6eaa9",
  "source_sha": "af3930bd9860344688efa62684afdd7ba4ba25f5",
  "version": "v1.8.6",
  "version_code": "10614"
}
```

| 主仓库 artifact | ID | 大小 |
| --- | ---: | ---: |
| `magicnet-module-42330606044-1` | 13557459752 | 142,285,073 bytes |
| `android-kernelsu-acceptance-42330606044-1` | 13557792885 | 498,637 bytes |
| `magicnet-plan-42330606044-1` | 13556764184 | 406 bytes |

模块 artifact 容器的 SHA-256 为 `07584cdfac635804a3edef192ab08a44038463513b12939c30c47392a346e652`，下载时的摘要匹配；归档内部全部发布文件由 `scripts/release.py verify` 另行检查。读取时三个 artifact 均未过期，下载入口为上述 run 的 Artifacts 区域。

以精确 PR head `913d66280ac55e1c868b330c33da6f9f29db8e05` 合并后，功能修复提交为 `3e2e604683ab9e0b5309a1b5ed2c4fc4fba7e2ce`。该合并提交与实际受测的 PR merge 提交 `d2956b7e4e0b285a18e5907dd4cbda0c33d6eaa9` 的 tree 均为 `a9153c3032503e82cfd8db701bc4753a6efb3b36`；父提交也一致。随后只补充本报告与配方验收记录。

## 5. sing-box 的平台阻塞与恢复入口

在 [sing-box Actions 页面](https://github.com/LIghtJUNction/sing-box/actions) 直接观察到 GitHub 的提示：该 fork 因 Actions 使用规模而暂停工作流，需要仓库维护者重新启用。两个修复提交的 run 查询均为 0；交付前再次查询最终提交并刷新 Actions 页面，仍为 0 次运行且暂停提示仍存在。公开 REST 的 workflow state 仍显示 active，证明仅查看单份 workflow 状态不能排除仓库层面的暂停。

当前 GitHub 插件可以提交仓库文件，但没有恢复仓库 Actions 的设置接口；共享浏览器未登录，无法执行维护者操作。因此本轮能交付已提交且通过本地验证的全部修复，不能把 sing-box 的新构建报告为线上成功。

维护者在上述 Actions 页面恢复运行后，可先手动执行只读的 **Validate workflows** 检查。正常 testing push 会执行已修复的普通 CI 路径；手动 **Build** 仍含明确的发行选择，应按所需产物与签名配置使用。MagicNet 的统一发行入口位于主仓库，使用固定源码构建，不依赖该 fork 自身先发布二进制。

## 6. 交付前自检

| 复核维度 | 结论 |
| --- | --- |
| 问题是否解决 | 非法权限、遗漏语义门禁、发布后文档漂移、gitlink 触发遗漏、ADB 测试误报及关联发行配置缺陷均有具体提交与验证记录。 |
| 说明是否清晰 | 每份 workflow 有独立结果，当前状态、历史成功与静态审查分别列明。 |
| 证据是否支持结论 | 代码绑定提交，线上结果绑定 run；sing-box 暂停明确记为阻塞。 |
| 验证是否完整 | 全部现行 YAML 已检查；主仓库发布链路及关联仓库本轮新增的版本、状态和配置门禁有本地回归，其他有副作用入口完成静态审查。 |
| 设计是否保持约束 | 只读预览、严格发布门禁、固定源码、幂等恢复、稳定版本不回退及最终 ZIP 内容边界继续保留。 |
