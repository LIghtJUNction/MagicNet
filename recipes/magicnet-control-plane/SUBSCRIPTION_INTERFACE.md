# 订阅入口、状态与逐源结果合同

本文件是重建输入。C-SUB-001–004 提炼自固定的 v1.8.0 源码；C-SUB-005–007 是本轮为多来源可诊断性和错误恢复补充的明确要求，不能声称旧二进制已经提供。原有命令、schema=1 和私密边界继续有效。订阅业务规则由 runtime 的 SUBSCRIPTION_CONTRACT.md 定义，界面由 webui 的 SUBSCRIPTION_FLOW.md 定义。

## C-SUB-001：入口不能把批量列表降成单 URL

| 入口 | 输入与可观察行为 |
| --- | --- |
| cli setup <url> / cli sub set sing-box <url> | 一个 URL；是替换来源并尝试更新，不是向旧列表追加。接受 singbox 兼容别名的旧入口保持兼容。 |
| cli sub set-file sing-box <base64-lines> | base64 解码后的 UTF-8 换行列表；先校验全部来源，再进入共同更新事务。 |
| cli sub apply-file sing-box <base64-lines> | 同样接收 base64 编码的 UTF-8 URL 换行列表，保留兼容入口；它不是任意本地路径或订阅正文读取。 |
| cli sub update sing-box / all / cli sub update-all | 更新已保存的来源，不能把其中第一个 URL 当作整批。 |
| cli sub clear | 清除订阅来源，保留当前已验证内核配置及工作的网络；存在未恢复事务时拒绝清除。 |
| cli sub resolve-host <hostname> <port> | 校验主机名与端口，解析全部地址并检查公网策略，成功逐行输出排序后的 IP；仅检查解析及地址策略，不下载内容，不证明 URL、令牌、TLS、订阅格式、转换、合并或代理连接可用。 |
| cli webui payload create/append/remove | 私有文件传输入口，命名空间 tmp 或 subscription；每块独立 base64 解码，累计上限 8 MiB。文件名 1–128 个 ASCII 字节，只允许字母、数字、点、下划线、连字符，首字节不能为点。拒绝路径、链接及错误归属，私有权限。 |
| cli webui payload apply-subscription <safe-basename> | 一次消费 UTF-8 URL 换行列表；受控消费即去除重放入口，读取、校验或应用失败均不得遗留可被再次执行的私有 payload。 |
| cli webui payload apply-subscription-source <safe-basename> | 一次消费本地订阅正文（可以是 JSON/YAML/分享文本等），不是 URL 列表，也不是聚合配置的 JSON envelope；同样在受控消费时去除重放入口。 |

URL、User-Agent、过滤器与周期是分开的现有写入口，不存在聚合配置 JSON envelope。UI 来源保存前可先保存并回读 UA；后续来源失败不能宣称已自动撤销 UA。具体先后与草稿语义按 webui 合同。完整 URL 列表与本地正文按上表传输，不把 JSON、换行或查询字符串拼成 shell 命令。旧 argv/base64 入口仅作兼容，不把秘密值记录进命令历史、公共任务标签或支持包；新 UI 使用私有 payload。普通写入口仍返回真实退出码，不能为了统一输出而让 --json 落回人类 dispatcher 执行写操作。

## C-SUB-002：公共 sub.status 的现有字段

cli --json sub status 只输出一个 schema=1、ok=true、command=sub.status、data 对象；错误 envelope 规则不变。下列路径相对于 data。

| 路径 | 类型与语义 |
| --- | --- |
| source.mode | remote_url 或 local_file；local_file 是单个已保存本地来源，不是零个订阅。 |
| source.configured_count | 当前已提交的远程来源数量；本地模式为 1，未配置远程来源为 0。与最近失败候选数可以不同。 |
| update.lock_present / transaction_pending | bool，分别代表锁记录和待恢复事务存在；存在不能证明任务正在运行。 |
| update.owner | active / none / stale / pending / unknown。active 才证明运行；none/stale 对应 running=false；pending/unknown 对应 running=null。 |
| last.phase / result / generation_id | 最近尝试的阶段、结果与代次。stored result=running 但 owner 已确定 none/stale 时报告 interrupted。不能把旧成功变成本次结果。 |
| last.attempt_epoch / success_epoch | 已知尝试和成功的 Unix 秒；旧协议没有记录时为 0，0 不能当作新成功。 |
| last.configured_count / source_count | 最近尝试登记的候选数与解析流程来源计数；不能替代当前 source.configured_count，也不能仅凭 source_count 推断每个来源都是本次新下载。 |
| last.imported_count / skipped_count | 本次记录的节点数量和跳过数量；转换前原始行数、过滤后节点数与同名去重后数量不能混为一谈。 |
| last.has_reason | bool，仅表示内部原因存在；不返回原始 reason、响应正文或 URL。 |
| last.source_mode | 旧运行时登记的 url / local 等来源 token；与 source.mode 的 remote_url / local_file 是不同字段，客户端不能按字符串相等比较。 |
| last.native_parser / native_node_count | 原生识别类型与节点计数；unknown/0 不构成某种协议受支持的证据。 |
| last.converter_enabled / available / attempted / format / result | 保留旧 token 类型，不把字符串 0/1 自动改成布尔或把未尝试显示成失败；新客户端按能力与完整 schema 读取。实际字段名分别为 converter_enabled、converter_available、converter_attempted、converter_format、converter_result。 |
| cache.entries / source_entries / provenance_entries | 三个独立计数。entries 包含多种普通缓存文件；source_entries 是来源缓存数量，不能把一个来源的正文、identity、usage 三个文件当作三个订阅。 |
| cache.identity | url_sha256_identity；摘要只在私密归属检查中使用，不能取列表位置替代来源身份。 |
| refresh.event_count / error_count | 有界近期日志窗口的统计，来源实现至多读取最后 200 行；不是进程或设备的终身累计量。 |
| schedule.interval_hours / enabled / owner / running / owner_valid | 周期 off / 12 / 24 / 48 / 72 及独立 scheduler 所有权；与一次订阅 updater 的 owner 分开。未知 owner 对应 null，而非运行正常。 |

公共 JSON、canonical 文件和自动 MCP 资源禁止含 URL、hostname、节点/selector 名、URL 摘要、用户标识、凭据和原始错误。需要展示具体来源时，只有用户本地私密编辑页可以把有界 index 与自己的已验证草稿/回读内容对应。

## C-SUB-003：私密 sub.inspect 与用量

cli --json sub inspect 必须在 capabilities.private_commands 中单列。其 data 复用相同生命周期投影，额外提供 configuration.sing_box_urls（有序字符串数组）、configuration.user_agent（字符串）、configuration.filters（字符串数组）与 source_usage（数组）。用户主动进入订阅编辑流程时安静读取；不经过通用命令捕获、日志、Issue 生成或自动诊断。

每个 source_usage 行包含 id（规范 URL 的 SHA-256 小写十六进制）、index（1 起始）、hostname、state（fresh/cached/unknown），及 upload_bytes、download_bytes、total_bytes、expire_epoch、updated_epoch。缺失/无效数值是 null；字节数须为不超过 9007199254740991 的非负整数；时间须为正整数且不超过 253402300799。expire=0 或越界不能显示成已到期。fresh 只表示该条可信元数据的新鲜度，不证明全部订阅或代理通信成功。

用量以完整来源身份绑定，不能按 index、域名或节点名匹配；来源重排、同主机不同查询令牌都必须独立。最近更新失败/中断时，旧 fresh 最多显示 cached；待提交事务不展示新用量；本地模式 source_usage 为空。URL 或 generation 在观察期间改变，返回 machine.snapshot_changed 并拒绝混合快照。它是变更检测，不是全 OS 原子快照；临时多次读取同值也不证明没有 ABA 变化，重建应使用受控代次/锁保证同次投影。

来源配置读取上限 64 KiB，User-Agent 检查读取上限 1 KiB，过滤器读取上限 8 KiB，独立用量元数据上限 2 KiB；合法业务输入的更小限制仍按 runtime 合同。必要配置意图的 symlink、特殊文件、超限或格式错误使 inspect 结构化失败，错误不回显私密值。可选用量 metadata 缺失、不可信、损坏或超限时只保留该来源行并降为 unknown/null，不删除来源或使全部配置读取失败。页面刷新失败时可保留用户草稿，清空未经确认的即时用量与有效状态并标未知。

## C-SUB-004：单一状态与 MCP

subscription canonical 的 schema/domain/state/phase/result/owner/source/configured_count/generation/update_lock/transaction_pending 保留；subscription-refresh 独立保存 schedule_hours/enabled/state。state 的决策顺序为：active→running；pending→pending；unknown→unknown；无活动 owner 但事务存在→recovery_pending；否则按实际 result 成功、失败、中断或 idle。刚建立而 owner 尚未发布的锁有 5 秒初始化宽限，不能当作已运行，也不能被读取端删掉。

MCP 的 magicnet_subscription_status 和自动 subscription 资源调用脱敏机器状态。显式命名的 magicnet_subscription_list 才是私密 URL 读取；set、set_singbox_lines、update、update_all、schedule 保留既有工具名、参数和校验，最终委托同一运行时。generic magicnet_cli 拒绝 sub inspect/list/get、敏感默认读取及私密路径旁路。不能因某命名工具可读私密内容，就把它挂到自动资源。现有 MCP_TOOL_SCHEMAS.md 不因新状态字段而悄悄重命名工具。

## C-SUB-005：本轮新增 subscription_batch_v1

这是重建必须实现的增量能力，固定旧源码尚无此特性。在 capabilities.features 增加 subscription_batch_v1，保持 machine_schema=1 和已有命令名。协商成功后 sub.status / sub.inspect 的 data.last.batch 为 null 或下表对象：从未接受更新、旧数据迁移无逐源证据时用 null，不能补造 generation 或成功记录。新客户端面对不支持的旧版本显示“逐源结果不可用”；支持但为 null 时显示“尚无逐源记录”，两者均不得按聚合结果编造各源成功。

| 字段 | 精确规则 |
| --- | --- |
| schema | 整数 1。 |
| generation_id | 非空、不含私密值的代次 token，须与同次 last.generation_id 相等；每次接受新的更新任务建立新代次。 |
| requested_count | 控制面实际收到的列表去掉空行后、该控制面去重前的条数；不是设备看不到的 UI 原始草稿行数。输入接口不接收注释行。UI 若已去重再投递，requested_count 就是投递条数；UI 原始行数/重复数另行显示。已保存来源更新时为保存列表条数，本地为 1。 |
| unique_count | 按 runtime 统一 URL 身份去重后的候选数量，远程接受范围 1–5，本地为 1。它不是旧已保存数量。 |
| outcome | running / committed / rolled_back / recovery_pending / interrupted / unknown。只有整个配置及来源事务提交后为 committed；成功使用同源缓存时也可 committed，但每源须标 cached。 |
| sources | 按候选首次出现顺序排列，恰好 unique_count 项；index 为连续 1 起始整数。没有 URL、hostname、URL hash 或显示名称。 |
| sources[].stage | validate / fetch / parse / convert / merge / check / activate / complete / unknown。是本次实际到达的阶段，不用 DNS 检测成功跳到 complete。 |
| sources[].fetch_result | fresh / cached / failed / not_attempted / not_applicable；本地来源用 not_applicable。cached 必须有同源内容与 provenance 证据。 |
| sources[].convert_result | success / not_needed / failed / not_attempted / unknown；原生解析完整且不需要转换时为 not_needed，不能假报转换器成功。 |
| sources[].parsed_count / imported_count / filtered_count / duplicate_count | 非负整数或 null。解析未到达/无法计数用 null；imported_count 是经过规定过滤、真实语义去重后由该源贡献的数量。同名不同节点不属于 duplicate_count。 |
| sources[].error_code | none / input_invalid / source_limit / url_policy / dns_failed / tls_failed / download_timeout / download_failed / response_too_large / cache_untrusted / format_unsupported / converter_unavailable / conversion_failed / semantic_incomplete / node_invalid / empty_result / merge_failed / config_invalid / activation_failed / rollback_failed / interrupted / unknown。只允许这些 token，不拼接 URL、主机或子进程原文。 |
| error_code | 同一枚举，记录整体失败阶段；整体 merge/check/activate 错误不倒填成每个来源下载失败。 |
| warning_code | none / selector_replay_failed；提交后重放选择失败用后者，和 error_code 分开。 |

输入预校验拒绝或争锁 busy、尚未接受任务时，不覆盖其他 owner 正在发布的 batch，也不伪造一个已经回滚的新 generation。客户端使用本次返回的规范错误；已接受任务必须留下可恢复代次。取消导致任务确实终止后报告 interrupted；只关闭页面、前端超时或取消等待，不代表设备任务已取消。

sources 的 index 永远属于该 generation 的候选列表，失败后可以与当前已保存列表不同。UI 只有保有同 generation 的冻结候选时才能私密映射到具体来源；重开、换草稿或没有该候选时，只显示匿名“来源 1/2…”，不能套用旧配置或当前草稿的域名。明确私密回读如以后增加候选详情，须另行设计并协商，不能把恢复 journal 直接公开。

generation 与本次 UI 任务的绑定必须来自受控任务回执：同一 task/operation 标识、被接受的执行者身份与其公布的 generation 有可验证关联。不能仅轮询到最新 last.generation_id、比较数量或看到一次更新发生就把它认作自己的任务。缺少可信关联时继续匿名显示，不丢草稿、不宣布本次保存已确认；可提示重新读取最终配置核对。此要求可由现有受控后台结果通道实现，不授权新增任意机器写命令或把私密候选公开。

批量提交不可丢掉失败来源后只保存成功子集。任一来源无可接受的新内容也无可信同源缓存，整批失败；旧已提交来源、有效配置及选择保留，outcome 为 rolled_back 或 recovery_pending。逐源下载成功与整批提交成功分开。已提交后的 selector replay 若失败，沿用旧完成函数的成功退出码 0 与独立 stderr 警告，同时 batch 保持 committed、error_code=none、warning_code=selector_replay_failed；UI 显示“订阅已提交，选择恢复待重试”。不能把已提交来源伪装为回滚，重试只恢复选择，不重复提交订阅。

## C-SUB-006：读取失败和代次一致性

配置文件确实不存在可表示未配置；权限错误、特殊文件、超限、解析失败和观察竞争不能被吞成 configured_count=0 的成功响应。返回 machine.subscription_observation_failed 或 machine.snapshot_changed，非零退出且零写操作。字段类型不合规、batch 数组缺项/重复 index、代次不一致时，客户端拒绝整份新投影，保留草稿并标状态未知。

公共状态读取不下载订阅，不启动 updater，不回收锁，不提交 journal。后台 producer 随阶段变化主动发布，跨页面和重开后可恢复；网络流量是否可用仍由数据面及真实业务验收独立判断。

## C-SUB-007：跨入口验收

1. 两源/五源用完全相同合成列表分别经 set-file、WebUI payload 和命名 MCP 批量工具提交：有效来源、顺序、节点集合、generation 与回读一致；不能循环调用单源 set 得到最后一个来源。
2. 已保存 A，提交 A+B 且 B 超时无同源缓存：source.configured_count 仍为 1，batch.unique_count=2，B 为 download_timeout，outcome=rolled_back；不能用旧 last.result=success 显示本次成功。
3. A+B 均可用但节点同名不同端点：两源各贡献 1，最终保留 2；仅把 B 改名不能决定能否导入。完整重复节点按 runtime 合同合并并归属首源，第二源计 duplicate_count。
4. A 缓存、B 新下载：来源顺序改变仍正确归属；B 缺 metadata 不影响来源计数，相关用量为 unknown/null；同域名不同查询令牌不得复用缓存。
5. raw status fixture 中 cache.entries=3、source_entries=1、configured_count=1：UI 与支持包只能报告一个来源；域名可解析但 HTTPS/转换失败须保持失败。
6. owner unknown、5 秒初始化窗口、stale PID、残余 journal、读取 I/O 错误分别验证 null/pending/interrupted/recovery_pending/结构化失败；状态读不产生修复副作用。
7. 在 URL 查询、UA、节点名称、转换器 stderr 填合成 canary；扫描公共 JSON、canonical、MCP 自动资源、Issue、任务标签，均不得泄漏；明确本地 inspect 可按需读取编辑值。

以上是重建验收，不是本轮对旧版全部接口的运行结果。实际提取/探针结果统一记于根 VERIFICATION.md。
