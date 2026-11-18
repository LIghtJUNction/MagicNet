# 控制面验收

本文件定义重建与维护验收标准；各场景实际执行的源码提交、主机结果及 Android 设备结果见根 VERIFICATION.md。

0.2.5 追加 DIAG-A01–A06（见 DIAGNOSTIC_CONTRACT.md），并验证 `connectivity.status` / `service.status.data.connectivity` 的同一缓存、capabilities 增量、未知/暂停/失败与新鲜度、纯状态读取零写入零公网请求。MCP 自动资源只读脱敏缓存；`--json connectivity tick` 和未设计的参数组合结构化拒绝。support.export 仅生成报告，不能借用 dispatcher 收尾 reconcile 改写 canonical。

1. --json 放头/尾各调用 capabilities，解析 stdout 恰好一个 schema-1；重复 flag/未知命令/service stop --json 返回非零结构化错误，不执行写命令。
2. 构造 PID 可见但 API 拒绝、API 正常但 TUN 缺失、PID 枚举失败、eBPF local attached 且 shared pending 的独立夹具；检查每层和 overall，不允许用一个 bool 覆盖未知。
3. 并发读取/发布 15 域，逐个 rename 注入失败；读不到半条文件，失败恢复已替换域；跨域读取走机器命令且不宣称全 OS 原子性。
4. 输入超大 JSON、FIFO、symlink、命令洪泛 stdout/stderr、保留 pipe 的孙进程、64 个卡住 helper、锁长期被持有；有界返回并清理可证明拥有的资源，不泄露秘密、不创建无限线程。
5. override 对象/数组/null、相同重放、旧 revision、外部改写和失败激活；检查 pending、conflict/busy/rollback_conflict 与原配置/用户停止意图。
6. MCP 未认证、错误协议、通知、重复/未知字段、私密文件 symlink（含 .state/hotspot、应用 UID/包名/selector、路由/屏蔽域名清单、block.conf、proxy-chain.json、dns-leak-guard 与 eBPF 共享接口名、network-access-recovery）、redact=false、generic 默认私密动作、人类 hotspot status/app 清单、人类 warp/node/route/block 默认清单及 diagnose 尾参；拒绝前无运行副作用。`--json hotspot status` 与 named `magicnet_hotspot_status` 仍只返回脱敏 envelope。named `magicnet_node_list` / `magicnet_node_current` / `magicnet_block_list` 仍是显式路径。
7. 在合成源、Wi-Fi、节点与错误里注入唯一 canary，扫描所有公共 JSON/canonical/resources/log tool 输出，不得出现 canary；explicit private inspector 只在对应明确调用返回必要数据。
8. 同一修改分别经人类 CLI、认证工具与 UI 调用，比较意图和 canonical；日志/状态刷新不得掩盖原失败退出码。
9. 执行 SUBSCRIPTION_INTERFACE.md 的 C-SUB-007 全部七组场景，覆盖 1/2/5 源跨入口一致性、候选与已提交数量分离、cache 文件数不当来源数、同名节点、owner/快照错误及公共 canary；capabilities 必须如实声明 subscription_batch_v1，旧版本回退和无历史批次的 null 独立验证。
10. batch 提交后仅 selector replay 失败时，退出码 0、committed、独立 warning 一致；UI 显示可重试警告，不能重复提交或谎称回滚。失败候选 index 仅映射同代冻结列表，重开没有候选时匿名显示。
11. 对运行时 LIFE-A01–A04 使用真实子进程检查一次性预算、父退出、超时清理与就绪后核心存活；内部启动入口带 `--json` 时仍只能返回结构化 unsupported，不能执行核心启动。
12. 日志尾读比较空文件、1 MiB 密集空行、CRLF、中文、末行无换行、坏 UTF-8、截断多字节字符、读取期间追加、零行内部请求及最大公开行数。旧版与新版输出逐字相同；文件字节/行数上限、脱敏与非普通文件拒绝有效，临时行索引只随请求行数增长。记录可复现局部基准与分配口径。
13. 执行 C-SUB-008：URL 清单与本地正文分别覆盖合法边界、超限、坏 UTF-8、NUL、symlink、目录/FIFO、权限错误、缺失和读取中改写。status/inspect 共用观测，失败非零且结构化；缺失父目录也不创建。canonical 与支持包未知来源/数量输出 unknown，service.status 保留其他独立事实；合成 canary 不进入任何公共错误/状态/支持包。检查只读调用前后的目录树和文件摘要。

14. 缺省 stack、显式旧 stack、无 TUN、非法 stack 分别返回 default、原值、unavailable、unknown；capabilities 声明 native_tun_stack，WebUI 保留 token，健康检查接受原生默认且指出旧字段需迁移。
15. 用带私密 canary 的 .cache、旧 .tmp、.local/state、directory-migration 与 symlink 别名测试通用文件读/列举拒绝；私密载荷正常读取消费，原有权限/硬链接/大小限制继续通过。

16. 使用同一 TUN 观测覆盖 auto_route 开/关、IPv4/IPv6、自定义表与优先级、redirect mark、必要规则缺失、仅热点 iif 或 fallback 残留、受限查表规则、错误设备路由及截断/失败/超时。Android 参数不支持、普通命名表及数字外观别名分别验证；RPDB/FIB 必须指向同一真实数字 ID，不能由错误表共同伪装为成功。health 与机器快照共享观测：机器字段在任一必要项已知缺失时为 false，无已知缺失而有未知时为 null；人类 health 用 warning/detail 区分缺失与未知。机器 snapshot 对 stopped/unknown 不执行路由探测，人类 health 可检查残留接口。RPDB/FIB 子命令只读，共享 3 秒截止时间，stdout/stderr 每流最多 256 KiB，不改规则/canonical、不发公网请求；真实 netd 网络切换及 App 流量须另记设备证据。

17. `api select` 分别缺 group、缺 node：非零用法错误、无 panic，不执行选择或创建 selector-selections.json；有效参数仍走既有选择逻辑。
18. 用 unknown 的进程观测执行 `service toggle sing-box`：非零拒绝，不调用 start/stop，watchdog marker 保留；running/stopped 的已支持分支继续正常。区分既有 canonical 收尾发布与服务写操作。
19. 固定 configured=tun/ebpf，分别提供缺失、坏 JSON、无透明入站、重复同型和混合透明入站；effective 均为 unknown。事务目录无 phase、空 phase、不可读 phase 同样 unknown，目录不存在仍为 idle。机器快照与显式 reconcile 后 canonical 一致，不泄露配置或原始错误。
20. 执行 C-SUB-009：trust set/clear 的合法、空/坏输入、边界与超限、锁竞争、恢复 pending 和原子保存；HTTP/本地候选的默认拒绝与精确授权。setup、列表、payload、安装与定时入口一致。check-source 不做 DNS 且成功无输出；resolve-source 核对起始来源与目标并在全部地址通过后才输出固定格式。trust/check-source/resolve-source 带 --json 均结构化拒绝且零写入；canary 不进入公共状态、MCP 自动资源、错误或支持包。升级有/无历史分别核对原记录与 never/未记录语义，不从已配置来源或有效配置补造成功。
21. 在 TUN 已覆盖必要范围的快照中加入同长或更具体的其他设备、blackhole/unreachable、linkdown 路由，IPv4/IPv6 均验证 unknown；不以 TUN 范围并集伪报 ready。对照范围外竞争项、被更具体 TUN 路由覆盖的宽泛回退及真正缺失，分别保持 present 或 missing。未知与另一项已知缺失并存时，机器 readiness 可为 false，但 runtime 不得据此累计完整缺失或自动恢复。
22. 独立配置保存覆盖已有/缺失配置、已有备份、无效 UTF-8 旧配置及 Tailscale auth_key 提取；旧配置恰为 8 MiB 时保留完整备份，超过一字节则拒绝且所有目标不变、私有 snapshot 清理；成功后配置、原字节备份、standalone 标记和变化的 keys 一致，私密文件权限保持。把备份、标记或 keys 目标替换为目录、链接或其他非普通文件，预检失败时旧配置及相关文件不变；逐次注入后续替换失败，核对已替换项回滚及错误传播。已提交后的清理失败须保留已提交事实。
23. 在候选校验期间将配置目录改名，并在原路径放入另一个真实目录或 symlink；保存必须拒绝，不能把旧目录中验证的候选或备份写入替代目录。以正常目录为对照，核对所有事务目标沿同一已验证目录身份完成预检、暂存与提交。
24. 用本地 HTTP 合成服务验证调用方正文预算为 0、1、8192 字节和 1 MiB 时的恰限与超一字节响应，分别提供和省略 `Content-Length`。恰限返回完整原字节，超限明确失败；仅发送超限声明头而不发送正文、无长度正文越限后不关闭连接，客户端均应提前拒绝。调用方大于 8 MiB 的预算不得提高原生总上限。回归头边界、HTTP 错误、重复或错误长度、截断响应、流首行及总截止时间；流的首行限制与完整响应预算分别生效。通过 API 调用边界核对预算传递，测量注明是否进入原生后备及临时分配/RSS 口径。

## 0.2.12 联网与选择回执

| ID | 场景 | 必须观察到的结果 |
| --- | --- | --- |
| C-CON-001 | 人类 connectivity check；普通/机器 status、health、MCP、诊断；未知 --json check | 显式 check 取得新结果且保留恢复预算；10 秒节流、queued/throttled 错误真实；人工 check 零恢复，其他读取零公网请求，未设计机器写命令结构化拒绝 |
| C-CON-002 | selected 出站失败而 mixed 成功及反向对照；旧核心、畸形响应、严格失败、0 ms 成功 | selected_proxy 与 mixed_proxy 各自准确，缺标记 unknown/probe_unsupported，真实 204 与合法 0 ms 被正确识别；mixed 失败保持 degraded；机器与人类输出一致并脱敏 |
| C-CON-003 | 选择保存失败、运行时 PUT/读回失败、外部新选择、原保存项缺省 | 保存失败非零且零 PUT；后续失败补偿原运行与保存值，缺省保持缺省；冲突报告 rollback_conflict 且不覆盖新选择，不宣称多组瞬时原子 |

## 本地面板资源

| ID | 场景 | 必须观察到的结果 |
| --- | --- | --- |
| C-UI-001 | 固定入口缺失、目录、文件、删除及元数据失败 | api.webui_ready 如实返回 boolean，人类 local_ready 共用判断；不读正文、不建状态/目录、不启动或下载 |
| C-UI-002 | 核心停止但文件存在；API ready 但文件缺失；服务与资源齐全 | 文件、API、进程、dataplane/overall 分别准确，面板信号不改变原服务合成或联网结论 |
| C-UI-003 | capabilities、私密 canary、旧 CLI 缺字段 | 声明 local_zashboard_readiness，命令目录不变；入口正文/canary 不进入公共结果，旧字段缺省可识别 |

## 当前节点候选（0.2.14）

| ID | 场景 | 必须观察到的结果 |
| --- | --- | --- |
| C-NODE-001 | 已提交 JP/US，旧 work tags 含 48 条 HK，候选含 HK；改变列表上限并加入重复和非成员节点 | 当前真实代理节点按既有成员、去重与限值输出；旧 tags 和候选不抢占名额；链式代理及显式节点列表一致 |
| C-NODE-002 | 有效配置省略 outbounds、null、空数组或仅非代理出站，且磁盘有旧节点缓存 | 返回空列表并清除旧节点缓存，不将空集误判为无法读取 |
| C-NODE-003 | 配置缺失、不可读、坏 JSON、非对象或 outbounds 错误类型，缓存开/关 | 仅不可用配置允许既有缓存回退，关闭时不回退；不宣称缓存是运行状态，不读取暂存候选和旧 work tags |
