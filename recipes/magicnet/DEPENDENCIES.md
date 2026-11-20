# 依赖与外部前提

## 配方闭包

| 包 | 版本 | 职责 |
| --- | --- | --- |
| magicnet | 0.3.37 | 产品集成、M01–M87 与完整验收 |
| magicnet-control-plane | 0.2.15 | CLI/JSON/MCP、文件状态、本地面板就绪与诊断 |
| magicnet-network-runtime | 0.1.21 | 订阅事务、生命周期、退出后清理与低频联网检查 |
| magicnet-web-console | 0.2.14 | 首页层级、模态快捷键、日常导航与设备操作 |
| magicnet-packet-engine | 0.2.4 | 协议、Encryption、连接清理与原生 TUN |
| magicnet-routing-policy | 0.2.6 | 路由次序、指定拒绝目标、教育分类与 DNS 出口 |
| magicnet-module-delivery | 0.2.13 | 安装升级、组件、版本选择、构建和正式发布 |
| software-quality | 0.1.0 | 设计、代码质量、性能证据与工程合同 |

根包直接依赖 control、webui、delivery、quality；control 依赖 runtime，runtime 依赖 engine、policy。所有边均为可检查、递归打包的 Markdown 配方，pack 时由 LOCK 记录摘要。webui、delivery 与 control 的集成由根包协调，避免重复分发规格。

control 统一公共状态、参数错误和有界只读订阅观察；runtime 统一 URL/节点身份、来源与恢复，根据已确认进程身份执行启停并保留未知配置与事务状态；delivery 统一模块 manifest、资产及正式发行身份。WebUI 从有效只读快照建立编辑基线和下一步建议，操作 ownership 与订阅读取状态仅留内存。合同入口见 [BUILD_PROMPT.md](BUILD_PROMPT.md)，不得复制第二套状态机或增加无需求的常驻服务。

WebUI 的静态路径、简化导航和公共视觉组件沿用 schema=1 机器接口；configured/effective、unknown/pending、危险确认与草稿语义保持。界面不增加设备持久字段、机器写接口、外部字体、网络资源或运行依赖。

本轮提升 magicnet 至 0.3.37、runtime 至 0.1.21；control 维持 0.2.15，webui 维持 0.2.14。现有合同保留真实节点的特殊标签保真、空选择器成员约束及扫描/缓存一致性；链式代理页只过滤明确日志前缀，保留合法方括号标签。共享 JSON 编码器兼容 Android awk，转换器逐项拒绝普通坏代理行并沿用完整原生回退；公告/保留标签、来源和排除语义保持。WebUI 0.2.14 统一左对齐状态、56px 起的矩形服务按钮与相邻刷新、模式/延迟/RSS、平面任务入口、中性画布和克制蓝色操作；五项手机 dock/左抽屉保持。模态快捷键隔离沿用现有 DOM 事件和界面状态，不新增机器接口、状态文件、npm 包或网络资源。沿用现有节点缓存文件、CLI 参数与全部机器接口，无新增运行依赖；runtime 0.1.21 继续保留按有效配置范围判断热点 FIB、规范表查询 argv 及 TUN 核心启动代际核对。未过期 present/missing 只属于当前单一 PID/starttime；缺少身份或代际改变投影 unknown，保留文件、探测和恢复预算。既有目的范围过滤、手动 check 与后台停机清理边界继续适用。local_zashboard_readiness、api.webui_ready 与界面合同保持，沿用现有运行库、状态域和机器接口。正式源码、构建 workflow pin 与配方固定点同步，pack 的 LOCK 包含完整闭包。

本轮 API 正文预算与路由归一化复用现有原生 loopback HTTP、可信 curl 和构建期归一化工具，无新增运行库、常驻服务、机器命令或能力标记。规则集定义、出口、DNS server 和 selector 依赖集合保持；M71 的正文预算、规则结构与设备网络测量分别验收。

本轮反馈验收补充 runtime 的 LIFE-011–014、LIFE-A17–A24 与根包 M85–M87。路由身份由现有内核 ip 查询证明，保留完整规则和重复计数，再沿用原 ownership/ledger 精确清理；不以显示别名或独立名称文件推断所有权，不要求 Android ip 必须支持 -N。prepared 基线使用私有格式证明 `rule_table_format=verified-2022`；旧基线须在核心停止且无 TUN 路由时重建，active schema 2 保持兼容。首次删除前观测失败零写入；删除中途失败留证并停止后续，已完成的明确归属删除不回滚。停止前热点循环静止、失败恢复复用现有监督器和配置锁；恢复先 try 共享配置锁，guard 内逐项核验核心/归属，锁忙/I/O 未知保持 restoration deferred；不新增运行依赖、常驻进程、机器命令、公共字段或状态文件。运行中 start/ensure 快路复用共享锁、原 shell bootstrap、幂等维护与 cgroup 脱离；DNS 安装只消除同次事务内的重复 detach 和新空链 flush。当前固定版本与源码身份仍由下节和实际 gitlink 表示，新增验收要求不构成实现已通过的声明。

## 维护实现的固定来源

`generated/magicnet-android/` 固定独立源码仓库 [LIghtJUNction/magicnet-android](https://github.com/LIghtJUNction/magicnet-android) 的主线提交 `edf2d9926e9a71000667596c9f80edd547e96363`，tree `694aa5b7a661c4e237c89762d12061c9062610fa`。gitlink、可复用工作流和三语 README 使用同一固定值；源码提交已进入 main 历史；既有严格联网检查与选择补偿的验证见[连接恢复验收](../../docs/connectivity-recovery-2026-11-18.md)。历史 2026-11-15 的七次增量提交修复 watcher 生命周期、分流编辑、TUN 冲突观察、配置事务及卸载中断恢复，完整复现、七个提交和验证范围见[11-15 检查报告](../../docs/comprehensive-audit-2026-11-15.md)与 [VERIFICATION.md](VERIFICATION.md)。

11-15 检查从源码 `73722038ab527c8d9926bc2ab532ba212bfab31e` 继续，保留此前已合入的可信本地订阅、克制 WebUI、规则次序、mDNS 和固定发行资产。此前 `af72e043` 及其对应 PR/构建/Android 结果继续按原始身份保存在 [VERIFICATION.md](VERIFICATION.md)，不用于替代本轮验证。

11-16 调优以 `b6f3a37fb5d035105917f844a6a23bb499bc1a61` 为对照，实施提交 `be00fa78f2e26a4d6998eb64e181de4028056aff` 保留 API 正文预算与路由归一化修复；当前固定提交同时保存可复现基准和完整脱敏证据。Android 开发手机仅替换 CLI 并保留经过四阶段短测的 gc_percent=50 覆盖，全局默认和现有依赖固定值保持。实测与范围见 [PERFORMANCE.md](PERFORMANCE.md)。

源码基线版本由正式发布计划统一覆盖；当前公开稳定版本、versionCode 和下载入口以根 update.json 为准，源码基线不能回退已发布版本。历史发布与实物验收结果见 VERIFICATION.md。

| 源码子模块 | 固定提交 |
| --- | --- |
| sing-box | `3a155d21872b22e6b9b75326c98d11f7ff159a2e` |
| MagicSingBox 默认模板 | `da3d375d024e0982265bc67c48a87de7bb4f9424` |
| MagicNetRules | `c4ad0a94f35af2b7950b47362e1c23e583209790` |
| kamfw | `a7788737b938a9ed930645befe2526b626999a22` |
| KamHooks | `13cff0dc1f30d8d0842e563008c7e2712233243f` |
| KamModuleX | `f21050a31c33f0ebcbf429af3056ec43c1b816ef` |

模板 `config.json` SHA-256 为 `fe741b83040191dfeca2543c6bd630d92b06a3e6e373506a2ee32cc87fc8c9b8`。默认业务 DNS 经 proxy，节点域名使用引导解析；只迁移精确旧官方 pin，自定义 repo/ref/digest 保留。规则与完整次序由 policy/POLICY_INVENTORY 定义，历史 Voice 数据不得重新引入。`.local` 与链路本地 PTR 使用原生 mDNS；home.arpa/.lan 不在新增范围。MagicNetRules 运行资产固定 `rules-20261116-df4863416dd56ad6`，manifest SHA-256 为 `701c103ede587ca83ed6852a2a9bd0b093248cc843e8e221c9b3b7cac6f116cc`，下载归档与各个规则文件均按发布清单核验。

正式包携带 curl/OpenSSL/zlib、内嵌 CA、许可证和构建来源；这些是实际运行依赖，不能假定 Android 自带 curl。固定版本与摘要由源码 `scripts/android-curl-lock.json` 和 delivery/EXTERNAL_ASSETS 维护。安装/卸载共用固定 kamfw 的 launcher.sh，核心生命周期共用该框架；不恢复 lib/kamfw-web 或重复 overlay。

源码、观察 checkout、宿主测试工具和六个嵌套子模块均不进入配方归档。独立重建可采用自己的依赖结构，但必须遵守 engine、delivery 的复用许可和全部行为合同；不能要求读取旧源码补齐需求。本次改动没有新增运行库。

Android 路由恢复验收使用现有 netd 与 ip 的只读观测。全局及逐应用 UID selectors 从已核验的网络元数据派生，采集器与独立报告门禁各自验证完整规则和重复次数；沿用 schema=1 证据、现有工具及生产恢复接口。

## 2026-11-17 维护输入

本轮在既有规则发行资产、Rust 兼容锁及 npm/Bun 双锁基础上，固定包含可选严格 HTTPS 探测的 sing-box fork 提交；MagicNet 显式启用 with_lx_probe。WebUI 使用 Vue 3.5.45、Vite 8.3.8、Tailwind 4.3.5、KernelSU SDK 3.3.0、Playwright 1.65.1、vue-tsc 3.3.14 和 highlight.js 11.12.0；TypeScript 维持 5.9 系列。运行接口与持久化格式保持。

外部工具使用 yq 4.54.3、eCapture 2.11.0、Zashboard 3.30.0；jq 1.8.2 保持当前正式版。HTTPS 执行器固定 curl 8.23.0、OpenSSL 3.5.9 LTS、zlib 1.4 和 2026-11-05 Mozilla CA，全部摘要见 delivery/EXTERNAL_ASSETS。新规则归档摘要为 df4863416dd56ad6637fdc3edc395d488463b9079d845a27085052a8e69e9e28。

规则、源码、依赖与发布说明已经分阶段提交；验证范围见 VERIFICATION，稳定软件版本继续由根 update.json 表示。

## 外部前提

- Android arm64、root 管理器、OEM 网络栈、proc/sysfs/netlink，以及当前模式所需内核能力。
- 构建宿主的 Git、编译器/交叉工具链；沿用维护实现时还需 JDK/d8、Node、KAM。独立实现可选等价工具，模块合同不变。
- 经许可的固定 sing-box 协议/密码学实现与 MagicNetRules 规则数据；jq/yq、可选转换器、ecapture 和第三方面板按所属合同核验版本、摘要和许可。缺必需能力失败，可选项报告 unsupported。
- 模板/发行服务、订阅提供者、DNS、代理出口、Tailscale 控制服务及用户授权账号。网络可达性、OEM root/SELinux/TC 能力、最低 Android/WebView 和完整多协议基线仍需实际验证。
- 正式发行需 GitHub CLI/REST 的 Release 列表、数字 ID 与附件摘要接口；只有发布 job 获得 contents 写权限。恢复另需 Actions run/job/artifact 读权限，不能用尚未公开的标签查询草稿。
- `.env`、真实订阅、密钥和设备身份不属于配方或验收夹具。测量脚本、临时 C 测量器、真实 mksh 和 KernelSU BusyBox 只用于对应开发验证，不进入模块常驻进程。

## 集成与历史

先推送已授权源码，再更新主仓库 gitlink 与可复用工作流到同一 SHA。主仓库选择版本并固定发行快照；构建和模拟器只读，稳定索引在公开成功后更新。操作见主仓库 [发布指南](../../docs/releasing.md)，完整重建语义见 delivery/RELEASE_CONTRACT。

项目名保持 MagicNet。配方发布保留原 topics 并添加 recipkg、回读核对；发现标签不构成验收证据。来源归属见 [PROVENANCE.md](PROVENANCE.md)，历史依赖变更见[精简前的固定记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/recipes/magicnet/DEPENDENCIES.md)，实际结果与限制见 [VERIFICATION.md](VERIFICATION.md)。

证书禁用默认关闭且开机无操作，接口与依赖继续遵守 runtime/CERTIFICATE_POLICY.md 合同；实现复用已有 Android app_process/Java bridge 构建链，无新增网络依赖或 CA 注入。
