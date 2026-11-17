# MagicNet v1.9.0 改进与验证记录

记录日期：2026-11-18（UTC+8）。本轮处理日常界面复杂、错误说明难懂，以及代理核心退出后可能遗留网络拦截规则的问题。

## 当前结果

实现已分两次提交并进入源码仓库 main。目标版本为 v1.9.0；截至本记录编写，正式发布尚未触发，公开稳定索引仍为 v1.8.9 / 10617。下文分别记录本地验证、当前 CI 和仍待完成的发行步骤。

| 身份 | 固定值 |
| --- | --- |
| 网络修复提交 | [`8cb0a06152d70ed24405cfe5f0232e4871fcfb94`](https://github.com/LIghtJUNction/magicnet-android/commit/8cb0a06152d70ed24405cfe5f0232e4871fcfb94) |
| 界面改造及最终源码 | [`1e91457e5a04d96fc0604728a512333477a63376`](https://github.com/LIghtJUNction/magicnet-android/commit/1e91457e5a04d96fc0604728a512333477a63376) |
| 最终源码 tree | `ebc376174a91ece21ff73a53e81af924c1a7b81d` |
| 配方版本 | magicnet 0.3.27、web-console 0.2.10、network-runtime 0.1.15 |
| 目标发行 | v1.9.0；Android versionCode 由正式发布计划确定 |

## 日常操作改进

桌面侧栏和手机底栏把概览、节点、订阅、应用放在固定位置。手机第五项“更多”及桌面“更多功能”提供另外十页；全部十四页、深链接、快速跳转和浏览历史继续可用。删除重复的顶部分区导航，也删除再次点击当前分区才弹出页面清单的隐藏操作。

概览首先回答服务是否运行、当前出现什么问题、下一步能做什么。启动或停止、刷新状态、检查网络、订阅与选节点直接可见。进程、综合服务检查、实际模式与 RSS 收进“运行详情”；TUN/eBPF、热点、Wi-Fi 和维护操作收进“网络设置”。两部分默认折叠，重启位于服务管理并继续使用原确认流程。

首页装饰性流量星图及其专用代码已移除。独立流量路径页继续提供静态说明；实时状态由运行详情和诊断展示，示意图本身不能证明联网。关键错误、未就绪、首次设置下一步和任务状态保留在折叠区域之外。内部标记 `recorded` 改为三语可理解的网络操作错误提示，无法读取代理模式时明确提示刷新或打开诊断。

保留浅色和深色主题、中英俄文本、表单草稿、键盘焦点恢复与操作确认。顶部工具入口使用齿轮，手机底部“更多”使用省略号。未增加前端依赖，也未改变设备命令或机器状态协议。

## 已复现的断网机制与修复

代理核心退出后，本地 DNS 监听端口也随之关闭。旧监控分支仅记录 `paused/core_stopped` 并返回，可能让仍然指向该端口的 DNS 转发规则继续生效。此时应用发出 DNS 请求，却被转发到没有进程接收的位置。新增回归在旧实现上能复现未清理问题。

新版复用正常停止流程清理 MagicNet 自有 DNS 捕获、防泄漏、路由和热点资源。清理先取得现有生命周期互斥锁，重新确认核心确实停止，再进入与 shell 启动共用的配置锁；锁内再次检查，防止误清理正在启动的替代核心。锁等待保持 2 秒，总执行预算为 45 秒。实现见 [connectivity.rs](https://github.com/LIghtJUNction/magicnet-android/blob/1e91457e5a04d96fc0604728a512333477a63376/crates/magicnet-cli/src/connectivity.rs)，维护说明见 [connectivity-diagnostics.md](https://github.com/LIghtJUNction/magicnet-android/blob/1e91457e5a04d96fc0604728a512333477a63376/docs/connectivity-diagnostics.md)。

核心活跃、状态未知、配置禁用、任务取消或锁忙时不执行清理。失败保留 `connectivity.cleanup_failed` 证据，并在后续本地 watchdog 检查重试。此路径保持用户配置与节点选择，不自动启动核心，不更新订阅，不附加公网探测。成功清理仍记录核心已停止，不把它标记成互联网在线。外部规则依靠原有 ownership 边界保留。

这修复了一条已复现的持续断网路径。用户原始偶发断网没有对应的现场日志或物理手机复现，不能据此断言所有换网、运营商、节点和 OEM 网络问题均已解决。

## 本地验证

| 范围 | 实际结果 | 边界 |
| --- | --- | --- |
| Rust workspace，全部 target / feature，锁定依赖 | 948 passed，0 failed，1 ignored | 875 单元与 73 集成；ignored 是既有 AOSP Android-profile mksh 专用环境用例 |
| connectivity runtime | 14 / 14 通过，包含 5 项新增回归 | 已包含在 Rust 总数内；覆盖核心退出、两道锁、失败重试、未知状态及替代核心 |
| 自有网络资源清理 | sh 59 / 59、bash 59 / 59 通过 | 同一组场景用两种 shell 执行，覆盖重复清理和外部规则保留 |
| DNS 捕获与启动安全 | DNS fastpath 6 / 6，startup safety 通过 | 宿主夹具，不是用户手机 |
| WebUI 单元、类型与生产构建 | 388 / 388、vue-tsc、Vite build 通过 | 删除装饰专用测试，保留并迁移原导航、状态和输入安全断言 |
| 固定代码浏览器验收 | 63 passed，1 skipped，0 failed | 320×740、390×844、844×390、1280×900；桌面跳过手机软键盘场景 |
| 最终错误提示文字修订 | 相关 18 项单测及 phone-390 单条 E2E 通过 | 仅三语文字及对应断言变化；与前述数量重叠，不累计 |
| 主仓发行与固定值回归 | 79 / 79 通过 | 发布脚本 18、发布计划 42、配方检查回归 19 |
| 静态质量 | Rust fmt、严格 Clippy、ShellCheck、source lint、actionlint、diff 检查通过 | 未放宽现有检查规则 |
| 配方闭包 | check、pack、归档 check、完整提示词生成通过，8 包 / 62 Markdown | 集成快照 `7eefc939` 的整仓 source pin 检查通过，精确固定 `1e91457e`，稳定索引保持 v1.8.9 / 10617 |

浏览器使用官方 Chrome for Testing 157.0.8103.78。项目 Playwright 固定浏览器的本地下载未取得有效归档，因此通过已有的浏览器路径参数运行，项目依赖与锁文件保持原样。浏览器验收包含十四页双主题布局、三语、未知及失败状态、四项直达与次级页面、模式切换确认、草稿、缩放和滚动。首次验收发现折叠区域隐藏模式错误，已修复并在固定代码回归通过。

浅色、深色各一张手机和桌面预览已目视检查。截图由明确标记的只读模拟桥接状态生成，使用模拟服务就绪、TUN 和 HTTPS 延迟；未在设备上执行命令，不能作为物理手机联网或 v1.9.0 已安装的证据。

## 当前 CI 与发行

以下运行均对应最终源码 `1e91457e`，不是历史提交的结果。创建本记录时均在执行，尚未记为通过：

- [Code Quality 44136054407](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44136054407)
- [Build 44136054360](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44136054360)
- [Android KernelSU Acceptance 44136054256](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44136054256)
- [Network Regression Evidence 44136054354](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44136054354)

正式发布使用主仓既有 [Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml)，分支 main，`mode=publish`、`bump=none`、`version=1.9.0`，保持 `source_ref` 为空并使用已审查的 gitlink。源码构建、完整质量、Android 生命周期与网络恢复、安装包来源和资产清单核验通过后才可公开发行，再同步稳定更新索引。

目前 GitHub 插件能提交源码和读取 CI，但没有手动触发 workflow 的操作；备用浏览器未登录 GitHub，ssmcp 连接需要重新认证。主仓集成快照 `7eefc939` 已完成最终配方检查；发行触发仍需要恢复其中一个可用的已登录发布通道。发布门禁、触发条件和权限规则保持原样。

## 后续验收边界

本轮本地验证不替代最终发布工作流，也不替代用户物理手机上的升级和换网行为。正式发行后应记录实际 release URL、版本号、源码身份、工作流结论及公开安装包核验结果。若用户设备仍然断网，应在故障当时通过诊断保留核心、DNS、路由和连通性证据，再针对实际失败环节修复。
