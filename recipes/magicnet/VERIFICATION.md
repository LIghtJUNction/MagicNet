# 实现与发行验证

本页保留可定位的结果与限制。历史结果只适用于各自提交、产物和环境；完整过程保存在[精简前的固定记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/recipes/magicnet/VERIFICATION.md)。

## 当前索引

| 对象 | 事实源 |
| --- | --- |
| 维护源码 | `e8b4bb76dcb54e5d242c20ffcebae96d588c98a8`；依赖身份见 [DEPENDENCIES.md](DEPENDENCIES.md) |
| 稳定发行索引 | 根 `update.json` 与 [README](../../README.md)：v1.8.5 / 10613 |
| 配方 | 0.3.20，八包；验收 M01–M68 见 [ACCEPTANCE.md](ACCEPTANCE.md) |
| 最近完整发布预览 | 2026-11-07，[42330606044](https://github.com/LIghtJUNction/MagicNet/actions/runs/42330606044)，对 af3930bd 注入 v1.8.6 / 10614；构建、完整质量、Android 与资产核验通过，公开发布按 PR 条件跳过 |
| 待完成工作 | [Issue 修复记录](ISSUE_TRIAGE_2026-11-06.md)：#436 现场规则消失根因与 #440 可信 NAS 入口；以下真机/公网边界继续保留 |

## 2026-11-09：#436 与模拟器故障回归

源码 [48efc93](https://github.com/LIghtJUNction/magicnet-android/commit/48efc93601ed1bb66871c1274034a372da2ffc06) 实现 CON-005、CON-A08–A09 和 M66：独立 TUN 观测、同一核心双确认、90 秒启动宽限、共享 300 秒冷却及每次开机最多 3 次恢复。Google/mixed_proxy 结果独立；未知、停止、事务、换代与损坏预算有拒绝路径。模拟器新增必选 `tun-route-recovery`，用自有规则删除和受控上联断续验证真实应用 UID 流量，并独立核验完整报告。

宿主完整 Rust 回归 916 项通过、1 项既有忽略；保留并合入同时到达的 ebb0b9d 后，重新通过 852 unit、9 connectivity_runtime、9 observation_state（共 870）及严格 Clippy/格式检查。Android 注入器/流程/接线 198 项、报告门禁 29 项、验收合同 33 项（共 260 项）及 workflow 语义检查通过；采集器到独立门禁的交叉校验通过。宿主夹具不算真实 Android 流量。

[17f1f59](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42635923874) 与 [7c8faf8](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42637788199) 的前 5 阶段通过，删规则时以 `invalid_rule_snapshot` 失败；原配置已恢复，自动恢复及后续 7 阶段未执行，报告门禁拒绝。后续修正只删除自有 lookup 规则、保留跳转锚点，并在 tick 前记录后台观测。

[e8b4bb7](https://github.com/LIghtJUNction/magicnet-android/commit/e8b4bb76dcb54e5d242c20ffcebae96d588c98a8) 复用首次正常停止/启动，证明核心动态辅助表的归属；故障保持该表不变，自动恢复后完整核验新旧表，其余非自有规则仍须一致。未知读取、空快照和旧表残留均拒绝；未禁用 auto_redirect。[新版 Android CI](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42644387012) 已排队，真实故障闭环待核验。

## 2026-11-09：前后端可用性与状态恢复

初始改动分三次提交：[08c2dea](https://github.com/LIghtJUNction/magicnet-android/commit/08c2deaab8106d46cb015942a61f1a0832be54b7) 修复异步前台操作恢复与订阅读取跟踪；[cd6055f](https://github.com/LIghtJUNction/magicnet-android/commit/cd6055f3605a53746a657fe8157fc0ac5de523f8) 修正未知运行状态和不完整命令；[ebb0b9d](https://github.com/LIghtJUNction/magicnet-android/commit/ebb0b9d98183effdb552be74ede7d81c1de4e3f0) 增加首页下一步建议、内置节点入口及订阅来源/设置的读取和并发门控。

最终 [0a175bc](https://github.com/LIghtJUNction/magicnet-android/commit/0a175bcb68bdd514f6db88f975193e4c73120126) 保留并行合入的 TUN 恢复实现，修复 Tailscale 私密读取结束后自动重读的真实循环。读取只由首次可用、显式刷新或配置 revision 变化驱动；在途变化合并一次补读。真实 Vue watcher 新增 5 项反例修复前失败、修复后通过，Tailscale 定向 54 项通过。根据 CI 窄屏截图，将首页下一步移至概览顶部，并加入完整首屏可见断言。

首页建议区分未读取、空来源、需要更新、可尝试启动；本地文件导入成功且远程缓存为零时仍提供启动检查。建议不把缓存数量当成有效节点数，不限制自定义完整配置的显式启动。服务状态未知时只读取状态。自动引导等到有效观测后出现，不因读取失败误判为新用户。订阅读取失败保留草稿，重试成功才恢复写入；任务占用、队列和未完成后台操作也阻止并发提交。

CLI 缺少 selector 参数返回可读用法错误，不再 panic。未知进程状态不做 toggle，缺失/损坏配置或事务日志保持 unknown；configured 与 effective 分开。机器接口继续使用 schema=1，未增加写 API。

宿主验证：回归修正后的 `npm run check` 通过，含 **390 项 WebUI 测试**、TypeScript 检查和生产构建；后端修复阶段（cd6055f）Rust 相关 **84 项通过、1 项既有环境用例忽略**，格式检查通过。忽略项依赖 AOSP mksh，不计为通过。完整前端构建仍提示主 chunk 超过 500 kB；本轮未测量启动速度、内存或续航，不据此宣称性能提升。

本地 Chromium 创建 socket 被宿主阻止，额外权限请求被自动拒绝；共享浏览器未能访问隔离服务，因此本地浏览器交互未记为通过。

初次 [浏览器 CI](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42630589799) 为 715 passed、84 failed、5 skipped；失败集中于 Tailscale 自循环和仍按旧语义查找启动按钮的用例，已修正代码与断言。0a175bc、ae8632d 与 17f1f59 的质量运行被后续 push 自动取消，不计为通过。17f1f59 的[网络证据 CI](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42635923842) 另有 312 项浏览器测试通过；该子集与后续完整套件重叠，不累计计数。

[7c8faf8 的完整六视口 WebUI 门禁](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42637788178/job/129230822352) 已实际运行 500.47s、exit=0 并成功；[网络回归](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42637788275) 成功，其中订阅/Tailscale/页面浏览器子集为 312 passed，不能与完整套件相加。7c8faf8 整体质量运行随后因并行提交取消，未结束的 shell 不计为通过。[该提交模块构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42637788405) 成功，已上传 artifact `13685705675`（142,307,045 字节）。

后继 a5c63c4 的[完整质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42639937728)和[网络回归](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42639937778)均为 attempt 1 success，含实际执行的 WebUI 全套及 312 项页面子集。e8b4bb7 继续只调整 Android 验收及文档，生产 Rust/WebUI 未变；其独立工作流结果另行记录。[较早 CI 快照](../../docs/evidence/usability-ci-2026-11-09.json)保留历史身份与当时状态。现有真机/公网验证边界继续保留。

## 2026-11-08：代码与文档精简

源码提交 [fb944a1](https://github.com/LIghtJUNction/magicnet-android/commit/fb944a10b15fd1f7e97182da1ac5078b6b226a69) 移除无引用组件、样式和重复展示逻辑；[351b7d7](https://github.com/LIghtJUNction/magicnet-android/commit/351b7d7189c057ba88c4da89092e5bc4124989d0) 合并 DNS、网络策略和连接列表处理。合计新增 54 行、删除 302 行，净减 248 行。主仓库 [e5da4a8](https://github.com/LIghtJUNction/MagicNet/commit/e5da4a83d40a28ed6f8461732af14c5ceb7d1ede) 删除已由 release-plan.py 接替的旧规划入口，保留现行资产验证和发布保护。

宿主验证：347 项 WebUI 测试、类型检查与生产构建；69 项 Rust 定向测试、构建与测试编译；132 个 CLI 新旧差分及 38 个颜色映射对照，全部通过。发布/资产/固定点 57 项检查、配方 check/pack/归档/build（8 包、61 Markdown）与主仓库工作流语义检查通过；第一批主仓库 [CI](https://github.com/LIghtJUNction/MagicNet/actions/runs/42494426303) 成功。未删除产品测试或降低验收要求；旧规划路径的三项重复测试由现行发布流程的等价检查覆盖。

Chromium 启动时创建 socket 被宿主拒绝，手机/桌面布局实测未进入页面；不能记为通过。本轮未做 Android 真机或新增性能测量，删行不构成运行时提速证据。当前源码与旧发行、旧完整预览分别保留提交身份。

## 已有验证与实际边界

- 配方检查覆盖目录、pack、归档再次 check、完整中文 build 提示词与 UTF-8 Markdown 闭包。它验证材料交付；实现是否满足合同须另跑验收。
- Android 15 / KernelSU / x86_64 已有 12 阶段、5 次重启、本地 TUN/应用控制、TLS 正负控制、升级/停止/禁用/卸载及单文件诊断证据。
- Google 正常产品 tick 的已记录结果为 TLS 失败，HTTP 204 未取得；告警与退避生效，未满足恢复门槛时没有订阅更新/核心重启。确切握手原因未知。
- 物理 ARM64 手机、用户真实订阅/代理出口、OEM/WebView、热点/IPv6/eBPF 数据面、移动网络切换、持续负载与续航尚缺完整验收；最低 Android/WebView 版本未知。
- 性能样本保留环境、输入与测量口径。宿主 GC 堆、CLI 峰值、短时回环和 Android 核心快照分别记录于 [PERFORMANCE.md](PERFORMANCE.md)，不合并为整模块或真机性能结论。
- 独立 Go/ES modules 候选与维护的 Rust/Vue 实现具有不同源码和冻结输入，验收结果不可互换；M40 之后新增合同未被旧候选完整覆盖。

## 2026-11-07：全部工作流与发布预览

[PR #445](https://github.com/LIghtJUNction/MagicNet/pull/445) 修正静态权限、严格依赖、README/updater 同步和所有工作流的 actionlint 门禁。源码 af3930bd 修复 ADB 成功测试的 1 秒预算误报；生产默认 300 秒和生产脚本保持，原失败反例仍执行。

| 对象 | 成功运行 |
| --- | --- |
| 主仓库完整预览 | [42330606044](https://github.com/LIghtJUNction/MagicNet/actions/runs/42330606044) |
| 源码质量 | [42330416104](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416104) |
| 源码构建 | [42330416074](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416074) |
| 网络证据 | [42330415990](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330415990) |
| Android 模拟器 | [42330416075](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416075) |

合并提交 `3e2e604683ab9e0b5309a1b5ed2c4fc4fba7e2ce` 与受测 PR merge `d2956b7e4e0b285a18e5907dd4cbda0c33d6eaa9` 的 tree 同为 `a9153c3032503e82cfd8db701bc4753a6efb3b36`。模块 artifact `13557459752` 为 142,285,073 字节，Android artifact 为 `13557792885`。

当时本地 37 项 release-plan、19 项资产、4 项 live-pin 及八包/61 Markdown 检查通过。五仓库 26 份 workflow 均通过语义检查；sing-box fork 的 Actions 当时暂停，缺本轮线上结果。[逐文件审计](../../docs/workflow-audit-2026-11-07.md)保留范围、运行与恢复入口。11-07 报告中的 v1.8.4 是当时稳定版，当前索引见上表。

## 2026-11-06：DNS 默认出口

源码 `38c6eea6a42eb5f2cc3697c81225f35fd3c82d5c`、模板 `ba5793b41fd06704102116fe2536eef5988f2905`，配置摘要 `e269e2303cf1e23d3b4ce69dcb7cca39f0f53dc647c5d03aace4c4bd7f986be0`。未知域名经代理 DoH，节点域名直连引导，显式 resolver/独立配置保留；代理拒绝时没有直连业务回退。

最终[质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346672)、[网络证据](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346632)、[构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346674)通过。真实固定核心的 A/AAAA × UDP/TCP、本地 TLS DoH/CONNECT 和无直连回退验证通过，公共 DNS 请求为零。完整 ARM64 包 68,480,032 字节，SHA-256 `1fdc0caa0c2d412562bc44058b8527210ebad6df75dbc0fcc17d1eba44bab234`；完成归档核验，ARM64 执行未测。

[Android 42187346630](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346630) 首次 cold-boot 本地 TLS 正控制失败，确切原因未保存；同源码第二次 12/12 阶段、5/5 重启通过。curl 重建摘要有变化，保留两次身份；Google 仍 TLS 失败。详见 [DNS 修复](DNS_REPAIR_2026-11-06.md)及[原始 CI 记录](../../docs/evidence/dns-repair-ci-2026-11-06.json)。

## 2026-11-06：低频联网、HTTPS 组件与诊断

最终源码 `ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9`；[质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653819)、[构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653787)、[Android](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653691)和[网络证据](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653682)通过。真实归档核验 14 ZIP、1,104 成员、10 组件/168 文件、17 摘要、12 pins 和 9 ARM64 ELF 路径，测试开发目录为零。

无系统 curl 的模拟器实际使用包内执行器；本地 TLS 正负控制、gzip、12 阶段和5次重启通过。一次正常 tick 得到 `tls_failure`、`warning=true`、60 秒退避；辅助目标与直连对照也失败，恢复动作保持 none。诊断 64,649 字节、48 节，采集 764ms，0 incomplete/0 truncated；导出前后探测次数为 1。

完整包 68,476,029 字节，SHA-256 `8dc73eb02ed508b772ed55618fa835ef869906ec8f3ae326e594fc94a0fd4d63`；[模块下载](https://drive.google.com/file/d/1b0qGXu15kLS01dFjhhF74_tqphRmYaAt/view?usp=drivesdk)、[实际诊断样本](https://drive.google.com/file/d/1e_Cj7QrqJmOCjXNzWdDhxRrKH5bsdaoJ/view?usp=drivesdk)。[专题报告](../../docs/connectivity-diagnostics-2026-11-06.md)保留合同参数、测量、复现命令与失败边界；[host](../../docs/evidence/connectivity-diagnostics-host-2026-11-06.json)/[CI 原始记录](../../docs/evidence/connectivity-diagnostics-ci-2026-11-06.json)保留全部候选身份。旧 d22/b5/218 失败候选未作为最终包交付。

## 历史证据索引

| 日期 / 范围 | 结果与来源 |
| --- | --- |
| 11-06 Issue 集成 | `8ff12428` 七条 CI 均 attempt 1 成功，Android 12/12、5/5 与本地 TLS 通过；Google 204 未取得。[ISSUE_TRIAGE](ISSUE_TRIAGE_2026-11-06.md)保存 #437–439 关闭与 #436/#440 未完范围。 |
| 11-06 跨仓库发布 | 主仓库 [#443](https://github.com/LIghtJUNction/MagicNet/pull/443)、源码 [#4](https://github.com/LIghtJUNction/magicnet-android/pull/4)合入；v1.8.6/10614 预览全门禁通过，未公开该版本。[迁移报告](../../docs/ci-release-migration-2026-11-06.md)。 |
| 11-06 跨层重写 | 全量对照绑定 `d58dbdc5ed8a43bc1fee5050187b529a0f7136b7`，最终整合另做定向复验；[源码报告](https://github.com/LIghtJUNction/magicnet-android/blob/f7188cc1f1184e5b5ac8da2d24b2dabeb42503ea/docs/rewrite-verification-2026-11-06.md)区分保留算法、修正缺陷与资源样本。 |
| 11-06 目录、锁、原生 TUN | `fafd08c3` 宿主回归和核心配置通过；完整模板因缺 SRS 有未过项，未部署设备。[运行时报告](../../docs/runtime-repairs-2026-11-06.md)。 |
| 11-06 教育与 Voice 规则 | 教育模板 `6b5f68a` 及消费源码 `cb7f63b` 有配置/集成 CI；Voice 清理 `76a0e69` 保留普通 ChatGPT 分流。来源与完整次序见 [POLICY_INVENTORY](../magicnet-routing-policy/POLICY_INVENTORY.md)。 |
| 11-06 kamfw 启动器 | `44f3c69f` 使用固定 kamfw/launcher.sh；删除重复 lib/kamfw-web，保留浏览器回退和错误传播。 |
| 11-05 指定拒绝目标 | `c75583b`、模板 `6da3994` 的七条源码 CI 通过；本地 PID namespace 失败与可选跳过保留在固定历史记录。 |
| 11-03 v1.8.4 | [41570680957](https://github.com/LIghtJUNction/MagicNet/actions/runs/41570680957)成功并公开[发行](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.4)，source `d22086d2`，19 附件；默认 UA 403 单次回退与 MCP 隐私修复，#434 真机复测另需证据。 |
| 11-03 UDP/安装清理 | `d0b1422d`，32,768 客户端 GC 后宿主保留堆由 3,149,632–3,186,872 B 降至 736–27,416 B（各3次）；零分配缓存命中，未宣称吞吐提升。安装成功/恢复/未知目录保护回归通过，无手机 RSS。 |
| 11-01 v1.8.2 | 旧 changelog 元数据导致首次发布阻断；`689bd614` 修复后 [41299804577](https://github.com/LIghtJUNction/MagicNet/actions/runs/41299804577)全部门禁成功，19 公开附件本地核验通过。[v1.8.2](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.2)；#426 由维护者关闭，现场根因未证实。 |
| 10-30 核心同步 | source `396d71df` / core `ff669d45`：宿主测试、Linux/Android 构建、真实回环 DNS 通过；默认测试明确排除 13 个环境用例。10,000 ACK 路径 GC 后堆减少 1,120,000 B。[完整报告](https://github.com/LIghtJUNction/sing-box/blob/ff669d45e6562a790a49ef066340dbed5df46363/SPECS/TASKS/051-UPSTREAM_MERGE_235/IMPLEMENTATION_REPORT.md)。 |
| 10-30 UI 与生命周期 | `fd0e2dab` 手机导航、`b113f512` 留白及 `72b6e8fc` 进程交接/PID/日志优化保留；宿主/浏览器结果见固定历史与 PERFORMANCE，真机 WebView 未测。 |
| 10-29 独立候选 | [b22f9f28 验证](https://github.com/LIghtJUNction/magicnet-android/blob/b22f9f280ddaf729da47078c13838a73e6d89294/VERIFICATION.md)记录 Go/ES modules 实现，输入8包/53 Markdown；缺外部 converter、M40 后续发行合同及真实设备验收。目录晋升/回执/恢复/草稿反例纳入现行合同。 |
| 10-29 v1.8.1 | source `a5617d63`、tag `b762b8c5`；构建/质量/Android 门禁通过，草稿恢复核对原19附件后公开。[v1.8.1](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.1)。 |
| 10-28–29 迁移与 v1.8.0 | 原 `f13ca61b` 与导入 `0dca28dd` 完整 tree 相同；保留原历史与固定子模块。Rust 808 passed/1 ignored、WebUI 338 项、浏览器747 passed/3 skipped及模块构建通过；无真机部署。[PROVENANCE](PROVENANCE.md)。 |

历史失败、跳过、临时环境阻塞、精确命令和全部源链接继续保存在本页开头的固定原文，原始 JSON 与发布说明保留。新的验证只追加与本次改动直接有关的结果，避免复述上述记录。

## 本地复现入口

```sh
python3 scripts/check-recipes.py
python3 scripts/test-release.py
python3 scripts/test-release-plan.py
python3 scripts/test-check-recipes.py
bash scripts/check-workflows.sh
```

实现测试进入固定源码仓库，遵守其工具链和对应专题中的命令。实网、模拟器和物理设备测试按各自前提执行，分别记录结果。
