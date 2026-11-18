# MagicNet 版本化 CLI、机器接口与认证 MCP

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-control-plane"
version = "0.2.15"
kind = "software"
description = "MagicNet 版本化 CLI、机器接口与认证 MCP"
entry = "BUILD_PROMPT.md"

[dependencies.runtime]
source = "../magicnet-network-runtime"
~~~

交付单一 CLI、schema-1 机器接口、认证 MCP 与文件状态面；进程、订阅和网络事务委托 runtime。[BUILD_PROMPT.md](BUILD_PROMPT.md) 索引人类、机器、订阅、诊断、MCP、状态与资源合同，[ACCEPTANCE.md](ACCEPTANCE.md) 定义验收。

0.2.15 明确节点身份与空成员语义：真实代理类型的标签不因包含“选择”“策略”或 Selector、URLTest、Fallback 等文字而被隐藏；内部保留标签与生成链路节点仍排除。存在但无成员的 proxy 选择器保持空，新鲜配置与缓存回退使用一致的标签规则。共享 JSON 编码器须兼容 Android awk；转换结果逐项检查普通代理节点，保留既有公告和保留标签过滤，失败沿用完整原生回退。

0.2.14 明确当前节点列表的事实源：已提交配置的真实代理节点优先，旧 work tags 和候选配置不参与；有效空配置保持空，只有配置不可用时才沿用可关闭的既有缓存回退。命令、参数与机器接口保持。

0.2.13 增加 local_zashboard_readiness 能力与 service.status.data.api.webui_ready 布尔字段。只读观测固定本地入口文件，与 API、进程、数据面及整体 readiness 分开；不新增命令、状态域或联网动作。

配方不含实现源码，版本与 Android 软件版本独立。来源和历史由根包 PROVENANCE 统一记录，实际源码、主机及 Android 结果见 VERIFICATION；新增合同与旧实现的能力差异以所属接口文件为准。
