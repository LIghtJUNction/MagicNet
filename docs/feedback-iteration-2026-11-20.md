# MagicNet 用户反馈迭代记录：2026-11-20

本轮已修正命名路由表的身份判断、停止前维护调度，并减少 DNS 安装的重复内核调用。手机候选重复 start 的三个样本中位数为 544 ms，但仍有慢样本；冷启动仍约 34–35 秒，一次订阅过滤更新成功仍耗 225 秒，都是需要继续处理的体验问题。原始样本与各层验证见[结构化证据](evidence/feedback-iteration-2026-11-20.json)。

验收期间的 27→25 节点变化可由已记录的 WebUI 过滤提交及刷新解释，保留当前过滤设置。共有节点 server 字段变化与这次来源更新相符，缺少前后原始响应，不能精确归因；测量期间有配置变化，前后观察不作严格同配置 A/B。三轮基线及一轮候选蜂窝重连均未复现 #436，真实 Wi-Fi 切换和规则丢失恢复仍待验证。

## 1. 把用户反馈转成可追踪验收

Issue 关闭只能证明该讨论已结束，不能代替当前实现的验收。尤其 #396、#337 等已转入配方的项目，本轮仍保留 pending；详细映射见 [FEEDBACK](../recipes/magicnet/FEEDBACK.md) 与 M22/M23/M26/M62/M66/M85–M87。

| 用户反馈 | 本轮处理与仍需验证的条件 |
| --- | --- |
| [#436 换网后应用断流](https://github.com/LIghtJUNction/MagicNet/issues/436) | 以同一普通应用 UID、内核规则与核心身份观察蜂窝数据断开重连；当前未复现，真实 Wi-Fi 切换和 OEM 触发原因仍待验证 |
| [#396 启停慢](https://github.com/LIghtJUNction/MagicNet/issues/396) | 留存冷/热调用基线和启动分段，减少已证明重复的工作；不把闭单或宿主测试时长当成手机提速 |
| [#336](https://github.com/LIghtJUNction/MagicNet/issues/336)、[#337 停服后的网络恢复](https://github.com/LIghtJUNction/MagicNet/issues/337) | 修正路由身份与停止调度；逐轮检查自有规则、普通应用直连和重新启动，完整五轮验收继续跟踪 |
| [#439](https://github.com/LIghtJUNction/MagicNet/issues/439)、[#437 订阅更新后的维护恢复](https://github.com/LIghtJUNction/MagicNet/issues/437) | 保留恢复集合与锁内复核；连续订阅更新后的真实维护进程及网络结果仍待验证 |
| [#426 多源订阅](https://github.com/LIghtJUNction/MagicNet/issues/426)、[#434 HTTP 403](https://github.com/LIghtJUNction/MagicNet/issues/434) | 沿用整批导入、逐源完整性与有界 UA 回退合同；原来源和设备条件下的结果不由其它成功样本代填 |
| [#393 热点耗时](https://github.com/LIghtJUNction/MagicNet/issues/393)、[#394 重复热点规则](https://github.com/LIghtJUNction/MagicNet/issues/394) | 分开核验规则幂等、等待耗时和真实下游回程；尚需第二台热点客户端及可用 IPv6 条件 |

Box for Root 的生命周期顺序用于核对 MagicNet 的行为要求：核心启动后安装透明规则，停止时先撤销透明规则再停核心。参考为官方 [taamarin/box_for_magisk](https://github.com/taamarin/box_for_magisk) 与相关实现 [boxproxy/box](https://github.com/boxproxy/box)。本轮没有同设备 BFR 对照，因此不评价两者的相对速度或可靠性；MagicNet 的模式范围继续是 tun/ebpf。

## 2. 本轮修复了什么

路由清理现在以数值表身份为依据，表名只用于展示。旧逻辑仅识别字面的 lookup 2022，会漏掉数值表 2022 的名称表示；另一张表若名为“2022”，也可能误导常规表参数解析。修复先保留完整 RPDB 快照，再用内核数值过滤核对完整规则与重复次数，只有身份明确的规则才进入原有所有权差集和精确删除。实现与回归固定于 [862239b](https://github.com/LIghtJUNction/magicnet-android/commit/862239b73b9caa863b9af6e04cb389042c30086b)。

旧状态迁移保持保守。prepared 基线必须带有 `rule_table_format=verified-2022`；旧 prepared 只可在核心确认停止且目标表无 TUN 路由时重建。active schema 2 保持兼容，旧版本未记录的规则不被追认为自有。首次删除前观测失败要求零清理写入；删除过程中再次观测失败则停止后续并保留 ledger，已完成的明确归属删除不回滚。契约见 [LIFE-011](../recipes/magicnet-network-runtime/LIFECYCLE_CONTRACT.md)。

DNS 安装只移除了同一事务内可证明重复的工作。新建成功的私有空链省去一次 flush；重建前已经完成自有跳转清理，完整规则写入后直接挂接，省去再次扫描三类跳转。每个受支持地址族，新建链少 4 次 xtables 调用，已有链重建少 3 次；已有链仍先 detach 再 flush，失败清理、跳转顺序和外部规则保护保持。实现固定于 [49d3c63](https://github.com/LIghtJUNction/magicnet-android/commit/49d3c63fabae19aec5cdcbc6033df4c0f113458d)，调用次数变化本身不等于实机耗时改善。

显式停止先完整读取三类维护进程身份，任一未知时不开始静止；身份明确后暂停会周期性提交 reconcile 的自有热点循环，再等待原配置锁。新增步骤不额外强杀正在执行的热点 reconcile；原有 connectivity/config-apply 事务协议保持。quiesce 或取锁失败后，恢复须先 try 同一把共享配置锁，再在 guard 内逐项核验核心/归属与原运行集合；锁忙或 I/O 未知时保留原错误并报告 restoration deferred，不创建新的后台恢复事务。

已运行核心的 start/ensure 使用保守快路，仍经过原 shell bootstrap。资格判断持有配置锁，必须确认精确自有核心存活，且停用/移除、恢复事务入口和 disruptive 请求均不存在；未知条件回原命令。bootstrap 后再次核对 disruptive：start 快路只做原幂等维护启动并保留 cgroup 脱离，ensure 快路不补启维护进程；ensure 拿不到 try-lock 时回原 shell，冷启动沿原路径。停止与快路实现固定于 [edf2d99](https://github.com/LIghtJUNction/magicnet-android/commit/edf2d9926e9a71000667596c9f80edd547e96363)，契约见 LIFE-012–014。

## 3. 同设备前后观察与启动分段

手机基线的模块元数据是 v1.9.1 / 10619，原始证据没有对当时安装文件组合声明单一源码提交。候选使用已核验的本轮 CLI 与两份脚本，模块元数据保持原值。验收期间还发生了过滤与活动节点变化，因此下表是同设备的前后观察，不构成严格同配置 A/B，也不能把差异全部归因于本轮代码。[测量证据](evidence/feedback-iteration-2026-11-20.json)

| 场景 | 基线样本（ms） | 候选样本（ms） | 同时观察到的事实 |
| --- | --- | --- | --- |
| 核心已运行，重复 start | 2844 / 5061 / 2488 | 2952 / 479 / 544 | 各三次成功，核心身份不变；中位数分别为 2844、544 ms |
| 核心已运行，ensure | 2538 | 373 / 313 / 2507 | 候选三次成功、核心身份不变；基线只有一次 |
| 显式 stop | 19698 / 15571 | 16342 / 16915 | 停止后两族 TUN 规则为 0；候选普通应用国内 HTTPS 200 为 331/258 ms |
| 停止后的 cold start | 37065 / 35712 | 34695 / 34193 | 候选仍约 34–35 秒；普通应用 Google/Cloudflare 严格 HTTPS 204 成功 |

重复 start 的三个候选样本中有两个明显较短，也有一次 2952 ms 的慢样本；ensure 同样保留了 2507 ms 的慢样本。各次慢路径尚未逐一归因，样本量和配置变化都限制了结论，不能称为稳定的因果提速。停止耗时仍落在基线波动范围内，冷启动也仍然偏慢。部署后的首次冷启动另为 34419 ms，单独记录，不并入上表两轮生命周期样本。

基线普通应用 UID 的 Google 探针四次为 373–528 ms，Cloudflare 采样为 436–720 ms；严格检查 204、无重定向和空响应体。两轮基线停止后的国内 HTTPS 200 与重新启动后的 Google 204 均通过；候选两站探针成功与命令耗时分别留证，不能用它们证明全部代理出口可用。[普通应用证据](evidence/feedback-iteration-2026-11-20.json)

一次独立的基线插桩启动耗时 38685 ms，其中 network-ready 为 6640 ms，core-launch 为 5810 ms。分段观察用于选择优化位置，不与未插桩的两轮冷启动样本混算；临时插桩随后按原字节恢复，恢复后普通应用 Google 严格 204 成功。network-ready 包含热点 reconcile、DNS capture、DNS leak guard 及可能的重试清理，本轮尚无这三项的对应分段 A/B，不能把总耗时变化分摊到其中一项。[分段证据](evidence/feedback-iteration-2026-11-20.json)

## 4. 蜂窝重连结果与 #436 的边界

三轮基线蜂窝数据断开重连后，分别在 5666、6382、6647 ms 的轮询窗口内观察到 Google 与 Cloudflare 两站严格 HTTPS 204 成功。候选额外执行的一轮在 6649 ms 内观察到同样的双站点成功；该轮前后核心身份不变，IPv4 与 IPv6 自有规则各 2 条保留，TUN route 均为 present、warning=false，health 退出 0。[重连证据](evidence/feedback-iteration-2026-11-20.json)

这些窗口包含轮询与探针时间，只表示何时观察到成功，不是准确恢复时延；候选轮后续读取状态的总耗时不混入 6649 ms。四轮都没有观察到 TUN 规则丢失，因此没有验证规则丢失后的自动恢复，#436 保持 NOT_REPRODUCED/open。场景是蜂窝数据关闭/开启，没有完成真实 Wi-Fi 切换；此前受控删规则试验的 NOT_VERIFIED 结论按历史保留。

## 5. 已完成验证与部署身份

宿主和隔离内核回归证明了相应分支行为，但不替代物理设备、真实热点客户端或长时间订阅更新结果。各组测试分别计数，未合并成全项目覆盖率。

| 验证层 | 已完成结果 | 证据范围 |
| --- | --- | --- |
| 路由所有权宿主回归 | 66 项通过 | 数值身份、同优先级外部资源、重复规则与失败路径 |
| BusyBox 路由专项 | 最终 66 项套件中的别名 8 项、旧基线迁移 1 项另行通过 | 同一用例的 ash 子集，不与 66 相加计算独立用例数 |
| 启动 ip 分派 | 6 项通过 | Android 入口分派约束 |
| 隔离 Linux 网络命名空间 | 通过 | 实际内核中的表身份与外部资源保留；不等同 Android 全流程 |
| DNS 顺序与故障回归 | 15 项通过 | 带状态 xtables、跳转顺序、失败清理、幂等与调用预算 |
| DNS 快路回归 | 6 项通过 | UID/mark、非 DNS 数据路径、模式与地址族边界 |
| Rust service 定向模块 | 44 项通过，1 项既有 Android mksh 专用 fixture ignored | 45 项定向模块；新增 9 项 quiesce 与 8 项 live-service 情况，不代表全项目 Rust 测试 |
| DNS shell 语法与差异空白 | 通过 | sh -n、git diff --check |
| 主仓辅助脚本 | 19 / 18 / 42 项通过 | 分别为 test-check-recipes.py、test-release.py、test-release-plan.py |
| Workflow / actionlint | check-workflows.sh 退出 0 | 工作流静态检查 |
| 完整配方闭包流程 | 集成 HEAD 上通过 | check → pack → archive check → build；8 个包、62 份 Markdown，固定源码与公开版本索引一致 |

当前维护源码固定为 `edf2d9926e9a71000667596c9f80edd547e96363`，tree 为 `694aa5b7a661c4e237c89762d12061c9062610fa`。ARM64 release CLI 为 2262512 字节，SHA-256 为 `424ab31f1d635b649d954866d1c1c5569aa8c4a30890085ff7c7e53c838583c2`。公开最新发行仍为 [v1.9.2 / 10620](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.9.2)，本轮没有据此改变公开更新索引。

候选采用 CLI 加 lifecycle/network 两份脚本的文件级替换。部署前对 48 份 shell/entrypoint 的兼容性核对中，45 份与当前源码一致，2 份差异正是目标脚本，customize.sh 安装后不保留符合预期；模块元数据继续是 v1.9.1。CLI 入口已确认是指向受管二进制的正确软链，入口与实际二进制的摘要均匹配本轮候选。文件级后测与完整模块安装验收分别记录，文件匹配数量不代替运行结果。

## 6. 订阅审计与仍未解决的耗时

节点数量变化已经对应到一条可核验的操作链。第 7 条新增持久过滤规则精确匹配此前的 2 个 VMess；记录中存在 `apply_subscription_filter` 的 WebUI 启动与成功退出，以及随后来源更新的抓取、转换、校验、激活阶段。当前 25 SS 符合该过滤配置，因此保留当前设置，不覆盖或绕过；这条记录证明操作路径，不能识别具体操作者。[脱敏审计](evidence/feedback-iteration-2026-11-20.json)

普通 start 的已有记录均走 cached skip。对实际 cached 分支另做三组隔离测试：原 27 节点加旧过滤、原 27 节点加新过滤、现 25 节点加新过滤，均退出 0、活动配置字节不变，也没有 replay/refresh。这个结果限定于被测试的缓存分支，不等于所有订阅或配置入口都没有写入；本轮未修改生产订阅与过滤策略。

共有 25 个标签的 server 字段变化与同次来源更新相符，其余节点参数相同。订阅 URL 内容未变但修改时间改变；由于未保存来源响应前后对照，不能进一步归因具体服务器变化。24 份未变文件仅属于 config/magicnet 与 env，不能扩展为全部订阅和活动配置未变。性能观察继续保留这一限制。

一次成功的过滤刷新总耗时为 225 秒，虽然处于现行 1200 秒预算内，仍是本轮未修的明显体验问题。该次处理 1 个来源，native 识别 48 项、导入 25 项、跳过 23 项；converter 尝试失败后由 native fallback 成功完成。08:18:49 至 08:21:03 的 134 秒是整个转换与原生回退阶段，包含解析和完整性检查，不能写成“converter 超时 134 秒”。

单来源 converter 只有一次 file 调用，默认名义预算为 12 秒加 1 秒 TERM 宽限。当前 `converter_result=failed` 合并了超时、进程退出、结构或数量校验失败，现有状态不足以确定这次失败的细分原因。源码存在重复 native 解析/校验成本，但这些完整性门用于防止部分导入，不能直接删除换取速度；下一步应增加有界子阶段计时和规范化失败原因，再优化重复工作。

## 7. 交付后的状态与下一轮验收

临时探针 APK 已成功卸载，随后确认包不存在；本轮创建的 7 个暂存/临时路径均已清理。最终快照中 core、overall readiness 与 dataplane readiness 均为 true，fswatch 为 running，TUN 为 present、warning=false，当前恢复计数为 0。三类维护进程 3/3 确认自有，应用 cgroup 内为 0，unknown/unavailable 均为 0；这些是本次结束时的观测，不作为长期运行保证。[收尾证据](evidence/feedback-iteration-2026-11-20.json)

下一轮优先分解并降低 225 秒订阅更新成本，同时保留原过滤意图与逐来源完整性。随后在冻结配置条件下重复冷/热调用和连续五轮启停；真实 Wi-Fi 切换、规则确实丢失后的恢复、第二台热点客户端、有效 IPv6 下游及连续订阅更新后的维护恢复仍独立待测。配方以 [M85–M87](../recipes/magicnet/ACCEPTANCE.md)、[LIFE-A17–A24](../recipes/magicnet-network-runtime/LIFECYCLE_CONTRACT.md) 跟踪，只有对应场景的新证据才能更新 pending。
