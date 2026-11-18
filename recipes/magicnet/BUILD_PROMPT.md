# 重建 MagicNet（配方 0.3.33）

为 Android root 用户实现完整网络工作台：安装、订阅、应用/Wi-Fi/热点分流、节点、DNS、诊断与自动化控制。保留 [BEHAVIOR.md](BEHAVIOR.md) 的用户流程和 [ACCEPTANCE.md](ACCEPTANCE.md) 的 M01–M78；交付可运行产品。

## 平台、材料与布局

- 生产目标为 Android root/arm64，支持 Magisk、KernelSU、APatch；WebUI 使用模块管理器的 WebView/浏览器桥。Linux 与 x86_64 模拟器用于开发验证。最低 Android/WebView 版本未知；Java 桥的 API 26 目标不构成全产品兼容承诺。
- 语言、框架由实现者按特权边界、协议兼容和维护成本选择。WebUI 保留 zh-CN/en/ru；安装向导和菜单保留已有中、英、俄、日、韩及回退。机器 token、参数、配置和日志不翻译。
- 项目名保持 MagicNet。`recipes/` 为主要输入；实现放在独立小写连字符源码仓库，并以同名固定子模块接入 `generated/`。跟踪 `.gitmodules` 和 gitlink，不向容器提交普通源码。
- 当前维护实现为 `LIghtJUNction/magicnet-android@a97467513e5f3c9842b470112f31a961e2bc99b0`；全部固定依赖见 [DEPENDENCIES.md](DEPENDENCIES.md)，来源归属见 [PROVENANCE.md](PROVENANCE.md)。源码和观察 checkout 不属于 Recipkg 依赖或归档负载。
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
- **可信本地订阅（M69）：** 默认远程来源仍只允许公网 HTTPS。私有授权表仅按精确 HTTP/HTTPS origin 与明确的本地 CIDR 放行 NAS/Tailnet；每次请求、重试和重定向前验证全部解析地址，并固定数值目标。可选代理仅为显式端口的字面 loopback SOCKS5，不自动启动 Tailscale 或代理，不采用环境代理。CLI 授权修改不抓取或启动服务；WebUI 接受 HTTP 语法不代表授予网络权限。遵守 SUB-016、C-SUB-009、UI-SUB-013 的限制、私密与失败语义；升级保留设备授权和订阅历史，所有发布包剔除构建机授权，新装默认无授权。
- **持久化与幂等：** 暂存目录晋升后，自有规则、缓存、Tailscale 路径和 checkpoint/last-known-good 继续有效，外部路径与停止意图保留。网络策略恢复保留最初完整共享 UID、策略与逐项进度；回执重放也先核对当前 marker、owner 和 journal。模块目录 manifest 及引用资源完整。
- **核心生命周期（M41–M43、M48）：** 启动超时不传入长期守护；核心就绪前由启动者回收，就绪后脱离旧命令组超时。Android mksh 32 位 PID 校验准确；日志尾读索引按请求行数分配。同步固定上游并保留 fork 协议和生产 tags；握手失败清理连接/回调，流挂接与关闭共享一致并发状态。
- **路由与 DNS（M38、M49、M50、M55、M60）：** 保留 POLICY_INVENTORY 的五个指定拒绝目标及端口边界、16 个教育后缀和完整优先级。删除 Voice 专用脚本、Sukka 数据及 IP/端口规则，保留普通 ChatGPT 域名/应用、meta-openai、ai-chatgpt 和 DNS。受管未知域名使用经 proxy 的 doh-cloudflare；代理不可用时失败。缺失的 default_domain_resolver 使用 bootstrap-local-dns；已有 resolver、显式 profile、独立配置 DNS 图、国内/Direct/LAN/Tailnet 规则保留。只迁移精确旧官方模板 pin，保留自定义 repo/ref/digest。托管应用、自定义域名、广告规则按该顺序插入；保护 DNS、sniff/resolve/route-options 准备动作、模式、拒绝、LAN 与真实 Tailnet 规则，显式 action:route 不提高业务优先级，原数组保持原序。交错于后置保护前的用户规则保持已有优先级；六种物化顺序与重复应用结果一致。`.local` 与 RFC 6762 的 IPv4/IPv6 链路本地反向区域使用原生 mDNS，先于模式的公网 DNS；失败无公共后备，home.arpa 与 .lan 不因此获得本地解析。范围、边界与固定规则资产按 POLICY-A26–A33 验收。
- **安装与升级（M51、M54）：** 状态统一 `.state`，缓存/私密临时载荷统一 `.cache`；旧 `.local/state`、`.tmp` 作一次迁移输入。冲突保留目标并私密保存旧数据，失败不丢数据；移除旧 network-card 图标。安装/卸载共用固定 kamfw/launcher.sh，移除重复 lib/kamfw-web，保留浏览器回退、有界等待与错误传播。
- **锁与监督（M52）：** 配置锁记录实际执行 shell PID 和启动身份，活/暂停/未知 owner 保留互斥。停止先清理自有热点路由/DNS，再结束核心。fswatch 在有界锁内重查，重复启动保留健康 PID；长期进程不继承锁 FD。controller 与框架 lifecycle 锁分离、顺序固定；生成文件相对路径排除保留。用真实固定框架验证首次/重复/并发启停、忙锁与排除规则。
- **原生 TUN（M53）：** 按 sing-box 1.15 省略弃用 stack，生成器、模板、旧快照恢复与健康状态一致；更新 M29 的默认栈要求。native_tun_stack 与 effective.stack=default 表示配置。Android CLI 选择系统路由且无显式接口/网络绑定时，监控为空仍允许系统路由尝试；依赖真实接口的配置继续等待。失网取消旧异步更新，恢复后重置，不伪造接口或联网状态。
- **联网、诊断、打包（M56–M58）：** 低频 Google 检查、明确警告、持久指数退避及按证据恢复遵守 CONNECTIVITY_CONTRACT，界面只读缓存。正式包提供固定 curl/OpenSSL/zlib、内嵌 CA、许可和来源，在无系统 curl 的 Android 验证执行器及 TLS 正负控制。单文件诊断有界、脱敏、关联路由/核心/订阅，含 detached supervisor 日志与 HTTPS 能力；保留可解析 JSON 和真实阶段，只用已支持的只读入口。最终 core/full/别名/全部组件 ZIP 独立拒绝测试开发目录，夹具遵守 sanitize→split 次序。
- **Issue 修复（M61–M64）：** 订阅重启后恢复整组维护进程；TUN 健康检查读取实时路由；升级补全默认文件与订阅历史；TLS 与就绪失败保留有界脱敏诊断。采集失败保持原错误和验收条件。#436 现场路由丢失根因、#440 可信 NAS 入口的真机验证范围见 [ISSUE_TRIAGE_2026-11-06.md](ISSUE_TRIAGE_2026-11-06.md)。
- **TUN 恢复与免真机回归（M66）：** 按 CON-005/CON-A08–A09，在既有 watchdog 独立观察自动路由，以启动宽限、连续确认、共享冷却和开机预算控制标准核心重启。固定的一次性 x86_64 Android/KernelSU AVD 在稳定的单 eth0 上联下主动删除精确自有 RPDB 规则，并执行 eth0 down/up，以同应用 UID、依赖 RPDB 的非 DNS UDP 验证断流与恢复，保留 TCP 正反控制并记录上联断续前后路由、就绪与 TCP 实测；独立校验接收端/清理、外部网络归属、报告与源码身份，缺失或跳过不得通过。netd 网络重编号须由不变的网络元数据与接口/FIB 派生权限对应的全局规则和逐应用 UID selectors，逐项核对完整字段和重复次数，仅替换 netId；其余规则变化仍失败。现场 OEM 触发原因与模拟器可复现恢复分开记录。

CON-A09 先验证模拟器身份与 adb 控制链路，保存原 Wi-Fi 启用状态并通过 Android 服务临时关闭 Wi-Fi；在有界等待内取得连续两次相同的单 eth0 netd/RPDB/出口基线后才允许注入。固定镜像的 eth0 是模拟蜂窝接口，故障前须将唯一默认 phone/数据订阅、启用状态与当前 CONNECTED/WWAN/eth0 连接及 netd 网络编号对齐。使用 `cmd phone data disable/enable` 控制其真实生命周期；关闭后须有界确认用户/有效数据均关闭、连接状态断开、当前精确连接为空、接口 DOWN，且 netd 旧 eth0 网络已销毁。仅允许原逐应用 UID 元数据精确转移到 UNREACHABLE，其余元数据不变；重新启用后原归属恢复，只允许 eth0 netId 更新。保留独立延迟 enable guard 并核对 `restore_method=android_mobile_data_toggle`，恢复后仍须实际路由、就绪与应用 TCP 成功。finally 恢复并核对原 Wi-Fi 启用布尔值，准备、关闭或恢复证据缺失即失败。报告保留 `cellular_lifecycle` 三阶段证据；受控蜂窝重连与 Wi-Fi 切换恢复分别验收，临时 Wi-Fi 开关不证明后者。

## 故障恢复一致性（M70）

M23 热点状态按 runtime 0.1.20 的有效配置范围与 FIB 共用观察器判断：合法静态排除后的分段路由可就绪；条件、竞争及不确定配置保持 unknown，已知必要证据缺失保持 pending。机器 JSON 与 canonical 一致，继承只读与脱敏边界，不能以配置或单条默认路由证明转发。查询表 2022 使用规范的独立 argv，严格夹具与完整模拟安装环境都必须验证。

connectivity 与 Wi-Fi watcher 的启动、重复启动和停止使用同一有界生命周期互斥，停止等待已进入启动流程的实例完成登记后再清理；常驻子进程不持有控制锁。已退出的 Wi-Fi watcher 可清理，活进程身份读取失败保持 unknown。

TUN 所需地址被同前缀或更具体的其他接口、blackhole 或 unreachable 路由覆盖时，观察结果保持 unknown，且不授权自动恢复；排除范围及被更具体 TUN 前缀覆盖的宽泛 fallback 保留。

未过期的 TUN present/missing 缓存必须属于当前单一核心的 PID/starttime；核心更换、PID 复用、多核心或不可读时只读投影为 unknown。paused、clock/summary unknown 与 stale 前置语义保留，not_required 不核对启动代际；读取不改文件、预算或探测次数，不能把旧核心的绿色显示给新核心。

FIB 先根据 route_address 扣除 route_exclude_address，忽略目的前缀完全位于必要范围之外的路由。相交路由的非零 `tos` / `dsfield`、未知或缺失条件值、源地址及多路径选择器保持 unknown；明确数值零继续默认匹配。无关条件路由不得使完整覆盖变为未知，也不得掩盖必要范围的明确缺失。健康、机器 readiness 与 watchdog 共用判断，按 runtime 0.1.20 的 CON-A08 验证 IPv4/IPv6、范围外、排除区间与相交对照。

独立配置保存将配置、原始字节备份、验证标记与 Tailscale 密钥纳入已有文件事务，预检所有目标，并在替换失败时回滚；提交使用与校验一致的目录身份。候选与旧配置备份沿用编辑器 8 MiB 上限，有界读取，超限在任何目标写入前失败。既有提交后暂存清理错误保持明确语义，断电或 SIGKILL 的跨文件持久原子性不在该保证内。

分流编辑器仅提交所选协议允许的认证字段，修改 URL-test 成员保留已有测速地址和间隔。卸载清理使用现有内核锁，整个尝试被终止后可重新执行，活跃清理者保持互斥；锁异常返回失败，后台 timeout 与告别页进程不继承卸载锁。

## 视觉与资源约束

视觉按 webui/DESIGN 统一：中性白浅底与近黑深底，蓝色用于操作和选中，语义色配合文字表达真实状态。普通分区以标题、对齐和 24/32px 留白组织，常规控件与必要容器圆角 8–12px、弹层 16px；保留输入、编辑器、危险提示和焦点边界。Logo 返回概览，低频入口保留在更多菜单或快速跳转；去除重复上标、宣传式副标、模型署名、卡片堆叠和装饰性无限动效，路径静态展示原有机器事实。保留 14 页、三语、草稿、危险确认、44px 触达下限、键盘避让和减少动效。检查窄屏、横屏、桌面、浅深主题与文字对比度；接口、持久字段和运行依赖沿用现有合同。

M78 按 webui 0.2.11 和 control 0.2.13 提供显眼的本机 Zashboard 入口：点击时读取新鲜 service.status，分别核验 API 与本地资源，旧 CLI 只读校验回退，目标限制为同 loopback origin 的 /ui/ 且保留 setup 参数。跨入口共享 busy；失败可重试且不自动启动或下载。运行中将其作为概览主操作、停止为次级，管理面板的维护细节默认折叠，保留全部功能与原确认。

M73 将概览、节点、订阅、应用作为四个日常直达入口，其余十页通过更多访问；高级页深链接和快速跳转须揭示当前导航。概览默认保留状态、启停、刷新、检查网络、异常与下一步，将进程、综合服务检查、实际模式与 RSS 放入运行详情，将透明模式、热点、Wi-Fi 和服务管理放入网络设置，两组默认折叠。重启移入服务管理，原确认和队列门控保留；独立流量路径页展示静态说明，示意图不证明联网，实时证据从概览运行详情与诊断查看。折叠不隐藏关键错误、未完成更新或初次设置，也不改变设备意图或后台任务。

M74 按 runtime CON-006/LIFE-010 处理核心已退出而监督循环仍运行的情形：watchdog 非阻塞取得既有配置/生命周期锁，在锁内重新确认核心仍停止、模块启用且未取消后，复用停止后清理。只撤销已证明归属的 DNS 捕获、guard、自有路由并恢复热点 offload 原值；忙锁、活跃/未知核心、停用或取消不清理。失败保留证据由后续 tick 重试，不启动核心、不新增公网探测，清理后继续报告 paused。手动 check 自身不执行清理；核心停止时仍待处理的观测请求不得阻止后台 tick 按上述条件清理。schema=1 与状态域保持。

安装/更新仅使用带 ownership 的唯一事务目录，失败先恢复再清理；恢复失败保留唯一材料。清理分批遍历，不新增时间戳备份。UDP 索引达到 1024 项后在最后一项释放时丢弃空索引空间；小流量复用，保留分片锁、引用计数和旧连接不能删除新连接的规则。覆盖大批释放/重建及安装成功、失败、恢复、未知目录保护。

性能预算见 [PERFORMANCE.md](PERFORMANCE.md)。记录实际路径、输入、环境与基线；宿主微基准、短时回环、Android RSS、持续吞吐和续航分别验收。

M71 将本地 API 正文预算和保守路由归一化纳入集成：原生后备在读取期间执行调用方上限，超限明确失败；默认规则只消除完整相邻覆盖的 53 快速规则，并合并相邻同目标的纯规则集分发。完整边界见 control 的运行资源与验收第 24 项、policy 的 POLICY-A34–A37。保留 HTTP 首行采样、路由状态屏障及用户策略；沿用现有接口与依赖。报告分别给出超限请求的内存边界、规则对象变化和设备网络实测，不以其中一项代替其他指标。

## 独立重建边界

新构建上下文只接收完整递归 Markdown 配方和明确允许的通用工具/外部资源。从空实现目录开始，不读取、复制、调用旧 MagicNet 实现、历史源码或旧测试作为产品基线。源码路径不能成为补需求的前提。

允许复用经许可的固定 sing-box 协议/密码学实现、规则数据和第三方工具，范围由 engine 与 delivery/EXTERNAL_ASSETS 定义；标注复用来源。MagicNetRules 固定 `c4ad0a94f35af2b7950b47362e1c23e583209790`，仅复用规则及必要描述/许可，并核实发行资产与提交对应。MagicSingBox 历史模板是观察来源；新默认配置依据 policy 完整合同生成。旧实现的六个嵌套子模块不是独立实现必须继承的结构。

[REWRITE_CONTRACT.md](REWRITE_CONTRACT.md) 的 M59 另定义观察原版后的跨层替换：同输入比较框架、Shell、CLI/MCP、WebUI、安装与打包的外部结果及持久化副作用，包含联网维护与诊断。该路径与无旧源码独立重建分别记录。只检查/打包配方无需初始化旧源码子模块。

## 实施、发布与验收

先建立公开接口和验收夹具，再实现依赖并集成完整模块。迁移旧状态时统一 producer/consumer，确认恢复依赖后删除旧路径；不长期维护两个公共事实源。先推送已授权源码提交，再更新主仓库 gitlink，保留未保存工作。

M65 与 delivery/RELEASE_CONTRACT 规定：主仓库选择 bump 或自定义 version/code、冻结源码与发行快照；源码仓库提供同版本构建与 Android 验收。主仓库静态权限分离只读/发布规划，计划、构建、Android、资产验证全部成功后才公开。稳定版公开后同步 updater 与 README；预发布保留稳定索引；同一 run 的恢复绑定原 artifact。操作见主仓库 docs/releasing.md。

日常迭代使用本地检查，不主动触发远程 CI。分别记录本地、模拟、真实网络、物理设备、正式发布和独立重建结果到 [VERIFICATION.md](VERIFICATION.md)。未获授权不重启用户设备、更改订阅、启用 MCP 或抓包。交付完整源码、依赖、安装物和实际验收证据；配方/提示词生成只完成材料检查。

## 系统证书策略

接入 runtime/CERTIFICATE_POLICY.md 的可恢复证书禁用脚本；默认关闭、开机不执行证书操作；显式启用时使用大陆公共 CA 关键词策略，用户随时预览、禁用、恢复。此功能不添加受信任 CA，不解密流量。

## 可复现依赖与发布（M72）

固定 fork 提交、规则清单和组件摘要；兼容依赖更新同步所有锁文件。输入下载成功后仍须校验摘要，损坏缓存重新获取，错误页面与摘要不符的内容保持失败。新建发行从创建响应取得数字 ID，再按既有身份和资产门禁上传公开。TLS/GoTLS 文本诊断显式选择 hook 来源，继续遵守时长、输出和进程过滤限制。

生产组件、AVD 安装载荷与 WebUI 的审核过的下载候选须同步固定版本。yq 的 AVD 构建直接读取生产锁；eCapture 的跨 ABI 资产分别固定并审核摘要，生产版本变化但 AVD 未审核时在早期合同检查失败。Zashboard 默认与候选下载使用审核过的同版资产，不使重装操作回退到旧版。

## 当前代理验证与有界恢复（M75–M77）

M75 按 runtime CON-007 与 engine 0.2.4，通过指定 proxy 组当前出站的严格 GET/204 接口验证 Google 和 Cloudflare；独立 mixed 观测不能替代当前代理结果。核心构建显式包含 with_lx_probe，CLI 检查严格标记、expected_status、ok 和真实 http_status；缺失能力不成功，不据此自动切换。

M76 的恢复候选最多三个，来自同组已有真实代理；候选双目标通过后，在现有锁内复核成员与选择，checked 保存、运行时 PUT、两侧读回，并立即复验真实路径。保存失败零运行时变更，其余失败补偿旧运行值与旧保存值；原缺省保持缺省，外部新选择报 rollback_conflict 且不覆盖。跨组是顺序可补偿批次，不宣称瞬时原子。共享冷却、订阅刷新间隔、TUN 次数和用户停止意图继续生效。

M77 提供人类 cli connectivity check 显式重测，解决长退避中仅显示旧失败的问题；概览“检查网络”仍打开诊断页，既有 ping 工具不代替严格双 HTTPS 204。人工 check 只探测、10 秒节流，不清空恢复预算，不新增 --json/MCP 写命令。普通页面刷新、status、health、MCP 和诊断保持只读。主机夹具、实际核心、Android、真实公网与发布结果分开记录，既有 M73 界面及 M74 退出清理完整保留。
