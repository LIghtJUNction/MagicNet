# 重建 MagicNet（配方 0.3.13）

为 Android root 用户重建 MagicNet：从首次安装与订阅导入，到按应用、Wi-Fi、热点分流，再到节点、故障诊断和自动化控制。保留来源版本的完整用户行为，不能交付只有静态页面或包装命令的演示。

## 用户已确认的选择

- 语言由重建 Agent 根据 Android、特权边界、协议兼容与维护成本选择；没有必须保留 Rust、Shell、Go 或 Vue 的要求。可复用合规第三方实现，不要求重新发明加密协议。
- 保留全部功能及现有目标平台：生产设备为 Android root / arm64，支持 Magisk、KernelSU、APatch；WebUI 由模块管理器提供的 WebView/浏览器桥接运行。Linux 宿主与 x86_64 模拟器是开发环境，不是新的生产平台。
- 保留操作流程，视觉沿用矿白、石墨与玉绿身份，增加留白、减少重复边框，用排版和背景层次组织内容；空间与控件规则见 webui 的 DESIGN.md。保留诊断、文件草稿、失败恢复和无障碍状态。
- 沿用现有语种：WebUI zh-CN/en/ru；安装向导和操作菜单保留已有中、英、俄、日、韩语言能力及各自回退。机器 token、命令参数、配置内容、日志不翻译。
- 测量并记录现有性能基线；性能预算未知，不能把基线直接宣布为承诺。见 PERFORMANCE.md。
- 项目和主仓库名称保持 MagicNet，不加 recipkg 后缀。配方为本体；generated/ 只作容器，实现放在独立的小写连字符源码仓库，以固定提交子模块接入 generated/<source-repository-name>/，仓库名与子目录名相同。当前源码固定为 LIghtJUNction/magicnet-android@f7188cc1f1184e5b5ac8da2d24b2dabeb42503ea；其基线 `0dca28dd984d82333707cbf4b222596934b4d847` 的完整 tree 与原仓库 v1.8.0 相同。后续提交包含订阅修复、跨仓库构建发布兼容、服务交接与 PID 校验修复、日志内存优化、前端留白与边框调整，以及逐源转换下界、共享有界来源观测和固定上游内核同步/连接资源清理与手机端导航和输入改进；当前实现保留同期教育模板与精确默认 pin 迁移、低频联网恢复、单文件诊断和全部模块归档排除测试目录；本轮替换各层共享实现及 kamfw 运行时，并保留最终锁分离和诊断日志修正，按 REWRITE_CONTRACT.md 分开记录完整回归、原版缺陷和最终定向复验。正式构建发布的状态与证据见 VERIFICATION.md，尚未部署设备。main 跟踪 gitlink 和 .gitmodules；源码与观察 checkout 均不是 Recipkg 依赖，不进入配方负载。原仓库历史标签保留发行来源。
- 用户反馈与 Issue 转录见 FEEDBACK.md；M18–M29 保留原需求，M30–M39 新增多订阅、Encryption、可观测状态和重建交付验收。SOURCE_AUDIT.md 分开记录基线缺陷、当前源码修复和仍未知事项；配方合同或源码 main 更新都不等于 Android 版本已发布/部署或 #426 根因已确认。

Android 全产品最低版本及 WebView 最低版本仍未知。Java 网络策略桥以 API 26 为最低目标不等于整个产品保证支持 Android 8。不得从一台 Android 14 设备推导全版本兼容。

## 阅读范围

完整阅读本文件、BEHAVIOR.md、ACCEPTANCE.md、FEEDBACK.md、SOURCE_AUDIT.md、PERFORMANCE.md、REWRITE_CONTRACT.md、PROVENANCE.md、DEPENDENCIES.md、LICENSE.md，以及四个依赖和所有递归依赖的全部 Markdown。归档内的依赖按 alias 展开，不能只读根入口。

本轮增加的具体合同为 control/SUBSCRIPTION_INTERFACE.md、runtime/SUBSCRIPTION_CONTRACT.md、webui/SUBSCRIPTION_FLOW.md、engine/VLESS_ENCRYPTION.md；这里的前缀是依赖职责简称，包名及实际位置由 RECIPE/LOCK 决定。依赖完整闭包仍是八包，不因补充合同新增常驻服务。

0.3.3 增加 engine/CORE_LIFECYCLE.md：同步固定上游、保留 fork 协议和生产 tags；握手失败完成连接与回调清理，流绑定和关闭共享一致的并发状态。根验收 M48 对应 CORE-A01–A06，内存结果按实际测量路径记录。

0.3.1 增加 runtime/LIFECYCLE_CONTRACT.md，并补齐 control 的命令预算和日志内存要求：一次启动操作的超时不能被长期守护继承；核心就绪前由启动方负责回收，就绪后不受旧命令进程组的超时清理影响；PID 校验在 Android mksh 的 32 位算术下也必须准确。日志读取只为请求的尾部行分配索引，避免短行文件放大临时内存。根验收 M41–M43 与对应组件验收共同约束这些行为。

0.3.2 增加 M44–M47：冲突引用只影响其实际目标；逐来源原生已知数量下界不能被另一来源补数；公共和私密订阅读取遵守 control/C-SUB-008 的同一有界、零写入检查；主仓库保留模块目录 manifest 及其引用资源。M11–M13 与 UI-SUB-CASE-07 同时吸收独立候选的恢复和草稿反例。新增要求与实际实现、测试结果分别记录。

0.3.7 增加 routing-policy 0.2.2 的 POLICY-A08–A12 与根验收 M49：四个精确域名拒绝连接，`dm.wo.com.cn` 仅限 TCP/UDP 目标端口 18080；保留前置 DNS/协议处理，拒绝先于模式、应用和业务分流。内置模板使用 MagicSingBox 固定提交 `6da399473a1ab3f99661556886e0b6701581af24`，`config.json` SHA-256 为 `6365ee9b4144974ced6012dc99b9712ceef3f721f58ae9eb0943024373b81d81`；普通订阅刷新不删除这些规则。

0.3.8 通过 routing-policy 0.2.3 移除专用 ChatGPT Voice 更新脚本、Sukka Voice 上游、JSON 资产及对应 IP/端口规则。构建按现行 POLICY_INVENTORY 筛选历史来源，保留 `meta-openai`、`ai-chatgpt`、ChatGPT 域名和应用包名分流及对应 DNS。POLICY-A13–A15 与 M50 验收清理和分流保留，不增加运行依赖。

0.3.10 通过 delivery 0.2.4 和 M54 统一安装、卸载的浏览器启动器。现行 Shell 实现直接维护固定 `MemDeco-WG/kamfw` 子模块的 `launcher.sh`，安装入口导入它，卸载临时会话复制它；移除 `lib/kamfw-web/`，同步依赖、构建和测试入口。当前用户浏览器回退、有界等待、错误传播和既有 URL/app 接口保留。

0.3.11 增加 routing-policy 0.2.4 的 POLICY-A16–A20 与根验收 M55：按 policy/POLICY_INVENTORY.md 的 16 个后缀覆盖教育科研域名、指定公共服务、慕课教学和学术资源，根域名与子域名都匹配。普通业务路由使用现有 `cn-direct`（默认 `direct`），省略 `action`；DNS 使用相同列表和现有本地加密解析器。模式、LAN、用户与应用分流、广告及 DNS 防护先于教育分类，教育分类先于插入点之后的国外学术、AI、游戏、开发和媒体分类。保持用户选择、五个指定目标拒绝及既有资产，不新增 selector、接口、运行库或规则数据来源。内置模板固定 `MagicSingBox@6b5f68a261818a4ffda6eb9a11b21eef9b755650`，`config.json` SHA-256 为 `cda86a582c15e6976e6b9eb1e3c7a00811b6efea4e604bcf3f44ecae443a3db3`；精确旧官方默认 pin 随升级迁移，自定义 repo/ref/digest 保留。完整次序和边界由 policy 的入口与验收定义，模板检查、正式构建、模拟器与真机证据分别记录。

0.3.13 增加 [REWRITE_CONTRACT.md](REWRITE_CONTRACT.md) 和 M59。本轮按用户明确指定的方法观察原版功能后替换内部实现，必须比较同一输入下的外部结果与持久化副作用；不能将其混称为下节定义的无旧源码独立重建。框架、Shell、CLI/MCP、WebUI、安装和打包均在兼容范围内，已有联网维护和诊断导出同样保留。具体源码和检查证据见 VERIFICATION.md。

0.3.12 增加 runtime/CONNECTIVITY_CONTRACT.md 和 control/DIAGNOSTIC_CONTRACT.md，根验收为 M56–M58。服务启动后低频检查 Google，失败明确警告、指数退避并按证据尝试恢复；界面只读缓存。一键输出有界、脱敏、可关联路由/核心/订阅证据的单文件报告。源码测试保留，但最终核心、完整、别名及组件 ZIP 递归禁止测试和开发目录；交付门禁检查真实归档。内存与耗时使用实际执行路径测量，权限阻断、模拟、实网和真机结果分开记录。

## 独立重建边界

新构建上下文只接收完整递归 Markdown 配方和明确允许的通用工具/外部资源。先在空实现目录构建，不读取、复制、调用旧 MagicNet 实现、历史源码或原测试实现作为产品基线；源码路径与提交只是证据索引，不能要求构建者再去原仓库补需求。已明确允许的固定 sing-box 内核/密码学实现、规则数据和第三方工具可按许可证复用，并在交付中分别说明，不能把复用部分宣称成独立重写成果。

原已发布实现的编译路径与从配方独立生成新实现分别记录。仅 check/pack/build 配方不需要初始化 generated/magicnet-android 或任何旧产品源码子模块。验证新实现后再按既有仓库布局集成并固定提交，不覆盖未保存的用户工作。

### 可复用材料与集成职责

- 规则数据来自 `https://github.com/LIghtJUNction/MagicNetRules.git`，固定提交 `f3335f9420d07b8c50b26488df2a9492da6bbb44`；仅复用规则数据及必要的描述、许可证，记录实际路径和摘要。规则发行资产与该提交的对应关系须单独核实。
- `MagicSingBox@e4ecf47499c35bf25e10d04257a21a4f7975ebad` 是历史默认模板的观察来源。新默认配置依据 policy 和 POLICY_INVENTORY 的完整行为生成，构建者无需复制历史模板实现。
- sing-box 的复用范围由 engine/BUILD_PROMPT 与 VLESS_ENCRYPTION 定义，其余第三方资产按 delivery/EXTERNAL_ASSETS 固定并核验；交付物区分复用组件与新实现。
- 构建者从空实现目录交付完整源码、依赖、安装物与检查记录；集成方负责既有源码仓库、主仓库 gitlink、技能固定点与 topics。旧实现的六个嵌套子模块不是新实现必须继承的技术结构；历史测试只适用于其绑定的实现与环境。
- 节点身份按 runtime/SUB-007 的完整目标处理。完全等价节点可保留；选择合并时忽略显示名并保留已确认来源归属。同源引用在身份明确时随稳定重命名重写，真实歧义才拒绝；现行维护补丁的覆盖范围不缩减重建目标。

## 依赖使用合同

| 别名 | 职责 | 交付与集成验收 |
| --- | --- | --- |
| control | 特权 CLI、schema-1 JSON、MCP；递归包含 runtime | 三种入口改变同一份意图、同一运行时，错误和版本协商一致 |
| webui | 14 页 WebUI、编辑器、原生桥并发与国际化 | 只消费已协商控制面；不重复实现特权状态机；在成功、失败、未知和退出重进后准确显示 |
| delivery | Android 模块入口、组件安装、可信分发与更新 | 生成可安装 ZIP；升级保留配置，失败可恢复；staged 与 effective 版本区分 |
| quality | 设计、代码质量、性能证据的通用合同 | 作用于整个产品；是工程标准，不是运行库或额外业务功能；按其验收给出实际证据 |

这些组件最终组成一个 MagicNet 产品，不是要求六个常驻服务或六个可安装应用。跨组件接口可用进程、文件或库实现，但必须保留已经定义的外部行为。

## 必须成立的边界

只支持显式 tun|ebpf，默认 tun；不增加 auto，不恢复 TProxy、Redirect、netd ALLOW_MULTI、CA 注入或已删除 MITM/capture 路径。TUN 用 magicnet0，eBPF 用 capability/cgroup/TC 证据，禁止用 magicnet0 作为 eBPF 成功条件。配置意图、运行证据、事务阶段、资源所有权分开。

进程活着、API 返回成功、配置校验通过分别只能证明对应层，不能代替真实流量。支持包默认脱敏。用户订阅、SSID/BSSID、节点名、密钥和设备标识不得进入公共状态、MCP 自动资源或发布物。

安装暂存目录晋升后，自有规则、缓存、Tailscale 路径及 checkpoint/last-known-good 继续有效，外部自定义路径和用户停止意图保留。网络策略重试与回滚始终保留最初完整的共享 UID 身份、策略与逐项进度。更新回执重放与新请求都先核对当前 marker、owner 和恢复 journal，健康重放保持幂等。

## 实施与交付

先建立公开接口和验收夹具，再重建各依赖，最后集成为完整模块。实现写入 generated/ 的独立源码子模块；保留旧存储的兼容导入边界，不并行维护两个公共状态源。先推送已授权源码提交，再更新主仓库的固定 gitlink，不能把普通源码直接写入 generated/ 容器或只留下本地未发布的指针。
执行合适的本地检查，不为日常迭代触发远程 CI。正式构建、签名、制品发布及设备验收另行报告。未获授权不重启用户设备、不更改其运行订阅、不启用 MCP 或发起抓包。
正式构建从主仓库的固定源码 gitlink 取实现，发行物仍交付到 MagicNet；完整接口、权限、资产和失败语义见 delivery 的 RELEASE_CONTRACT.md。工作流配置完成不等于 Android 构建或公开发行完成。
最终交付实际实现、安装物与检查证据；只生成本配方或 build 提示词不算完成独立重建。

## 本包补充材料

- [BEHAVIOR.md](BEHAVIOR.md)
- [DEPENDENCIES.md](DEPENDENCIES.md)
- [LICENSE.md](LICENSE.md)
- [PERFORMANCE.md](PERFORMANCE.md)
- [PROVENANCE.md](PROVENANCE.md)
- [SOURCE_AUDIT.md](SOURCE_AUDIT.md)：本轮固定源码调用链、全产品保留覆盖、具体修正、证据层次和重建顺序。

- [VERIFICATION.md](VERIFICATION.md)：配方、实现与发行的实际检查结果。
- [FEEDBACK.md](FEEDBACK.md)：走查限制、Issue 来源与吸收的验收要求。


## Hybrid Mount 风格对齐（2026-11-03）

参考 https://github.com/Hybrid-Mount/meta-hybrid_mount 的 webui/src/ui/miuix/theme.css，采用 Miuix 的分组卡片节奏；独立实现，不引入其 SolidJS 组件或运行依赖。以本节覆盖早期 Fieldnotes 配色和间距描述：中性浅灰底、白色卡片、蓝色操作色，深色为中性炭灰底与浅蓝操作色。公共卡片 24px 圆角，手机分组间距 12px，宽屏 20px；标题 28–36px，分区导航采用浅底分段控件。保留安全区、44px 触达下限、键盘避让、可见焦点、减少动效以及全部页面入口。

接口与依赖：继续使用既有 schema=1 机器接口和 Vue 组件；不新增机器写接口、持久化字段、网络资源或 npm 依赖。configured/effective、unknown/pending 和错误状态保持原义。

验收：本地类型检查和构建；既有行为测试；320px、390px 和桌面导航/布局浏览器回归，浅深主题正文及操作色对比度检查。浏览器模拟不等于设备验收。


## 安装清理与突发 UDP 内存（2026-11-03）

更新和安装继续使用唯一、有 ownership 标记的事务目录；失败先恢复再清理，恢复失败保留唯一恢复材料。清理分批遍历，避免文件数量决定瞬时列表内存，不新增时间戳备份。UDP 索引达到 1024 项后，在最后一项释放时丢弃空索引的底层空间；小流量仍复用索引。保留分片锁、共享引用计数和旧连接不能删除新连接的规则。测试覆盖大批连接释放、重建及安装成功/失败/恢复/未知目录保护；记录性能与内存实测，不把微基准当作真机 RSS。接口和运行依赖不变。

## 目录、锁与 sing-box 1.15 迁移（2026-11-06）

模块状态统一放在 `.state`，可丢弃缓存与私密临时载荷统一放在 `.cache`。构建、安装、Shell、Rust、WebUI 与组件打包使用同一布局；旧 `.local/state` 和 `.tmp` 仅作一次迁移输入。目标已有不同内容时保留目标，把旧内容放入私密恢复目录；失败保留未迁移数据，不能覆盖或丢失。移除 `magicnet-network-card.svg`，升级和复用构建也不再留下旧副本。

配置锁记录实际执行临界区的 shell PID 与启动身份，嵌套 shell 的 `$$` 不能代替其实际进程。执行者退出后，即使父 shell 仍存活也能按身份回收；活 owner、暂停 owner、未知身份仍保留互斥。停止仍先清理自有热点路由和 DNS 规则，再结束核心。fswatch 的 status/start 与 stop 共用有界生命周期锁，并在锁内重查，重复 start 保持健康 watcher 的 PID；长驻进程不得继承临界区锁描述符。完整合同见 runtime/LIFECYCLE_CONTRACT.md。

按用户本轮要求采用 sing-box 1.15 的原生 sing-tun 栈，生成器、内置模板、旧快照恢复与健康检查同步省略已弃用的 `stack`。此要求更新 M29 的默认栈选择；设备 A/B 性能结果仍须另行记录。模板固定到 `MagicSingBox@dacc776dad4bd2519d5dd0dfbf3839713f9e438c`，`config.json` SHA-256 为 `08996a10e24adc6ffb6a75f96d436a543264734d95f50f9952a7a265bb58213e`；既有指定域名拒绝与路由顺序保留。

Android CLI 明确使用系统路由、没有显式网卡或网络策略绑定时，默认接口探测为空不能把整个网络工作器永久暂停。保留实际拨号错误及各层 readiness，不伪造网卡或联网状态；依赖真实接口的配置继续等待。失网取消过期异步更新，恢复后按新接口重置。根验收 M51–M53 分别绑定目录、锁和网络监控；control 的 `native_tun_stack` 能力说明 `effective.stack=default` 的配置含义。
