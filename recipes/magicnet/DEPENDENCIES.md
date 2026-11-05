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

## 0.3.7 闭包与具体接口

| 包 | 版本 | 本轮合同责任 |
| --- | --- | --- |
| magicnet | 0.3.7 | 全产品保留范围、M01–M49、候选整合和真实验证 |
| magicnet-control-plane | 0.2.3 | C-SUB-001–008、共享只读来源检查、命令预算与日志尾读 |
| magicnet-network-runtime | 0.1.4 | SUB-001–015，LIFE-001–004，逐源下界、引用与恢复 |
| magicnet-web-console | 0.2.2 | UI-SUB-001–012，完整输入与同代反馈、草稿/隐私 |
| magicnet-packet-engine | 0.2.2 | VE-001–006、CORE-001–005，固定上游与连接资源归属 |
| magicnet-routing-policy | 0.2.2 | 增量分流、订阅归属与指定目标拒绝，POLICY-A01–12 |
| magicnet-module-delivery | 0.2.2 | 安装更新与三个核心包发布名的同身份合同 |
| software-quality | 0.1.0 | 沿用已固定工程质量合同，未更改 |

本地相对配方依赖在pack时递归进入归档并由LOCK记录摘要，不能仅交付上表链接。新订阅状态字段以control为唯一authority，URL/节点身份以runtime为唯一authority，UI只投递意图和显示已协商结果；不创建新常驻服务或复制第二套订阅状态机。

delivery 同时维护 RELEASE_CONTRACT.md：区分源码仓库、配方提交和官方发行仓库，定义 schema-1 构建来源记录、固定源码构建、同提交 Android 验收与草稿发布门槛；草稿按唯一数字 release ID 校验与公开，发布控制失败的独立恢复复用原通过记录与不可变产物。不新增运行时配方依赖。

0.3.1 的生命周期修复只使用现有 Rust 标准库/libc 与 shell 内建能力，日志优化不增加库依赖。验证端使用真实 mksh 与固定 KernelSU BusyBox；这些宿主测试工具不进入产品常驻进程或 Markdown 配方负载。

0.3.2 保留八包依赖关系，新增合同不引入常驻服务或新的运行库要求。来源只读检查由 control 统一，逐源数量与引用语义由 runtime 统一，模块目录 manifest 与正式发行身份由 delivery 统一。独立新实现可以采用自己的固定依赖集合；现行源码的六个嵌套子模块不构成重写的目录约束。

0.3.3 的 engine 同步对象为固定 sing-box/sing-tun 版本及既有 WireGuard 复制源码，保留 AWG 与 fork 差异。完整核心依赖锁和 gitlink 在源码实现中维护；CORE_LIFECYCLE.md 规定来源、兼容与验证要求，八包配方闭包保持不变。

0.3.7 保持八包依赖图及既有内核/公共规则资产。指定目标拒绝直接写入固定默认模板，不新增运行库、规则下载来源或常驻服务；模板提交为 `6da399473a1ab3f99661556886e0b6701581af24`，`config.json` SHA-256 为 `6365ee9b4144974ced6012dc99b9712ceef3f721f58ae9eb0943024373b81d81`。

## 实现与观察材料

`generated/magicnet-android/` 是独立源码仓库 `https://github.com/LIghtJUNction/magicnet-android.git` 的固定提交子模块，本轮为 `c75583b00527acf96310e96c124805db010d939a`，软件版本 `v1.8.5 / 10613`。该提交基于 v1.8.4 已发布源码 `d22086d28499ceb25c9f2b7d965e783ded6c286a`，引入上述固定模板、同步默认来源摘要与版本元数据，并补充应用分流及用户增量覆盖的保留回归。它不代表 Android 安装包已经公开或真机验收完成；实际结果见 VERIFICATION.md。源码仓库仍保留六个嵌套源码子模块，不加入上面的 Recipkg 依赖图，也不进入 Markdown 配方归档。观察 checkout 与实现分开；无需读取源码才能获取本包完整需求。

## 外部前提，未打包为依赖

- Android arm64、root 管理器、OEM 网络栈、可用 proc/sysfs/netlink，以及对应模式的内核能力。
- 宿主 Git、编译器/交叉工具链、JDK/d8（若仍使用 Java bridge）、Node（若仍使用现有前端）、KAM（若仍使用现有打包）。重建 Agent 可选择等价工具，公开模块包合同不变。
- sing-box 的协议/密码学实现可以按许可证复用经审核的固定源码。packet-engine 配方描述产品需要的入站、协议/API 与补丁能力；外部源码是实现前提，绝不作为 source-only Recipkg 依赖。
- 公共规则数据来自 `https://github.com/LIghtJUNction/MagicNetRules.git@f3335f9420d07b8c50b26488df2a9492da6bbb44`，仅复用规则数据及必要描述、许可证。jq/yq、可选订阅转换器、ecapture 和内嵌第三方面板按所属合同固定版本、摘要与许可证，缺失必需能力必须失败，可选项报告 unsupported。
- 官方 GitHub/GitLab 模板与发行服务、订阅提供者、DNS 解析器、代理出口、Tailscale 控制服务和用户授权的账号。
- 正式 GitHub 发行需要 GitHub CLI/REST 的 Release 列表、数字 ID 和附件摘要接口；只有发布 job 获得 contents 写权限。独立恢复另需 Actions run/job/artifact 只读权限，不能依赖尚未公开的标签查询草稿。
- 本地 .env、真实订阅和密钥均不属于配方，也不属于验收夹具。

重建环境能否联网获取上游、特定 OEM 的 root/SELinux/TC 能力、完整多协议端到端基线、最低 Android/WebView 版本均未确认。不能用这些外部前提的名字掩盖尚未实现的 MagicNet 行为。

## 发布与发现

项目名称保持 MagicNet。GitHub 发布配方时必须在原仓库保留已有 topics 并加入 recipkg，再回读确认；这只帮助发现，不证明配方正确。用户先授权按迁移技能发布独立源码仓库 magicnet-android 并接入主仓库，后明确授权发布新 Android 版本；v1.8.1 的公开发行和真实验证范围见 VERIFICATION.md，未执行设备部署或向无关项目推送。
