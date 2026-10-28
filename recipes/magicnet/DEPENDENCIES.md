# 依赖与外部前提

~~~mermaid
graph TD
  M[MagicNet] --> C[control]
  M --> U[webui]
  M --> D[delivery]
  M --> Q[quality]
  C --> R[runtime]
  R --> E[engine]
  R --> P[policy]
~~~

所有箭头均指实际存在、可检查并递归打包的 Markdown 配方。quality 是复用的工程合同；其余是重建的组件。webui 和 delivery 与 control 的集成由根包协调，避免以重复递归依赖复制同一控制面规格。

## 外部前提，未打包为依赖

- Android arm64、root 管理器、OEM 网络栈、可用 proc/sysfs/netlink，以及对应模式的内核能力。
- 宿主 Git、编译器/交叉工具链、JDK/d8（若仍使用 Java bridge）、Node（若仍使用现有前端）、KAM（若仍使用现有打包）。重建 Agent 可选择等价工具，公开模块包合同不变。
- sing-box 的协议/密码学实现可以按许可证复用经审核的固定源码。packet-engine 配方描述产品需要的入站、协议/API 与补丁能力；外部源码是实现前提，绝不作为 source-only Recipkg 依赖。
- 公共规则数据、jq/yq、可选订阅转换器、ecapture 和内嵌第三方面板；明确固定版本、摘要与许可证，缺失必需能力必须失败，可选项报告 unsupported。
- 官方 GitHub/GitLab 模板与发行服务、订阅提供者、DNS 解析器、代理出口、Tailscale 控制服务和用户授权的账号。
- 本地 .env、真实订阅和密钥均不属于配方，也不属于验收夹具。

重建环境能否联网获取上游、特定 OEM 的 root/SELinux/TC 能力、完整多协议端到端基线、最低 Android/WebView 版本均未确认。不能用这些外部前提的名字掩盖尚未实现的 MagicNet 行为。

## 发布与发现

项目名称保持 MagicNet。GitHub 发布配方时必须在原仓库保留已有 topics 并加入 recipkg，再回读确认；这只帮助发现，不证明配方正确。创建新远程、发布新版本、修改设备和推送到其他项目不包含在本地配方交付中。
