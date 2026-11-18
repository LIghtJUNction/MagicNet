# MagicNet 移动网络控制界面

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-web-console"
version = "0.2.11"
kind = "software"
description = "MagicNet 移动网络控制界面"
entry = "BUILD_PROMPT.md"
~~~

交付保留 14 页、三语、浅深主题与现有设备操作的移动界面。当前流程见 [BUILD_PROMPT.md](BUILD_PROMPT.md)，视觉规范见 [DESIGN.md](DESIGN.md)，订阅合同见 [SUBSCRIPTION_FLOW.md](SUBSCRIPTION_FLOW.md)，全部验收见 [ACCEPTANCE.md](ACCEPTANCE.md)。

0.2.11 将本机 Zashboard 提升为概览主操作，并在管理面板和宽屏顶栏提供同一入口；新鲜机器快照、同源 loopback 地址、setup 参数、旧 CLI 校验和共享 busy 构成完整打开流程。安装与校验等维护细节默认折叠。

配方不含实现源码，版本与 Android 软件版本独立。来源与历史由根包 PROVENANCE 统一记录；函数夹具、浏览器截图、Android WebView 和设备实测分别记入 VERIFICATION。
