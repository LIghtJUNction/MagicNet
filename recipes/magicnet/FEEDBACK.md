# 用户走查与 Issue 反馈

日期：2026-10-28。此文件把可复用的用户需求与验收证据带入重建配方；它不表示旧实现已修复或新实现已通过验收。

## 走查范围与结果

- 目标产品：来源源码 MagicNet v1.7.2，提交 `96993ea5c851b8d51cc562c3ca0766a2ca571210`；意向重建平台为 Android root / arm64。
- 设备只读观察：LG LM-G820、Android 14/API 34 上安装模块报告 v1.1.21，核心进程当时存在。它与来源源码版本不匹配，不能作为当前配方实现的验收对象。
- 走查任务 A（首次使用者）：从安装后打开控制页、配置常用分流并确认实际应用流量出口。**受阻**：无法在连接设备上执行该流程；只读调用 `cli --json capabilities` 返回旧版不支持该命令，随后设备断开。没有修改配置或运行状态。
- 走查任务 B（熟练用户）：在启用代理时检查核心、透明模式与热点客户端的真实数据路径。**受阻**：设备断开前未取得分层状态和客户端侧证据；核心进程存在不能证明业务可用。
- 本轮未把静态页面、源码阅读或既有测试结果冒充真实用户任务完成。新实现尚未生成；界面操作、Android root 管理器差异、热点客户端和实际网络结果仍待重建后走查。

## Issue 搜索范围

于 2026-10-28 查询 MagicNet 仓库的 19 条打开 Issue，阅读正文与可取得的维护者结论。只查本项目：这些反馈直接针对 MagicNet 用户、模块行为和已有验收边界；没有把相关项目的普遍建议误当成本项目事实。Issue 是报告来源，除明确复现记录外，不代表本次设备复现。公开原始日志、设备身份和敏感配置不复制到配方。

| 需求 | 来源与证据状态 | 配方要求及验收 |
| --- | --- | --- |
| 用户能直接理解路由名称，按应用和域名设置出口；常用动作不要求编辑 sing-box 原始 JSON | [#413](https://github.com/LIghtJUNction/MagicNet/issues/413) 用户反馈；其后 PR #421 只覆盖可读代理组入口，任意应用/域名编辑及新建组尚未实现 | M18、UI 11：提供中文名称与原始 tag 搜索，应用/域名规则及自定义组/出口的结构化编辑、预览、校验和安全回滚；来源订阅配置不得被静默覆盖 |
| 热点 reconcile 持锁时，用户的 no-op 启动不能因固定短超时误报失败；长操作要有可见进度和可恢复结果 | [#417](https://github.com/LIghtJUNction/MagicNet/issues/417)、[#398](https://github.com/LIghtJUNction/MagicNet/issues/398)；PR #423 已合并，本轮组合源码主机回归通过，设备验收仍未完成 | M19、M20、UI 12：周期 reconcile 争锁失败时无副作用地跳过；前台启停有界等待、阶段/耗时/busy 信息与明确重试；超时不释放仍运行任务的所有权，不展示旧状态为新结果 |
| 安装状态迁移不能靠两份独立手写清单，遗漏时静默成功 | [#418](https://github.com/LIghtJUNction/MagicNet/issues/418)；PR #422 已合并，本轮组合源码安装 fixture 回归通过，真机验收仍未完成 | M21、交付 11：单一迁移清单和显式排除项；备份/恢复不一致、复制失败或遗漏必须可见失败并保留可恢复状态；配置模板重建例外要单独声明 |
| 停核必须等自有核心完成清理，且只能移除本模块拥有的规则与资源 | [#336](https://github.com/LIghtJUNction/MagicNet/issues/336)、[#337](https://github.com/LIghtJUNction/MagicNet/issues/337)。#336 留有 v1.7.2 三轮恢复记录；#337 仍要求额外的设备验收 | M22、运行时 11：至少五轮启动/停止；停后核对原生网络恢复、TUN 或 eBPF 自有资源已清理；未知归属不得强杀或删除；不能把旧 TPROXY 方案带回新模式 |
| `route_status=ready` 不足以证明热点客户端回程可用；IPv6 条件要真实成立 | [#389](https://github.com/LIghtJUNction/MagicNet/issues/389) 后续客户端测试未复现原故障；[#335](https://github.com/LIghtJUNction/MagicNet/issues/335) 的后续客户端没有全局 IPv6，原 IPv6 路径未被触发 | M23、运行时 12、引擎 9：真实热点客户端完成 TCP/UDP 与返回路径检查；IPv4/IPv6 分开记录；没有全局 IPv6 时标为未覆盖，不可报通过；模式仍只允许 tun|ebpf |
| Google Play/GMS 的应用 DNS/网络结果必须用真实应用与 OEM 策略验证，不能用 root curl 或健康状态代替 | [#253](https://github.com/LIghtJUNction/MagicNet/issues/253)、[#329](https://github.com/LIghtJUNction/MagicNet/issues/329)、[#305](https://github.com/LIghtJUNction/MagicNet/issues/305)。#253 已有特定包 direct 对照；#329 跨 OEM 长期行为仍未知；#305 本身缺独立复现细节 | M24、运行时 13：覆盖 Play、GMS、GSF 的真实解析和应用流量；区分代理出口失败、UID/DNS 限制及系统策略；直连例外只能来自有证据的窄范围选择，不能全局绕过 |
| Tailscale discovery 成功不等于设备数据通道成功 | [#381](https://github.com/LIghtJUNction/MagicNet/issues/381)；报告跨核心/设备结果不一，根因未知 | M25、运行时 14：分别验证 DISCO、TSMP/ICMP 和实际 Tailnet 应用连接；记录核心版本和模式；只证明发现成功时结果保持 partial/unknown |
| 启动的进程创建开销和公网稳定性需要可比较的真实基线 | [#396](https://github.com/LIghtJUNction/MagicNet/issues/396) 有 v1.6.2 约 2473 个 exec 事件/35–37 秒报告及 v1.7.2 更慢但带本地改动的样本；[#377](https://github.com/LIghtJUNction/MagicNet/issues/377) 的公网长期验收明确未完成；[#398](https://github.com/LIghtJUNction/MagicNet/issues/398) 还列出重复扫描和冷启动成本 | M26、性能 6：固定设备、核心、配置、测量窗口和观测器开销；分别报告启动分段时间、exec 次数、空闲重复扫描和不少于 600 秒公网 soak；预算仍未知，不能把不同环境样本拼成优化结论 |
| 配置激活失败后必须有独立有效的 last-known-good 恢复基线 | [#254](https://github.com/LIghtJUNction/MagicNet/issues/254)；后续 PR #256/#403 修复部分恢复路径，原始设备故障因果仍未完全证明 | M27、运行时 15：损坏活动配置不能成为唯一回滚基线；已验证备份可恢复，备份缺失/损坏时拒绝继续并保留 journal；恢复中断可重试 |
| 订阅超时和核心启动错误要给出可恢复下一步，不能泄漏原始响应/私密字段 | [#331](https://github.com/LIghtJUNction/MagicNet/issues/331) 与 [#324](https://github.com/LIghtJUNction/MagicNet/issues/324) 是低信息量用户报告；维护者确认 #331 的下载器修复未证明原订阅超时已消失，#324 根因未定位 | M28、控制面 9：把下载/解析/校验/启动阶段分开报告；超时可重试且不产生第二个 owner；未知根因保留为 unknown，不写成已修复 |
| sing-box 新 TUN stack 与模块热点回程、DNS、IPv4/IPv6 的组合需要整体评估 | [#261](https://github.com/LIghtJUNction/MagicNet/issues/261)；维护者更新指出当前固定 fork 已包含 Go stack 基础，但配置仍锁在 mixed，尚无新 stack 真机 A/B | M29、引擎 10：以锁定核心为准比较 mixed 与 Go/default stack；完整跑热点回程、DNS、应用策略、IPv4/IPv6、长连接、RSS/CPU/延迟；通过前不改生产默认。stack 类型不等同 tun|ebpf 模式 |

## 仓库治理反馈

[Issue #281](https://github.com/LIghtJUNction/MagicNet/issues/281) 讨论的是 GitHub `main` 保护规则，不是 MagicNet 运行时功能。较早推送因 PR/审批/必需检查流程被拒；用户随后解除合并限制，本轮回读 main 的活动规则为空，并授权直接合并。它不进入产品配方验收，也不能把一次拒绝当作规则所有负向条件均已验收。

## 结论边界

Issue 需求已经转录为未来重建的可验收行为。Issue 关闭代表“需求已迁入配方”，不代表旧实现问题已修复、相关 PR 已合并、设备验收已通过或公网稳定性已确认。闭环证据仍须写入 `VERIFICATION.md`；M18–M29 均未在新实现执行。
