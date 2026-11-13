# 重建 MagicNet（配方 0.3.21）

为 Android root 用户实现完整网络工作台：安装、订阅、应用/Wi-Fi/热点分流、节点、DNS、诊断与自动化控制。保留 [BEHAVIOR.md](BEHAVIOR.md) 的用户流程和 [ACCEPTANCE.md](ACCEPTANCE.md) 的 M01–M68；交付可运行产品。

## 平台、材料与布局

- 生产目标为 Android root/arm64，支持 Magisk、KernelSU、APatch；WebUI 使用模块管理器的 WebView/浏览器桥。Linux 与 x86_64 模拟器用于开发验证。最低 Android/WebView 版本未知；Java 桥的 API 26 目标不构成全产品兼容承诺。
- 语言、框架由实现者按特权边界、协议兼容和维护成本选择。WebUI 保留 zh-CN/en/ru；安装向导和菜单保留已有中、英、俄、日、韩及回退。机器 token、参数、配置和日志不翻译。
- 项目名保持 MagicNet。`recipes/` 为主要输入；实现放在独立小写连字符源码仓库，并以同名固定子模块接入 `generated/`。跟踪 `.gitmodules` 和 gitlink，不向容器提交普通源码。
- 当前维护实现为 `LIghtJUNction/magicnet-android@7b6a2a61aff3dc495a10f5010464118ed65907db`；全部固定依赖见 [DEPENDENCIES.md](DEPENDENCIES.md)，来源归属见 [PROVENANCE.md](PROVENANCE.md)。源码和观察 checkout 不属于 Recipkg 依赖或归档负载。
- 完整阅读本文件、BEHAVIOR、ACCEPTANCE、FEEDBACK、SOURCE_AUDIT、PERFORMANCE、REWRITE_CONTRACT、PROVENANCE、DEPENDENCIES、LICENSE，以及四个直接依赖和所有递归依赖的全部 Markdown。归档按 alias 展开，完整闭包为八包。

## 依赖与合同入口

下表前缀为职责别名，实际包位置由 RECIPE/LOCK 确定。合同正文随递归配方交付，源码仅为证据索引。

| 依赖 | 职责与必读合同 |
| --- | --- |
| control | 特权 CLI、schema-1 JSON、MCP、文件状态；SUBSCRIPTION_INTERFACE、STATE_CONTRACT、MACHINE_CONTRACT、DIAGNOSTIC_CONTRACT、MCP_CONTRACT 与 MCP_TOOL_SCHEMAS；递归包含 runtime |
| webui | 14 页、编辑器、桥接并发、国际化；DESIGN、SUBSCRIPTION_FLOW；只消费已协商控制面，不复制特权状态机 |
| delivery | 安装升级、组件、可信分发；EXTERNAL_ASSETS、RELEASE_CONTRACT；可安装 ZIP、失败恢复及 staged/effective 版本 |
| quality | 全产品设计、代码质量、性能证据；工程合同，不增加运行服务 |
| runtime（递归） | SUBSCRIPTION_CONTRACT、LIFECYCLE_CONTRACT、CONNECTIVITY_CONTRACT；统一订阅身份、事务与恢复 |
| engine / policy（递归） | CORE_LIFECYCLE、VLESS_ENCRYPTION、POLICY_INVENTORY；内核、加密、DNS 与路由次序 |

这些职责组成一个产品，不要求各自成为常驻服务或独立应用。跨组件接口可用进程、文件或库实现，外部行为与持久化兼容必须保留。

## 必须保留的行为

- **透明模式与状态：** 仅显式 `tun|ebpf`，默认 tun；不增加 auto、TProxy、Redirect、netd ALLOW_MULTI、CA 注入或已删除 MITM/capture 路径。TUN 使用 `magicnet0`；eBPF 使用 capability/cgroup/TC 证据。意图、观测、事务 phase、ownership 分开，缺证据写 unknown/pending/null。
- **日常使用（M67）：** 首页按已确认的来源与缓存建议导入、更新或启动检查；cacheCount 仅计远程原始缓存，本地来源上次成功且 cacheCount=0 同样可建议启动，缓存本身不表示节点或配置就绪。保留自定义配置的显式启动入口和内置节点直达。服务未知时主按钮只读刷新。自动引导等到服务与订阅读取成功、服务停止且来源和缓存均为空；不打断已有输入。订阅初始/读取失败、busy、queueDepth>0 或后台 running/timeout 时统一禁用来源、导入、更新和设置写入，保留草稿及重试。基线读取被取代且未投递时返回可识别失败，不报已提交。新前台操作取得反馈后，旧刷新停止后续排队；各异步操作只清理自己拥有的 busy/task。
- **控制面未知值（M68）：** `api select` 缺参返回用法错误且不选择节点；`service toggle` 遇 unknown 拒绝启停。有效透明配置缺失、损坏或存在多个透明入站时，effective 保持 unknown；事务目录存在但 phase 缺失/空/不可读时同样 unknown。机器状态与 canonical 采用同一判断，不以 configured 填补观测。
- **公开状态与隐私：** 每个域只有一个 `.state/machines/*.state` canonical 文件，原子发布；跨域使用可恢复事务。机器接口由 schema-1 dispatcher 完整接管，能力、写操作例外及错误语义遵守 control 合同。订阅、SSID/BSSID、节点名、密钥、原始 UID、设备标识及自由错误文本不进入公共状态、MCP 自动资源或发布物。
- **订阅与恢复（M11–M13、M30–M47）：** 保留多源整批事务、逐源原生数量下界、稳定身份、同名/冲突判断、来源归属、VLESS Encryption、B/C 草稿及回读。等价节点合并忽略显示名并保留来源；身份明确的同源引用随重命名更新。公共/私密来源共用 C-SUB-008 的有界零写入观察。
- **持久化与幂等：** 暂存目录晋升后，自有规则、缓存、Tailscale 路径和 checkpoint/last-known-good 继续有效，外部路径与停止意图保留。网络策略恢复保留最初完整共享 UID、策略与逐项进度；回执重放也先核对当前 marker、owner 和 journal。模块目录 manifest 及引用资源完整。
- **核心生命周期（M41–M43、M48）：** 启动超时不传入长期守护；核心就绪前由启动者回收，就绪后脱离旧命令组超时。Android mksh 32 位 PID 校验准确；日志尾读索引按请求行数分配。同步固定上游并保留 fork 协议和生产 tags；握手失败清理连接/回调，流挂接与关闭共享一致并发状态。
- **路由与 DNS（M49、M50、M55、M60）：** 保留 POLICY_INVENTORY 的五个指定拒绝目标及端口边界、16 个教育后缀和完整优先级。删除 Voice 专用脚本、Sukka 数据及 IP/端口规则，保留普通 ChatGPT 域名/应用、meta-openai、ai-chatgpt 和 DNS。受管未知域名使用经 proxy 的 doh-cloudflare；代理不可用时失败。缺失的 default_domain_resolver 使用 bootstrap-local-dns；已有 resolver、显式 profile、独立配置 DNS 图、国内/Direct/LAN/Tailnet 规则保留。只迁移精确旧官方模板 pin，保留自定义 repo/ref/digest。
- **安装与升级（M51、M54）：** 状态统一 `.state`，缓存/私密临时载荷统一 `.cache`；旧 `.local/state`、`.tmp` 作一次迁移输入。冲突保留目标并私密保存旧数据，失败不丢数据；移除旧 network-card 图标。安装/卸载共用固定 kamfw/launcher.sh，移除重复 lib/kamfw-web，保留浏览器回退、有界等待与错误传播。
- **锁与监督（M52）：** 配置锁记录实际执行 shell PID 和启动身份，活/暂停/未知 owner 保留互斥。停止先清理自有热点路由/DNS，再结束核心。fswatch 在有界锁内重查，重复启动保留健康 PID；长期进程不继承锁 FD。controller 与框架 lifecycle 锁分离、顺序固定；生成文件相对路径排除保留。用真实固定框架验证首次/重复/并发启停、忙锁与排除规则。
- **原生 TUN（M53）：** 按 sing-box 1.15 省略弃用 stack，生成器、模板、旧快照恢复与健康状态一致；更新 M29 的默认栈要求。native_tun_stack 与 effective.stack=default 表示配置。Android CLI 选择系统路由且无显式接口/网络绑定时，监控为空仍允许系统路由尝试；依赖真实接口的配置继续等待。失网取消旧异步更新，恢复后重置，不伪造接口或联网状态。
- **联网、诊断、打包（M56–M58）：** 低频 Google 检查、明确警告、持久指数退避及按证据恢复遵守 CONNECTIVITY_CONTRACT，界面只读缓存。正式包提供固定 curl/OpenSSL/zlib、内嵌 CA、许可和来源，在无系统 curl 的 Android 验证执行器及 TLS 正负控制。单文件诊断有界、脱敏、关联路由/核心/订阅，含 detached supervisor 日志与 HTTPS 能力；保留可解析 JSON 和真实阶段，只用已支持的只读入口。最终 core/full/别名/全部组件 ZIP 独立拒绝测试开发目录，夹具遵守 sanitize→split 次序。
- **Issue 修复（M61–M64）：** 订阅重启后恢复整组维护进程；TUN 健康检查读取实时路由；升级补全默认文件与订阅历史；TLS 与就绪失败保留有界脱敏诊断。采集失败保持原错误和验收条件。#436 现场路由丢失根因、#440 可信 NAS 入口的未完成范围见 [ISSUE_TRIAGE_2026-11-06.md](ISSUE_TRIAGE_2026-11-06.md)。
- **TUN 恢复与免真机回归（M66）：** 按 CON-005/CON-A08–A09，在既有 watchdog 独立观察自动路由，以启动宽限、连续确认、共享冷却和开机预算控制标准核心重启。固定 Android/KernelSU 模拟器主动删除精确自有 RPDB 规则并切换受控上联，以同应用 UID、依赖 RPDB 的非 DNS UDP 验证断流与恢复，保留 TCP 正反控制并记录上联断续前后路由、就绪与 TCP 实测；独立校验接收端/清理、外部网络归属、报告与源码身份，缺失或跳过不得通过。netd 网络重编号须由不变的网络元数据与接口/FIB 派生全局和逐应用 UID selectors，逐项核对完整字段和重复次数，仅替换 netId；其余规则变化仍失败。现场 OEM 触发原因与模拟器可复现恢复分开记录。

## 视觉与资源约束

视觉按 webui/DESIGN 与 Hybrid Mount 风格合同：中性浅灰底、白卡片、蓝色操作色；深色为炭灰与浅蓝。参考 [Hybrid Mount](https://github.com/Hybrid-Mount/meta-hybrid_mount) 的 `webui/src/ui/miuix/theme.css`，独立实现，不引入 SolidJS 依赖。公共卡片 24px 圆角，手机/宽屏分组间距 12/20px，标题 28–36px；保留安全区、44px 触达、键盘避让、焦点、减少动效、诊断草稿与全部入口。此约定覆盖早期 Fieldnotes 配色。验证 320px、390px、桌面、浅深主题及对比度；不新增机器写接口、持久字段、网络资源或 npm 依赖。

安装/更新仅使用带 ownership 的唯一事务目录，失败先恢复再清理；恢复失败保留唯一材料。清理分批遍历，不新增时间戳备份。UDP 索引达到 1024 项后在最后一项释放时丢弃空索引空间；小流量复用，保留分片锁、引用计数和旧连接不能删除新连接的规则。覆盖大批释放/重建及安装成功、失败、恢复、未知目录保护。

性能预算见 [PERFORMANCE.md](PERFORMANCE.md)。记录实际路径、输入、环境与基线；宿主微基准、短时回环、Android RSS、持续吞吐和续航分别验收。

## 独立重建边界

新构建上下文只接收完整递归 Markdown 配方和明确允许的通用工具/外部资源。从空实现目录开始，不读取、复制、调用旧 MagicNet 实现、历史源码或旧测试作为产品基线。源码路径不能成为补需求的前提。

允许复用经许可的固定 sing-box 协议/密码学实现、规则数据和第三方工具，范围由 engine 与 delivery/EXTERNAL_ASSETS 定义；标注复用来源。MagicNetRules 固定 `f3335f9420d07b8c50b26488df2a9492da6bbb44`，仅复用规则及必要描述/许可，并核实发行资产与提交对应。MagicSingBox 历史模板是观察来源；新默认配置依据 policy 完整合同生成。旧实现的六个嵌套子模块不是独立实现必须继承的结构。

[REWRITE_CONTRACT.md](REWRITE_CONTRACT.md) 的 M59 另定义观察原版后的跨层替换：同输入比较框架、Shell、CLI/MCP、WebUI、安装与打包的外部结果及持久化副作用，包含联网维护与诊断。该路径与无旧源码独立重建分别记录。只检查/打包配方无需初始化旧源码子模块。

## 实施、发布与验收

先建立公开接口和验收夹具，再实现依赖并集成完整模块。迁移旧状态时统一 producer/consumer，确认恢复依赖后删除旧路径；不长期维护两个公共事实源。先推送已授权源码提交，再更新主仓库 gitlink，保留未保存工作。

M65 与 delivery/RELEASE_CONTRACT 规定：主仓库选择 bump 或自定义 version/code、冻结源码与发行快照；源码仓库提供同版本构建与 Android 验收。主仓库静态权限分离只读/发布规划，计划、构建、Android、资产验证全部成功后才公开。稳定版公开后同步 updater 与 README；预发布保留稳定索引；同一 run 的恢复绑定原 artifact。操作见主仓库 docs/releasing.md。

日常迭代使用本地检查，不主动触发远程 CI。分别记录本地、模拟、真实网络、物理设备、正式发布和独立重建结果到 [VERIFICATION.md](VERIFICATION.md)。未获授权不重启用户设备、更改订阅、启用 MCP 或抓包。交付完整源码、依赖、安装物和实际验收证据；配方/提示词生成只完成材料检查。

## 系统证书策略

接入 runtime/CERTIFICATE_POLICY.md 的可恢复证书禁用脚本；默认关闭、开机不执行证书操作；显式启用时使用大陆公共 CA 关键词策略，用户随时预览、禁用、恢复。此功能不添加受信任 CA，不解密流量。

模拟器上联故障测试在 wlan0 down/up 后通过 Android Wi-Fi 服务关闭再开启以恢复 supplicant、关联和系统路由，独立延迟恢复 guard 使用相同动作；eth0 只恢复链路。恢复命令成功仅记录动作，最终仍要求该上联实际默认路由、TUN 状态、就绪与同应用 UID TCP 实测通过。报告记录 restore_method，门禁拒绝缺失或与上联不符的方法。
