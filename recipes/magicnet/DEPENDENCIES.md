# 依赖与外部前提

## 配方闭包

| 包 | 版本 | 职责 |
| --- | --- | --- |
| magicnet | 0.3.20 | 产品集成、M01–M68 与完整验收 |
| magicnet-control-plane | 0.2.9 | CLI/JSON/MCP、文件状态、订阅观察与单文件诊断 |
| magicnet-network-runtime | 0.1.10 | 订阅事务、生命周期、监督恢复与低频联网检查 |
| magicnet-web-console | 0.2.6 | WebUI、订阅草稿、警告与诊断导出 |
| magicnet-packet-engine | 0.2.3 | 协议、Encryption、连接清理与原生 TUN |
| magicnet-routing-policy | 0.2.5 | 路由次序、指定拒绝目标、教育分类与 DNS 出口 |
| magicnet-module-delivery | 0.2.9 | 安装升级、组件、版本选择、构建和正式发布 |
| software-quality | 0.1.0 | 设计、代码质量、性能证据与工程合同 |

根包直接依赖 control、webui、delivery、quality；control 依赖 runtime，runtime 依赖 engine、policy。所有边均为可检查、递归打包的 Markdown 配方，pack 时由 LOCK 记录摘要。webui、delivery 与 control 的集成由根包协调，避免重复分发规格。

control 统一公共状态、参数错误和有界只读订阅观察；runtime 统一 URL/节点身份、来源与恢复，根据已确认进程身份执行启停并保留未知配置与事务状态；delivery 统一模块 manifest、资产及正式发行身份。WebUI 从有效只读快照建立编辑基线和下一步建议，操作 ownership 与订阅读取状态仅留内存。合同入口见 [BUILD_PROMPT.md](BUILD_PROMPT.md)，不得复制第二套状态机或增加无需求的常驻服务。

## 维护实现的固定来源

`generated/magicnet-android/` 是独立源码仓库 [LIghtJUNction/magicnet-android](https://github.com/LIghtJUNction/magicnet-android) 的子模块，当前固定为 `7c8faf8327a5249b83f721f0c1a64098ea92f576`，tree `1a9e4e8bfbf10991d9127a1987a2b9c0156b2515`。本固定点合并可用性修正、TUN 路由有界恢复与真实模拟器故障门禁，并修复 Tailscale 读取自循环，源码 metadata 仍为 v1.8.5 / 10613；公开安装物以根 `update.json` 与 Releases 为准。

| 源码子模块 | 固定提交 |
| --- | --- |
| sing-box | `d850ff0ff68e11a71aa8207627e0a826cb52808f` |
| MagicSingBox 默认模板 | `ba5793b41fd06704102116fe2536eef5988f2905` |
| MagicNetRules | `f3335f9420d07b8c50b26488df2a9492da6bbb44` |
| kamfw | `a7788737b938a9ed930645befe2526b626999a22` |
| KamHooks | `13cff0dc1f30d8d0842e563008c7e2712233243f` |
| KamModuleX | `f21050a31c33f0ebcbf429af3056ec43c1b816ef` |

模板 `config.json` SHA-256 为 `e269e2303cf1e23d3b4ce69dcb7cca39f0f53dc647c5d03aace4c4bd7f986be0`。默认业务 DNS 经 proxy，节点域名使用引导解析；只迁移精确旧官方 pin，自定义 repo/ref/digest 保留。规则与完整次序由 policy/POLICY_INVENTORY 定义，历史 Voice 数据不得重新引入。

正式包携带 curl/OpenSSL/zlib、内嵌 CA、许可证和构建来源；这些是实际运行依赖，不能假定 Android 自带 curl。固定版本与摘要由源码 `scripts/android-curl-lock.json` 和 delivery/EXTERNAL_ASSETS 维护。安装/卸载共用固定 kamfw 的 launcher.sh，核心生命周期共用该框架；不恢复 lib/kamfw-web 或重复 overlay。

源码、观察 checkout、宿主测试工具和六个嵌套子模块均不进入配方归档。独立重建可采用自己的依赖结构，但必须遵守 engine、delivery 的复用许可和全部行为合同；不能要求读取旧源码补齐需求。本次改动没有新增运行库。

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
