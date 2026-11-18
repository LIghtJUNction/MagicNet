# MagicNet 版本化 CLI、机器接口与认证 MCP

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-control-plane"
version = "0.2.13"
kind = "software"
description = "MagicNet 版本化 CLI、机器接口与认证 MCP"
entry = "BUILD_PROMPT.md"

[dependencies.runtime]
source = "../magicnet-network-runtime"
~~~

交付单一 CLI、schema-1 机器接口、认证 MCP 与文件状态面；进程、订阅和网络事务委托 runtime。[BUILD_PROMPT.md](BUILD_PROMPT.md) 索引人类、机器、订阅、诊断、MCP、状态与资源合同，[ACCEPTANCE.md](ACCEPTANCE.md) 定义验收。

0.2.13 增加 local_zashboard_readiness 能力与 service.status.data.api.webui_ready 布尔字段。只读观测固定本地入口文件，与 API、进程、数据面及整体 readiness 分开；不新增命令、状态域或联网动作。

配方不含实现源码，版本与 Android 软件版本独立。来源和历史由根包 PROVENANCE 统一记录，实际源码、主机及 Android 结果见 VERIFICATION；新增合同与旧实现的能力差异以所属接口文件为准。
