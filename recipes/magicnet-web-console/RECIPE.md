# MagicNet 移动网络控制界面

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-web-console"
version = "0.2.13"
kind = "software"
description = "MagicNet 移动网络控制界面"
entry = "BUILD_PROMPT.md"
~~~

交付保留 14 页、三语、浅深主题与现有设备操作的移动界面。当前流程见 [BUILD_PROMPT.md](BUILD_PROMPT.md)，视觉规范见 [DESIGN.md](DESIGN.md)，订阅合同见 [SUBSCRIPTION_FLOW.md](SUBSCRIPTION_FLOW.md)，全部验收见 [ACCEPTANCE.md](ACCEPTANCE.md)。

0.2.13 明确链式代理候选的标签保真：保留 [HK]、[US] 等方括号前缀及普通节点文字，只剔除明确的兼容日志前缀；原始标签用于选择和提交，沿用 control 的候选与缓存合同。首页以 112px 服务开关、模式/延迟/RSS 摘要和日常任务链接组织层级，使用中性黑白主题、手机底部 dock 与左侧抽屉；本轮将同一结构扩展到全部 14 页：每页以真实状态和主要任务开头，次要设置与报告按需展开，保留原设备操作、确认、草稿和队列门控。手机验收覆盖 360/390/430px，并为包含 proxies 在内的全部页面保存独立截图索引。

0.2.12 修正缓存节点页的刷新：重新进入已加载页面时读取当前核心快照，旧响应与旧测速结果不能覆盖新一轮状态；保留搜索、展开和有效的待确认选择。共享视觉使用克制的灰蓝画布、轻量设置面板与统一控件层次，保留触控、三语、浅深主题和全部功能。

0.2.11 将本机 Zashboard 提升为概览主操作，并在管理面板和宽屏顶栏提供同一入口；新鲜机器快照、同源 loopback 地址、setup 参数、旧 CLI 校验和共享 busy 构成完整打开流程。安装与校验等维护细节默认折叠。

配方不含实现源码，版本与 Android 软件版本独立。来源与历史由根包 PROVENANCE 统一记录；函数夹具、浏览器截图、Android WebView 和设备实测分别记入 VERIFICATION。
