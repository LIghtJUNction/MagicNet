# 工作流审计 · 2026-11-07

本轮检查五个仓库共26份现行workflow及相关composite，均通过actionlint1.7.12（归档SHA-256 `8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8`）。主仓库[PR #445](https://github.com/LIghtJUNction/MagicNet/pull/445)已合并；源码固定`af3930bd9860344688efa62684afdd7ba4ba25f5`，tree `60a573d8a4d7e349f70801edbf3b3882e8a9dd8a`。当次稳定版为v1.8.4/10612，未新建Release；当前版本见主README。

## 修复范围

| 范围 | 改动 |
| --- | --- |
| MagicNet | 非法动态permissions改为静态read/write规划job，共用composite；严格检查plan/build/Android/verify成功。稳定发布同步README/updater，保留历史、并发修改及gitlink，预发布不动稳定索引。 |
| magicnet-android | 全量workflow门禁；配置gitlink补精确触发路径；ADB成功夹具改5秒，保留1秒超时负例及生产300秒预算，受控1.2秒对照通过。 |
| MagicNetRules | [693f1b0](https://github.com/LIghtJUNction/MagicNetRules/commit/693f1b08ffffe57aaa93058c9e58c362d2f3a3b1)：全量lint；历史清理仅手动、必须填写已审阅expected_main。 |
| MagicSingBox | [f04f3d0](https://github.com/LIghtJUNction/MagicSingBox/commit/f04f3d0812b612e0b079209e18f6a4b55e6be158)：全量workflow检查及原配置回归。 |
| sing-box | [57c00b5](https://github.com/LIghtJUNction/sing-box/commit/57c00b534308d42c8ea1cbb7ce4f473289f038bd)、[5604500](https://github.com/LIghtJUNction/sing-box/commit/5604500d0b894af3b6fbc3c48a4ee71c1ff0e167)：删除未定义上下文；普通fork构建与签名发行分离，校验全部10个needs；发行版本绑定事件tag，Fury限上游，GHCR使用当前仓库及最小写权限。 |

actionlint使用[固定官方归档](https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz)和[官方摘要](https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_checksums.txt)，每次重验；只为已由[GitHub支持](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)的ubuntu-26.04补精确标签，保留runner检查。权限与依赖依据[permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions)、[needs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds)。

## 逐文件结果

以下分别标明静态审查、本轮执行和历史同blob运行，保留各自证据范围。

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

## 验证与交付

本地通过37项release-plan、19项release、4项live-pin；真实临时Git验证非快进重试、并发README/gitlink保留、部分同步恢复、预发布字节不变和版本不回退。八包/61 Markdown的check/pack/archive/build通过；规划汇合25状态组合仅放行成功/跳过配对。源码CI相关125项及路径46项回归通过；ADB六项和秒边界6/6通过。MagicSingBox33项通过；sing-box发行13合法组合通过、231异常组合拒绝，4合法tag接受、8非法tag拒绝，缺签名配置在上传前失败。

[最终预览42330606044](https://github.com/LIghtJUNction/MagicNet/actions/runs/42330606044)的7个执行job成功，发布相关两job按PR条件跳过；固定source af3930bd，目标v1.8.6/10614，CI_TEST_FORCE=1。ADB回归实际4.32秒通过。合并`3e2e604683ab9e0b5309a1b5ed2c4fc4fba7e2ce`与受测PR merge`d2956b7e4e0b285a18e5907dd4cbda0c33d6eaa9`同tree`a9153c3032503e82cfd8db701bc4753a6efb3b36`。

| artifact | ID | 字节数 |
| --- | ---: | ---: |
| 模块 | 13557459752 | 142285073 |
| Android验收 | 13557792885 | 498637 |
| 发布计划 | 13556764184 | 406 |

模块外层ZIP SHA-256 `07584cdfac635804a3edef192ab08a44038463513b12939c30c47392a346e652`；内部发行文件另经`scripts/release.py verify`检查。下载入口为上述run的Artifacts区域，保留时限按Actions元数据。

本轮未执行公开Release、商店/Docker/Fury上传或历史重写；发布恢复使用隔离Git和假GitHub API。Android证据属于模拟器；物理ARM64与真实公网另需验收。

## 当次平台阻塞

[sing-box Actions](https://github.com/LIghtJUNction/sing-box/actions)当时因fork使用规模暂停，两个修复提交均0次运行；单份workflow API的active状态未反映仓库暂停。需维护者在该页面恢复，再手动运行只读 **Validate workflows**。普通testing push执行修复后的CI，手动Build仍须选择产物并具备签名配置。MagicNet统一发行使用固定源码构建，不依赖fork先发布二进制。

[固定完整记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/docs/workflow-audit-2026-11-07.md)保留原失败运行、全部修复提交、测试明细和复核过程。现行发布操作见[releasing.md](releasing.md)。
