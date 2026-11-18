# 特权控制面

交付单一受控入口 /data/adb/modules/MagicNet/cli，供用户、模块脚本、WebUI 和 MCP 使用。内部语言可变，argv、JSON、数据隐私和退出状态稳定。阅读 CLI_REFERENCE.md、MACHINE_CONTRACT.md、SUBSCRIPTION_INTERFACE.md、DIAGNOSTIC_CONTRACT.md、MCP_CONTRACT.md、STATE_CONTRACT.md 和 ACCEPTANCE.md。

依赖 runtime 负责实际进程生命周期、订阅与网络策略；必须委托它的事务，不在 MCP 或 WebUI 再建一套特权逻辑。集成验收：人类 CLI、schema-1 和认证工具操作同一设备状态，同一失败不被包装成成功。

control 0.2.10 按 SUBSCRIPTION_INTERFACE.md 的 C-SUB-009 管理私密订阅信任清单，并提供仅接收来源 scheme、host、port 的检查与解析入口。来源授权统一委托 runtime/SUB-016；check-source 不做 DNS，resolve-source 验证整条下载链和全部解析地址后才输出私密执行器数据。trust set/clear 复用配置锁与订阅来源锁，恢复 pending 时拒绝，不触发下载或重启；不新增机器写例外、MCP 自动披露或状态域。公网 resolve-host 继续保持原保护。

control 0.2.3 增加 C-SUB-008：公共 sub.status、私密 sub.inspect、canonical producer 与支持包共用有界来源观测。URL 清单 64 KiB、本地正文 8 MiB；坏编码、NUL、链接、非普通文件和超限明确失败，缺失允许未配置。读取不创建任何目录或文件；canonical 与支持包的未知来源/数量不能伪报为零，service.status 保留独立服务事实。

## 人类入口

connectivity.status 与 service.status 共用缓存观测；support bundle/export 按 DIAGNOSTIC_CONTRACT.md 的 DIAG-A01–A08 执行有界、脱敏、原子导出及机器回执。保留启动失败日志、固定 HTTPS 执行器来源、必要章节与完整性，分别验证主机和 Android 的真实文件。普通读取和采集不探测公网、不 reconcile、不自愈；自动恢复由 runtime 的单一 producer 负责。

保留 CLI_REFERENCE.md 的命令族与参数。`api select` 缺 group/node 返回用法错误，不触发节点选择或写 selector 意图；`service toggle sing-box` 仅据已确认的 running/stopped 决定启停，unknown 报错并保留 watchdog 意图。help 可读；错误非零退出；日志保留原语种/token。health 与 transparent status 是诊断入口，不存在 cli ebpf status。
Android 模块根必须由可信可执行路径/固定安装位置确定，不能由调用者 MODDIR 重定向特权代码。宿主夹具可显式使用独立 MODDIR；本地 API 仅允许 loopback HTTP 端口，拒绝远端/userinfo/路径混入。
privileged 子进程不能执行任意拼接 shell；文件 payload 有界、私有、校验归属与路径。凭据不放 argv，不在输出预览泄露。

## 机器入口

任意位置出现 --json 都由机器 dispatcher 完整接管；恰好一个 flag，未支持命令给结构化错误，禁止回落成人类写路径。stdout 只有一个 JSON，诊断 stderr；错误保留非零退出。
capabilities 是实际命令/字段能力事实源；status 默认脱敏，inspect 明确私密且用户主动调用。generic MCP 文件读取不得绕过 named inspect：应用 UID/包名、selector/node 名、路由/屏蔽域名清单、block.conf、proxy-chain.json、dns-leak-guard 接口名和 network-access recovery journal 走拒绝或显式私密工具。generic `magicnet_cli` 还拒绝人类 warp/node/route/block 默认清单；named `magicnet_node_list` / `magicnet_node_current` / `magicnet_block_list` 仍是显式路径。显式设计的 override、module-update、network-access 写例外必须保留各自并发、幂等、确认和回滚。
配置值与运行值用 configured/effective；null/unknown 不等同于 false/stopped/success。有效配置缺失、损坏或重复透明入站时 effective 为 unknown，不回退 configured；事务目录存在但 phase 缺失、空或不可读时为 unknown。机器快照与 canonical 共用判断；普通失败路径的收尾观测发布不表示执行成功。状态读取不应偷偷发布 canonical 或更改用户意图。

service.status 的本地面板增量以 MACHINE_CONTRACT.md 为准：local_zashboard_readiness 声明 api.webui_ready，固定入口文件元数据与独立 api.ready/数据面/进程状态分别报告。人类 webui status 共用观测；不新增命令、状态域、下载或运行依赖。旧 CLI 缺字段按 webui 合同兼容，不能补造成功。

## 运行资源

命令/proc helper 在 spawn 前占用有界槽，同进程最多 64 个活跃或延迟回收子进程，一条共享 reaper；卡在内核的子进程保留槽，饱和拒绝。取消/超时关闭父端句柄，不生成无限等待线程。stdout/stderr 都公平有界读取，溢出与截断不能当作合法 JSON。
生命周期锁有截止时间，报 busy，不无限等 flock。JSON 配置/selector/Tailscale 读取 4 MiB 边界；Wi-Fi 名单和私密 curl stdin 64 KiB；拒绝 FIFO、symlink、非普通文件。curl 凭据走 stdin，超时、输出截断或输入交付失败明确失败。
资源数值是来源合同，不是推测的总 RSS 或速度保证。选择另一实现时必须通过相同可观察压力与清理验收。

本地 API 的原生 HTTP 后备必须在接收过程中执行调用方正文预算，使用调用方上限与既有 8 MiB 总上限的较小值。`Content-Length` 超限时在头解析后失败；无长度响应只按剩余预算加一个探测字节读取，超限即失败，不先收集到全局上限再丢弃。恰限完整响应保留原字节，超限不输出截断成功。16 KiB 头限制、总截止时间、HTTP 状态及 framing 校验保持；流式统计继续按 16 KiB 首行限制采样，首行预算不替代整条响应的声明长度限制。可信 curl 与原生路径共用调用方预算语义，失败后不重发写请求。正文预算、临时分配、进程 RSS 与核心常驻内存分别记录。

独立配置保存按 STATE_CONTRACT.md 将有效候选、旧配置备份、standalone 标记及本次变化的 Tailscale keys 纳入同一现有事务。全部目标先预检，再暂存和提交；后续替换失败回滚已替换项。校验与提交绑定同一目录身份，目录被换成另一个真实目录也必须在写入前拒绝；备份保留旧文件原字节。候选与旧配置使用编辑器既有 8 MiB 上限有界读取，恰限允许，超限在进入事务前失败。

命令预算由当前调用读取一次，创建 shell worker 时移除一次性 `MAGICNET_COMMAND_TIMEOUT` 覆盖。持久核心的启动、就绪交接和失败清理遵循 runtime/LIFECYCLE_CONTRACT.md；内部启动命令不绕过 `--json` 的机器分派。

MCP 与人类 CLI 的日志尾读共享同一快照语义：最多读取快照尾部 1 MiB，按原规则处理截断首行和无效 UTF-8，最多输出 1000 行，保留顺序、CRLF 与空行的处理规则及脱敏行为。定位末尾 N 行只扫描所需后缀，不为整个文件建立行数组；有效 UTF-8 直接复用读取缓冲区。用固定输入比较结果、临时分配和耗时，不把局部日志优化宣传成整机内存或网络吞吐提升。generic `magicnet_cli` 拒绝人类 `hotspot` / `hotspot status`；`file_list` / `file_read` 拒绝 `.state/hotspot` 及其 symlink 别名。接口名、客户端网段和回程对端只留在人类 CLI 与私密 journal，不能经 MCP 自动路径泄漏。`--json hotspot status` 与 named `magicnet_hotspot_status` 仍是脱敏入口。

## 本包补充材料

- [CLI_REFERENCE.md](CLI_REFERENCE.md)
- [MACHINE_CONTRACT.md](MACHINE_CONTRACT.md)
- [MCP_CONTRACT.md](MCP_CONTRACT.md)
- [STATE_CONTRACT.md](STATE_CONTRACT.md)

- [MCP_TOOL_SCHEMAS.md](MCP_TOOL_SCHEMAS.md)：完整已观察的工具目录。
- [SUBSCRIPTION_INTERFACE.md](SUBSCRIPTION_INTERFACE.md)：C-SUB-001–009，完整多源入口、公共/私密读取、逐源批次能力、计数、恢复、共享只读观测与显式来源授权；subscription_batch_v1 是重建新增能力，不能假称旧源码已经实现。

## 0.2.4 目录与默认 TUN 栈

遵守 STATE_CONTRACT.md 的 `.state`/`.cache` 布局及迁移私密边界，遵守 MACHINE_CONTRACT.md 的 `native_tun_stack` 能力和 `effective.stack=default` 语义。全部私密载荷入口与前端路径同时迁移，错误时不执行写动作；不增加新的机器写命令。

## 0.2.7 TUN 实时路由证据

Android 使用系统实际支持的只读命令参数，不能因桌面工具选项在设备上不可用而长期误报未知。路由表必须按配置的实际数字 ID 核对；命名表以及看似数字的表别名都不得被猜作该 ID，RPDB 与 FIB 采用同一无歧义身份。Android 对配置规则窗口与 redirect fallback 内的每条相关 lookup，包括数字外观输出，以无歧义数字表过滤快照逐条核验。无法取得该证据时保持 unknown，不退回只看接口，也不把原始别名或命令错误写入公共摘要。

TUN 健康与机器 readiness 共用一份解析和有界只读观测逻辑。接口存在只是前提；auto_route 启用时，按有效入站配置及固定核心的默认值推导表号、优先级、地址族与 redirect marks，核对必要策略路由组及目标表中 TUN 转发路由对必要静态范围的覆盖。每地址族按显式 route_address（缺省全族）减静态 route_exclude_address 推导，不要求固定 default 或两条 /1；默认模板的私网/ULA 排除仍可验证。route_address 与 route_exclude_address 各字段最多 1024 个前缀，超限保持 unknown；普通非 redirect 路径的动态地址集未观测时保持 unknown，不能把原生 auto_redirect 仅用于 netfilter 的动态集合误当成 FIB 输入。仅热点 iif 残留、fallback 或受限规则不能替代应用路径所需规则。保留 Android 的 per-network 路由表模型，不要求 main 表必有默认路由，不假定 UID 2000 代表所有应用。

TUN 路由的范围覆盖不能掩盖同表竞争前缀。有效 TUN 路由已覆盖必要范围，但其中存在其他设备、不可转发或 linkdown 路由，且受影响范围未被更具体的有效 TUN 路由完全覆盖时，路由证据为 unknown；不猜测 metric 等未观测的优先关系。范围外路由和已被更具体 TUN 路由覆盖的宽泛回退不误报冲突；该未知证据不能授权自动恢复。

每轮 RPDB/FIB 子命令共享 3 秒截止时间，stdout/stderr 每流最多 256 KiB；这不是整个 health/export 的总耗时或 CPU 解析硬截止。任一必要项已知缺失时机器字段为 false，即便另项未知；没有已知缺失而有读取失败、超时、截断或无法解释的证据时为 null。人类 health 显示 warning 及对应 detail。auto_route=false 不强行要求自动规则；eBPF 保持独立附着检查；机器快照对 stopped/unknown 核心保留原语义且不探测路由，人类 health 仍可能检查残留接口。检查不产生公网请求、规则写入、后台循环、自动重启或 canonical 发布，不返回原始地址/规则列表。必要内核资源存在仍不证明真实应用流量已成功。

## 0.2.12 显式联网检查与选择错误

新增人类 `cli connectivity check`，通过同一受控 producer 取得新联网观测，只探测、10 秒节流，保留自动动作/订阅冷却、TUN 预算和停止意图。普通 status、health、MCP、支持包及 WebUI 刷新仍只读；不新增 --json 或 MCP 写入口。所选代理的严格双 HTTPS 204 与独立 mixed 路径各自显示，不以旧核心 delay 或路由组的成功掩盖当前节点失效。

api select 的持久化错误必须非零返回，保存失败不触碰运行 API。使用既有锁复核、checked 保存、运行时 PUT、双读回与失败补偿，外部新选择返回 rollback_conflict 且不被覆盖；跨组操作保留顺序批次语义。命令成功、节点网络可用与系统应用流量成功分别呈现，公共状态保持 schema=1 与脱敏边界。
