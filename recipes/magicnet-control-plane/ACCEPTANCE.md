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

16. 使用同一 TUN 观测覆盖 auto_route 开/关、IPv4/IPv6、自定义表与优先级、redirect mark、必要规则缺失、仅热点 iif 或 fallback 残留、受限查表规则、错误设备路由及截断/失败/超时。health 与机器快照一致：任一必要项已知缺失 false；无已知缺失而有未知时 null。机器 snapshot 对 stopped/unknown 不执行路由探测，人类 health 可检查残留接口。RPDB/FIB 子命令只读，共享 3 秒截止时间，stdout/stderr 每流最多 256 KiB，不改规则/canonical、不发公网请求；真实 netd 网络切换及 App 流量须另记设备证据。
