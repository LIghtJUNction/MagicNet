# VLESS Encryption 客户端兼容合同

## VE-001：能力与边界

MagicNet 的 VLESS 出站必须完整保留用户配置的 Encryption。它是在既有传输/TLS 连接上执行的一层 VLESS 客户端握手，和 TLS、Reality、UUID、flow 不是同一个字段。启用 TLS 不等于启用 Encryption；关闭其中一层不允许暗中修改另一层。

固定 sing-box fork 871b7a3440cd9c850f1b09ef3b4ada9babb4384b 已有客户端字段、解析、初始化和连接包装；本轮并未运行其真实握手。该 fork 没有对应服务端 decryption 移植，重建目标不增加 VLESS 加密服务端。可以依原许可复用该固定实现；不得手写未经验证的密码学替代品并声称互通。

固定 MagicNet v1.8.0 的部分分享链接/原生 YAML/结构化编辑链路并未完整保留此字段。VE-002–006 因而同时是保留核心能力与修正管理层缺口的目标，不是旧产品已通过的宣称。

## VE-002：字段与语义

sing-box JSON 的 VLESS outbound 使用字符串字段 encryption；缺省/空字符串或精确 none 不启用额外加密，其他值必须经过核心解析和初始化，错误拒绝配置。不把布尔、数字、对象、大小写不同的 NONE 当作有效禁用值。

启用值的结构为：

~~~text
mlkem768x25519plus.<native|xorpub|random>.<0rtt|1rtt>[.<padding>…].<key>[.<key>…]
~~~

方法、appearance 和 RTT token 大小写敏感。至少包含一个 key；每个 key 是无填充 base64url，解码后为 32 字节 X25519 或 1184 字节 ML-KEM-768 公钥。第一段 key 前的后续短段（小于 20 个 ASCII 字节）按 padding 候选解释；出现 key 后，后面各段必须继续是 key。空段、缺 key、未知 token、非法编码、错误长度拒绝。原解析器对整串及后续段 trim；前端不能借此改写 key 内容或随意重排段。

语法/长度合格不保证公钥和 padding 初始化合格，更不保证服务器接受；仍须真实核心 check 与握手。完整 padding 合法性委托已声明的固定密码学实现，不以 UI 正则替代。1184 字节无填充 base64url 长度为 1579 字符，整个值超过 1600 字符；不得复用节点显示名的 128/256 字符限制截断。输入受现有有界完整配置/payload 限制，超限明确失败。

## VE-003：全路径保真

以下入口及后续操作必须保留完全相同的有效 Encryption 值和其他独立协议参数：

| 入口或操作 | 要求 |
| --- | --- |
| vless 分享链接，包括订阅正文、本地文本和 base64 包装 | 按 URI query 的定义解码 encryption 值一次；不能把不认识的非空值删掉或当 none，不能用其是否出现决定默默降级。 |
| Clash/Mihomo YAML 或转换器输出 | 格式可表达该字段时完整转换；不能表达/转换器会丢字段时拒绝该来源并保留旧有效状态。converter exit 0 不构成字段保真证明。 |
| sing-box JSON | 保留 VLESS outbound 的 encryption 及独立 TLS/transport/flow 字段；受控配置覆盖规则仍有效。 |
| 结构化自定义出站、私密覆写、配置编辑器 | 为 VLESS 提供完整值的显式私密输入/回读；schema 白名单接纳经过校验的 encryption，而非为方便开放所有任意字段。复杂传输仍遵循原受限结构化编辑范围。 |
| 保存、preview、apply、订阅刷新、selector replay、重启 | 候选到有效配置必须保真；只更改名称/来源顺序不能改变 Encryption。 |
| 私密备份恢复、失败回滚 | 按原字节恢复相关有效配置；公共支持包和状态不导出完整值或 key。 |

不支持的组合必须给出明确能力/解析失败，不能剥离必需字段后继续计入可用节点。无 Encryption 的普通 VLESS 继续兼容；修正导入不能破坏已有 UUID、server、TLS/Reality、flow 和传输参数。

## VE-004：错误、超时与资源

检查阶段错误不落盘；已开始激活后的失败按 runtime 事务恢复旧有效配置与选择。加密握手失败关闭新连接，不把失败连接交给 VLESS 数据层；取消/拨号截止时间必须约束握手等待并回收可证明属于本次请求的资源。

固定 fork 针对阻塞写入使用拨号上下文的写方向截止时间，结束后清除，不用会破坏 XHTTP 延迟绑定下载流的永久读截止时间替代。换一种实现也必须保持：超时不遗留无限等待的 URL 测试；握手成功后下载方向仍可用；没有既定 deadline 时不伪造一个无限期关闭读侧的操作。记录真实超时/取消结果，不声称所有内核/传输组合已经通过。

核心错误可能包含非法段或 key，公共诊断必须转为规范 token；本地私密编辑页可定位字段，但不把完整值写入通用日志、MCP 自动资源或 Issue 草稿。

## VE-005：公开验收矩阵

| 层级 | 输入与操作 | 预期 |
| --- | --- | --- |
| 字段保真 | 缺省、空、none、合法启用值分别经 JSON、YAML、分享链接、base64、本地和远程两源导入 | 缺省/禁用语义不变；启用值没有消失、截断或被 none 替代；可表达格式一致，不能表达者显式失败 |
| 长度与结构 | 真实测试密钥生成器生成 32/1184 字节公钥，三种 appearance、两种 RTT、合法 padding/多 key | 完整字段保存回读；以固定内核 check 的实际结果为准，不用全零占位值冒充可互通密钥 |
| 失败 | 未知方法/模式、空段、缺 key、有填充/非法 base64url、错长度、非法 padding/key、错误类型 | 非零且不激活，旧来源/配置/选择保留，公共结果不泄漏输入 |
| 编辑兼容 | 创建普通 VLESS，再增加 Encryption；切换 TLS/Reality；重复 preview/save/apply，再清除 Encryption | 各字段独立、可预览、可回读；原普通 VLESS 不回归；不支持组合清楚拒绝 |
| 生命周期 | 刷新、重排、同名节点、备份恢复、激活失败、进程重启 | 完整字段与来源归属保留，回滚准确，转换器开启/缺失两条路径分别测量 |
| 真实通信 | 受控且兼容的测试服务器、固定客户端 artifact，分别进行普通/加密 TCP/UDP 和支持的 TLS/传输组合 | 记录实际请求与响应、错误、关闭和超时；check 通过只记配置层通过；未提供服务端的组合标未运行 |
| 取消资源 | 半开服务器、URL 测试取消/超时、XHTTP 等支持的延迟下载侧 | 无无限遗留任务；成功握手后下载仍工作；失败连接关闭；不能仅以进程数量或日志字样判断 |

本轮未执行上述完整矩阵。根 VERIFICATION.md 仅记录旧原生解析分支的隔离丢字段/拒绝探针，不能替代核心、服务器或 Android 验收。

## VE-006：固定证据

核心路径：option/vless.go、protocol/vless/outbound.go、protocol/vless/lx_encryption.go、protocol/vless/encryption/client.go、protocol/vless/encryption/common.go 及对应解析/截止时间测试，全部来自本文件声明的完整 fork revision。

MagicNet 缺口路径：singbox_subscribe/parse.sh 的分享参数白名单与 VLESS JSON 输出；common.sh 的原生完整性检查；routing_overlay.rs 的出站字段白名单；RoutingEditor.vue 的 VLESS 表单。完整路径、观察范围和指纹由根 PROVENANCE.md / SOURCE_AUDIT.md 保存。它们是提取证据，不要求重建者复制旧代码结构。
