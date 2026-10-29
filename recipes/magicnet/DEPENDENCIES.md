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

## 0.3.0 闭包与具体接口

| 包 | 版本 | 本轮合同责任 |
| --- | --- | --- |
| magicnet | 0.3.0 | 全产品保留范围、M01–M39、来源和真实验证 |
| magicnet-control-plane | 0.2.1 | C-SUB完整入口、公共/私密状态、subscription_batch_v1 |
| magicnet-network-runtime | 0.1.1 | SUB-001–015，多源完整性、统一身份、合并与事务 |
| magicnet-web-console | 0.2.1 | UI-SUB-001–012，完整输入与同代反馈、草稿/隐私 |
| magicnet-packet-engine | 0.2.0 | VE-001–006，固定核心Encryption客户端能力与实测边界 |
| magicnet-routing-policy | 0.2.1 | 增量分流与订阅归属、POLICY-A01–07 |
| magicnet-module-delivery | 0.2.1 | 安装更新与三个核心包发布名的同身份合同 |
| software-quality | 0.1.0 | 沿用已固定工程质量合同，未更改 |

本地相对配方依赖在pack时递归进入归档并由LOCK记录摘要，不能仅交付上表链接。新订阅状态字段以control为唯一authority，URL/节点身份以runtime为唯一authority，UI只投递意图和显示已协商结果；不创建新常驻服务或复制第二套订阅状态机。

## 实现与观察材料

`generated/magicnet-android/` 是独立源码仓库 `https://github.com/LIghtJUNction/magicnet-android.git` 的固定提交子模块，当前为 `ed01282e8ee4bcfc27ce5f95f37723c34aebf745`。该提交接在基线 `0dca28dd984d82333707cbf4b222596934b4d847` 之后，修复本轮确认的订阅行为；它不是 Android 发行版或部署证明。源码仓库仍保留六个嵌套源码子模块，不加入上面的 Recipkg 依赖图，也不进入 Markdown 配方归档。观察 checkout 与实现分开；无需读取源码才能获取本包完整需求。

## 外部前提，未打包为依赖

- Android arm64、root 管理器、OEM 网络栈、可用 proc/sysfs/netlink，以及对应模式的内核能力。
- 宿主 Git、编译器/交叉工具链、JDK/d8（若仍使用 Java bridge）、Node（若仍使用现有前端）、KAM（若仍使用现有打包）。重建 Agent 可选择等价工具，公开模块包合同不变。
- sing-box 的协议/密码学实现可以按许可证复用经审核的固定源码。packet-engine 配方描述产品需要的入站、协议/API 与补丁能力；外部源码是实现前提，绝不作为 source-only Recipkg 依赖。
- 公共规则数据、jq/yq、可选订阅转换器、ecapture 和内嵌第三方面板；明确固定版本、摘要与许可证，缺失必需能力必须失败，可选项报告 unsupported。
- 官方 GitHub/GitLab 模板与发行服务、订阅提供者、DNS 解析器、代理出口、Tailscale 控制服务和用户授权的账号。
- 本地 .env、真实订阅和密钥均不属于配方，也不属于验收夹具。

重建环境能否联网获取上游、特定 OEM 的 root/SELinux/TC 能力、完整多协议端到端基线、最低 Android/WebView 版本均未确认。不能用这些外部前提的名字掩盖尚未实现的 MagicNet 行为。

## 发布与发现

项目名称保持 MagicNet。GitHub 发布配方时必须在原仓库保留已有 topics 并加入 recipkg，再回读确认；这只帮助发现，不证明配方正确。本轮用户已授权按迁移技能发布独立源码仓库 magicnet-android 并接入主仓库；不包含发布新 Android 版本、修改设备或推送到无关项目。
