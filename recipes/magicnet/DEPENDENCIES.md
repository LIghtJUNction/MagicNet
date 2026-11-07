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

## 0.3.16 闭包与具体接口

| 包 | 版本 | 本轮合同责任 |
| --- | --- | --- |
| magicnet | 0.3.16 | 全产品保留范围、M01–M64、重写对照、DNS 出口及 Issue 修复集成 |
| magicnet-control-plane | 0.2.7 | C-SUB-001–008、缓存联网状态、DIAG-001–003单文件导出、监督故障日志、状态结构保真、HTTPS执行器来源（DIAG-A07–A08）与实时 TUN 路由证据 |
| magicnet-network-runtime | 0.1.8 | SUB-001–015，LIFE-001–007，订阅完整监督恢复，CON-001–004低频探测、恢复与实际HTTPS执行器 |
| magicnet-web-console | 0.2.4 | UI-SUB-001–012、UI-CON-01–04警告与单次诊断导出 |
| magicnet-packet-engine | 0.2.3 | VE-001–006、CORE-001–005，原生 TUN 与可选接口监控 |
| magicnet-routing-policy | 0.2.5 | 增量分流、指定目标拒绝、Voice规则清理、教育分类与默认 DNS 出口，POLICY-A01–25 |
| magicnet-module-delivery | 0.2.7 | 安装更新、共用启动器、目录合并、正式curl/TLS/证书组件、缺失默认清单与历史迁移、验收失败证据及最终模块/组件排除测试目录 |
| software-quality | 0.1.0 | 沿用已固定工程质量合同，未更改 |

本地相对配方依赖在pack时递归进入归档并由LOCK记录摘要，不能仅交付上表链接。新订阅状态字段以control为唯一authority，URL/节点身份以runtime为唯一authority，UI只投递意图和显示已协商结果；不创建新常驻服务或复制第二套订阅状态机。

delivery 同时维护 RELEASE_CONTRACT.md：区分源码仓库、配方提交和官方发行仓库，定义 schema-1 构建来源记录、固定源码构建、同提交 Android 验收与草稿发布门槛；草稿按唯一数字 release ID 校验与公开，发布控制失败的独立恢复复用原通过记录与不可变产物。不新增运行时配方依赖。

0.3.10 保持八包闭包。现行源码直接通过固定 `MemDeco-WG/kamfw` 子模块提供安装和卸载使用的 `launcher.sh`，删除独立的 `lib/kamfw-web/`；安装、卸载和浏览器检查共用该依赖。

0.3.1 的生命周期修复只使用现有 Rust 标准库/libc 与 shell 内建能力，日志优化不增加库依赖。验证端使用真实 mksh 与固定 KernelSU BusyBox；这些宿主测试工具不进入产品常驻进程或 Markdown 配方负载。

0.3.2 保留八包依赖关系，新增合同不引入常驻服务或新的运行库要求。来源只读检查由 control 统一，逐源数量与引用语义由 runtime 统一，模块目录 manifest 与正式发行身份由 delivery 统一。独立新实现可以采用自己的固定依赖集合；现行源码的六个嵌套子模块不构成重写的目录约束。

0.3.3 的 engine 同步对象为固定 sing-box/sing-tun 版本及既有 WireGuard 复制源码，保留 AWG 与 fork 差异。完整核心依赖锁和 gitlink 在源码实现中维护；CORE_LIFECYCLE.md 规定来源、兼容与验证要求，八包配方闭包保持不变。

0.3.7 保持八包依赖图及既有内核/公共规则资产。指定目标拒绝直接写入固定默认模板，不新增运行库、规则下载来源或常驻服务；模板提交为 `6da399473a1ab3f99661556886e0b6701581af24`，`config.json` SHA-256 为 `6365ee9b4144974ced6012dc99b9712ceef3f721f58ae9eb0943024373b81d81`。

0.3.8 从外部规则来源中移除 Sukka ChatGPT Voice 专用数据及更新入口，历史数据按现行 POLICY_INVENTORY 筛选。模板固定为 `dacc776dad4bd2519d5dd0dfbf3839713f9e438c`，`config.json` SHA-256 为 `08996a10e24adc6ffb6a75f96d436a543264734d95f50f9952a7a265bb58213e`。八包依赖图保持不变，`meta-openai`、`ai-chatgpt` 与普通 ChatGPT 域名/应用分流继续保留。

0.3.9 保持八包闭包，不增加常驻服务、运行库或内核模块。配置锁和 fswatch 互斥复用现有 proc 身份与 metadata guard，目录迁移复用原有配置锁。固定核心的可选 Android 接口补丁不改变接口结构或真实拨号错误语义。

0.3.11 在同一八包闭包中由 routing-policy 0.2.4 维护 16 个教育服务后缀及路由/DNS 优先级，官方来源随 POLICY_INVENTORY.md 打包。复用 `cn-direct`、现有 DNS server 与规则资产，不增加 selector、运行库、规则数据下载或常驻服务；模板固定为 `6b5f68a261818a4ffda6eb9a11b21eef9b755650`，`config.json` SHA-256 为 `cda86a582c15e6976e6b9eb1e3c7a00811b6efea4e604bcf3f44ecae443a3db3`。精确旧默认 pin 升级至该提交和摘要，自定义 repo/ref/digest 不变；实际来源和验证结果分别记录。

0.3.13 保持八包闭包与既有内核、模板和规则来源。kamfw 框架作为独立固定源码依赖重写；核心启停由共享框架提供，删除 MagicNet 的重复 overlay。宿主差分、安装和打包工具只属于开发树。REWRITE_CONTRACT.md 要求对照同期基线中的 connectivity.status、support.export 和资源预算，公开接口的文件写入例外有明确范围，不扩大通用机器写权限。

## 实现与观察材料

0.3.12 保留八包闭包；探测复用监督循环、生命周期锁与 Rust std/libc，导出复用现有有界子进程和脱敏结构投影，WebUI复用Vue/原生桥。当时假定可用的curl并未进入正式包；后续实际归档和无系统curl的Android验证否定了这一前提。0.3.14通过delivery 0.2.6补入正式`bin-curl`组件：固定curl/OpenSSL/zlib源码与内嵌CA，同组件携带许可证和构建来源，安装与更新均校验。八包配方闭包保持，但运行负载新增了这个HTTPS执行器及其静态库，不能宣称没有新增运行依赖。CONNECTIVITY_CONTRACT由runtime维护，DIAGNOSTIC_CONTRACT和机器能力由control维护；delivery对所有最终ZIP独立拒绝测试/开发目录。测量脚本及其临时C测量器只供宿主验收，不进入模块。

`generated/magicnet-android/` 是独立源码仓库 `https://github.com/LIghtJUNction/magicnet-android.git` 的固定提交子模块，本轮为 `ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9`，软件版本仍为 `v1.8.5 / 10613`。本轮以 `aefcbfbab80fe14008e4467eb0292251f7ce8f89` 为比较原版，重写各层共享实现与 kamfw 运行时；保留原有低频联网恢复、单文件诊断、教育模板与精确默认 pin 迁移、Voice 规则清理、原生 TUN、目录及锁修正。完整差分、回归和性能对象为 `d58dbdc`；随后合入同期 `81a601` 的监督器锁分离、诊断日志及 Android 验收脚本修正，并做受影响路径复验。内核继续固定 `d850ff0ff68e11a71aa8207627e0a826cb52808f`，模板固定 `6b5f68a261818a4ffda6eb9a11b21eef9b755650`。框架最终固定到公开的 `MemDeco-WG/kamfw@a7788737b938a9ed930645befe2526b626999a22`，相对已测 `ea8758bf` 仅增加测试；核心生命周期使用该共享框架，删除 MagicNet 重复 overlay。此前的 launcher 维护继续保留，`lib/kamfw-web/` 已移除。随后d22b122修复安装测试夹具的清理次序，并以实际包内框架行为替代旧变量名断言。随后b5fa1cd按字段脱敏服务/TUN/DNS机器状态并使用有效MCP只读入口，Android验收同时验证导出内容语义，保留全部真实透明事务阶段。实际CI构建、归档与Android模拟器结果见VERIFICATION.md；没有新建正式Release或完成物理手机验收。源码仓库仍保留六个嵌套源码子模块，不加入上面的 Recipkg 依赖图，也不进入 Markdown 配方归档。观察 checkout 与实现分开；无需读取源码才能获取本包完整需求。

0.3.14的LIFE-006要求MagicNet外层controller锁与框架内层lifecycle锁分离，固定加锁顺序并用真实固定框架验证，避免同一进程链上的重复flock自锁。control 0.2.6将detached supervisor和connectivity-watchdog故障日志纳入单文件诊断；锁与日志修复本身不新增库。正式curl组件另按CON-004、CON-A07和DIAG-A08验证真实执行、证书校验及诊断来源。包内框架验证运行真实loader和watchdog/fswatch，测试夹具按真实sanitize→split次序准备，保留对开发目录的严格拒绝。

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

## 0.3.15 默认 DNS 修复

本轮接入 routing-policy 0.2.5，依赖闭包仍为八包，无新增运行时依赖。当前固定源码为 `LIghtJUNction/magicnet-android@38c6eea6a42eb5f2cc3697c81225f35fd3c82d5c`，源码版本保持 1.8.5，本轮不新建发行。

内置模板固定为 `LIghtJUNction/MagicSingBox@ba5793b41fd06704102116fe2536eef5988f2905`，`config.json` SHA-256 为 `e269e2303cf1e23d3b4ce69dcb7cca39f0f53dc647c5d03aace4c4bd7f986be0`。该模板以经 `proxy` 的 `doh-cloudflare` 承接默认 DNS，并保留 `bootstrap-local-dns` 引导解析和显式直连规则；精确旧官方默认 pin 迁移，自定义 repo/ref/digest 保留。验收对应 M60 与 POLICY-A21–A25，实际验证范围见 [DNS_REPAIR_2026-11-06.md](DNS_REPAIR_2026-11-06.md) 和 [VERIFICATION.md](VERIFICATION.md)。

## 0.3.16 Issue 修复集成

0.3.16 将 `generated/magicnet-android` 固定为 `LIghtJUNction/magicnet-android@8ff1242817038dfe220a68b75934d6b127bea4b1`，tree `a23ade9034a47be945dc526f7fe5b00751267911`，源码 PR [#3](https://github.com/LIghtJUNction/magicnet-android/pull/3)。软件仍为 1.8.5 / 10613。control 0.2.7、runtime 0.1.8、delivery 0.2.7 接入 M61–M64，八包闭包不变；内核、模板、kamfw 和规则来源继续使用上一轮固定值，不引入新运行时库或模式。

此提交包含九次增量提交：安装历史、TLS 夹具、监督恢复、实时 TUN 证据与文档精度，以及依赖安装预算、失败支持包和 Android 参数/数字表身份修正。已知限制、旧失败、当前 CI 和 Issue 处置见 [ISSUE_TRIAGE_2026-11-06.md](ISSUE_TRIAGE_2026-11-06.md)。受控本地测试不替代真机网络切换；未实现的可信 NAS 入口继续单独跟踪。

## 0.3.17 发布接口

当前 `generated/magicnet-android` 固定为 `LIghtJUNction/magicnet-android@b989227b140a7627edff8b60ad87655cb09ac2d0`，tree `7857e06e0f556aee1cb716cbcd717324e1da3f05`。相对 0.3.16 的 `8ff1242817038dfe220a68b75934d6b127bea4b1`，该提交只安装完整质量套件所需的 mksh，不改变运行时行为、八包闭包或软件版本 1.8.5 / 10613。主仓库可复用工作流与 gitlink 使用同一 SHA。源码 PR [#4](https://github.com/LIghtJUNction/magicnet-android/pull/4)，主仓库 PR [#443](https://github.com/LIghtJUNction/MagicNet/pull/443)。已发布 Android 包仍为 v1.8.4 / 10612。

接入 delivery 0.2.8，八包闭包和全部运行时依赖保持。源码仓库新增只用于构建的版本注入与可复用 workflow 接口；主仓库使用自带 GITHUB_TOKEN 写固定发行快照与官方 Release，构建/模拟器只有读权限。版本不依赖跨仓库写入令牌，source_ref 显式选择后固定为 SHA，稳定索引与源码开发版本分离。
