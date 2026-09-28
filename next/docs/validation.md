# 验证证据与边界

## 2026-09-29 推送前复查

本轮先核对 PR #355 最新头 `3f01e65a9aafb47e57369c501e606b8d8a907315`。它在此前 `056d99375c25fcdb70aa4001e0496e960d068983` 基础上，将 eCapture 与 Proxylink 一并纳入经校验的 x86_64 Android 验收载荷。随后使用该提交的 Source Snapshot 与 Rewrite Verification Kit 离线重放本增量；旧测试中把 eCapture/Proxylink 当作“未知外来 ELF”的假设已经移除，未知运行时 ELF 仍保持 fail-closed。

实际复查工具链：Rust/Cargo **1.98.1**、Node **22.16.0**、Python **3.13**、系统 Chromium。Rust 与前端依赖来自同一远端提交生成并经 SHA-256 校验的离线 verification kit；没有联网重新解析依赖。本地未重新执行 Android 交叉编译或启动 AVD。

本轮已完成的测试：

| 范围 | 结果 | 证据边界 |
| --- | --- | --- |
| kamfw / 业务引擎 Rust | 12 + 26 项通过 | 含事务故障注入、配置、模型状态，不是 Android 网络 |
| 实际 CLI 进程协议 | 12 项通过 | stdin、请求关联、只读回执、权限标记、输入限制 |
| 安装/升级 hooks | 15 项通过 | 宿主机文件和真实 CLI；拒绝未完成事务与运行中的来源 |
| 离线打包 | 9 项通过 | manifest、ELF/解释器、路径、私有文件、可重复输出 |
| 原生 supervisor | 10 项通过 | 实际进程、三秒清理、故障恢复和并发；子进程不操作网络 |
| 前端协议/回执 | 19 项通过 | malformed/未知结果、存储隐私、精确请求关联 |
| Chromium 页面/CLI 集成 | 14 项通过 | 四页、320/375/768/1440 像素；执行后丢回执不重发 |
| 生产 fake-curl 合同 | 8 项通过 | 实际脚本中的替身，FIFO/响应头/元数据/HTTP 错误 |
| Android 验收脚本合同 | 36 项通过 | 宿主机 archive/报告/设备前置条件测试，不是真实 AVD |

| Android 工作流接线合同 | 13 项通过 | 固定工具、缓存、生命周期步骤与失败门禁 |

合计 **174 项**。Rust fmt、Clippy（warnings 为错误）、构建、Vue 类型检查/构建、相关 ShellCheck 均单独检查。一次聚合运行被执行工具时限中断；随后分文件重跑，并最终独立执行完整发现命令，46 项在约 21.5 秒内全部通过。被中断那次不计通过。

新增的排队启动/STOP、禁用后的恢复、卸载标记后 action 三个回归先在修改前真实失败，再在修改后通过。回执集成测试让真实 CLI 完成写入后只损坏传回页面的结果，再从真实存储按请求编号读取结果；没有用固定成功对象代替后端。

页面测试离线加载构建产物，测试用 KernelSU 适配器把 SDK 请求交给宿主机 CLI。此方式不验证浏览器 CSP、Android WebView、KernelSU 实际权限或包安装。测试适配器不包含在发布 bundle 中。浏览器存储不可用时保留内存回执跟踪；持久存储只含请求编号和方法。

事务故障注入覆盖 Store 修改前后 48 个位置，不模拟所有磁盘断电语义。状态继续明确报告 `network_health: unknown`。测试中的节点和 URL 均为非私人夹具，不代表公网代理可用。

## 本轮尚未通过的生产检查

PR 头 `3f01e65` 的 Build Kam Module、Code Quality、Network Regression Evidence、Rewrite Verification、Rewrite Verification Kit 与 Source Snapshot 均通过。Android KernelSU Acceptance `36272742011` 的第二次尝试仍失败，但失败点已经不是 ELF 夹具：`simulation.json` 证明六个运行时载荷均已替换并记录 SHA-256，CLI 别名也记录了来源；随后 `environment` 阶段在约 307.6 秒后报 `RuntimeError: Android boot deadline exceeded`，其余 11 个生命周期阶段均为 `not_run`。

因此当前阻塞是“该次 x86_64 KernelSU AVD 未在截止时间内完成启动”，不能把它记成模块生命周期失败，也不能把宿主机通过当成 Android 验收通过。下一次 Android 运行仍需实际进入 KernelSU bootstrap、安装、冷启动、普通应用 UID TUN、错误配置回滚、停服清理、重复启动、升级保留、禁用/启用重启与卸载重启阶段；ARM64/OEM/Play-GMS/eBPF/IPv6 仍需独立证据。

生产 fake-curl 合同现在覆盖正文、响应头、write-out 元数据、FIFO、HTTP 非 2xx、参数消费与未知指标拒绝；对应 8 项合同测试通过。它验证测试替身没有吞掉真实下载器契约，不是公网订阅或真实网络验收。

旧运行中出现过 `unreplaced foreign ELF: cli`、eCapture/Proxylink ABI 不匹配、Node 探针解析等问题；这些属于不同提交的历史失败，不能继续作为 `3f01e65` 当前 Android 失败原因。

## 发布边界

本轮本地复查使用 `3f01e65` 同提交生成的远端快照与离线依赖，并重新执行 Rust、CLI/部署/worker、前端协议、Chromium UI、fake-curl 及 Android harness 合同。远端 Android AVD 失败仍保持失败，不因为宿主机回归通过而改写结论。

旧生产入口和测试保留，`cutover.json` 的 13 项仍未接受。完整切换须在同一最终提交上取得 Android 安装、升级、重启、停服/卸载恢复以及真实设备证据；提交到 PR 分支也不等于已合并、已发布或完成生产切换。
