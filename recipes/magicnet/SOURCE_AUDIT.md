# 0.3.0 源码提取与重建准备记录

日期：2026-10-29（Asia/Taipei）。任务来源：[MagicNet #426](https://github.com/LIghtJUNction/MagicNet/issues/426)，用户要求读取源代码、更新配方并准备重建。本轮交付是完整递归配方的增量更新；没有修改 Android 实现、变更源码 gitlink、发布新 Android 版本或对用户设备执行操作。

本文件第 1–5 节先记录基线源码 `0dca28dd984d82333707cbf4b222596934b4d847` 的发现与未知；后续“源码修复补记”单独记录当前未发行源码的改动和验证，不回写成基线原有能力。

## 1. 固定输入

| 对象 | 固定版本 / 用途 |
| --- | --- |
| MagicNet 配方仓库 | 0a773436c3b21a56931bbfc77b323c42218cf52b，原根包 0.2.1 |
| 实际产品源码 | LIghtJUNction/magicnet-android，0dca28dd984d82333707cbf4b222596934b4d847；模块标记 v1.8.0 / 10608；tree bcb709f66bc2eb6a19021bd2f969f7cf2fa2198a |
| 固定内核 | LIghtJUNction/sing-box，871b7a3440cd9c850f1b09ef3b4ada9babb4384b；只针对 VLESS Encryption 读取相关源码及测试，未全面审查内核 |
| 源码提取指南 | LIghtJUNction/software2prompt，4920378377332c0ca9779ede6062029fb15dacdb 的 SKILL.md、references/analysis.md、模板；另读本项目固定 software-to-prompt 技能 6f6ac21a8b398f09102c5f8b1f7d6f92fce0399c |
| Recipkg 工具 | recipkg/recipkg 09ae99eed53ceb97afb46f0e87999c5e50297825，固定 CLI 子模块 recipkg/cli-source d0879adba69989cfe3edc7cf0d069a7b139f6410，版本 0.1.1；只运行离线 extract/check/pack/build 材料命令 |

已通过 GitHub 连接器读取 #426 正文和评论列表；读取时无评论。Android 报告设备与宿主合成测试不是同一环境。报告正文的订阅、设备身份及原始日志不复制到配方。

## 2. #426 能证明什么

报告称每个订阅单独可拉取，多个一起不能拉取，域名检查成功。附带机器状态是一次单来源成功：source.configured_count=1、last.configured_count=1、last.source_count=1、last.imported_count=60、last.result=success。它没有提供多源失败那次的完整候选、阶段、转换输出或提交结果。

因此只能保留“用户报告多源失败，现场原因未确定”。域名解析不证明下载、转换、节点完整性、合并、核心校验、配置提交或真实流量。旧状态中的 cache.entries=3 也不代表三个订阅：同一来源可以产生正文、identity 和用量等多个文件。

## 3. 本轮沿实际调用链读取的范围

| 能力 | 关键源码与证据 | 对应配方 / 新验收 |
| --- | --- | --- |
| 多源入口与来源事务 | commands.rs；subscriptions.rs 的 normalized_subscription_text、set/apply/clear、私有 candidate；webui_payload.rs | runtime SUB-001/002/011–015，control C-SUB-001–007；M30–M34 |
| 下载、身份、缓存 | singbox_subscribe/fetch.sh；source identity、每跳地址校验、重试和用量 | runtime SUB-003/004/009，SUB-A01–18；M31/M33 |
| 格式、转换、节点合并 | singbox_subscribe/common.sh、parse.sh、proxylink.sh、config.sh、update.sh；实际函数隔离探针 | runtime SUB-005–008/010；M32/M36 |
| 公共与私密状态 | machine.rs:465–539；machine/subscription.rs；state.rs:387–487；mcp_server/rpc.rs/tools.rs | control SUBSCRIPTION_INTERFACE.md、MACHINE_CONTRACT.md、STATE_CONTRACT.md；M34 |
| WebUI 完整路径 | SubscriptionsPage.vue、subscriptionPreview.ts、utils.ts、useMagicNet.ts、backgroundTasks.ts、machineStatus.ts、subscriptionUsage.ts、设置卡片、本地文件与相关测试 | webui UI-SUB-001–012、UI-SUB-CASE-01–10；M30/M35 |
| VLESS Encryption | 固定 fork 的 option/vless.go、outbound.go、lx_encryption.go、encryption/client.go/common.go 及相关测试；MagicNet 原生解析、RoutingEditor.vue 和 routing_overlay.rs | engine VE-001–006，runtime SUB-005，policy POLICY-A07；M36 |
| 增量分流与订阅重叠 | routing_overlay.rs、overrides.rs、RoutingEditor.vue、config-overrides 文档与原测试 | policy POLICY-A01–07；M38 |
| 安装包别名 | scripts/package-components.py:246–251 | delivery 包及身份验收；M39 |

路径相对于已固定的源码仓库；这些位置是审查证据，不要求构建者复制内部函数或先读取旧实现。源码未运行分支标静态证据；测试存在不等于本轮运行。

## 4. 已确认缺陷与明确修正

### S-AUDIT-01：同名不同节点让合并误判不完整

旧 proxylink.sh 先逐源转换，再调用有效节点计数；config.sh 的计数按规范 tag 保留首项。随后把跨源去重数量与原生提取的未去重数量比较。两个源各自一个可转换的同名节点就可能由 2 变成 1，被判定为转换不完整。复杂 transport 无法原生回退时，整个更新被拒绝。

本轮使用真实原生提取、计数、合并与 selector 生成函数；转换器输出为合成夹具，未运行真实转换器。A、B 各含一个 Trojan gRPC 节点，显示名 shared-name、server 分别为 a.example.invalid / b.example.invalid。仅变更 B 的显示名作为对照。

~~~text
single_a: native_count=1 native_complete_rc=1 merge_rc=0 result=1 0
single_b: native_count=1 native_complete_rc=1 merge_rc=0 result=1 0
combined_same_tag_different_endpoint: expected_native_count=2 merge_rc=1
combined_unique_tags: expected_native_count=2 merge_rc=0 result=2 0
~~~

探针退出 0 表示成功证明上述旧缺陷，不是修复验收通过。它与 #426 现象相容，但没有证据证明该用户的来源含同名节点或走到此分支。

重建按 SUB-006/007：每个来源独立证明语义完整；同名但不同连接语义的节点全保留，真正重复才可合并并保留来源归属；稳定身份不能随来源顺序漂移。不能通过删掉完整性检查让批量导入“通过”。

### S-AUDIT-02：不同入口采用不同 URL 身份

旧 UI 的 URL 序列化保留 fragment；Rust 文本入口按 trim 后原串去重；shell 在 SHA-256 前剥离 fragment。相同输入因此可能在三个阶段产生不同来源数或缓存身份。

重建采用 SUB-002 的共同规范，保留签名 query 的字节、参数顺序、重复 key、path 大小写及已有 percent 编码，不能按域名合并账户。旧缓存必须能证明同一来源才迁移。这个修改是新增目标，尚未在产品中实现。

### S-AUDIT-03：套餐 metadata 行数被误当作来源数

旧 SubscriptionsPage 的来源总数取 usageRows.length；subscriptionUsage 中只要 sourceUsage 非空就用该数组，未补齐缺 metadata 的其他已配置来源。machineStatus 虽验证配置数量，并未要求 metadata 覆盖每个来源。

这是一条静态确认的展示风险：已有两源而 metadata 仅一条时可能显示一源。#426 的设备 status 本身为一源，不能据此认定是该展示风险所致。UI-SUB-007 与 M35 要求数量来自配置，用量缺失保留 unknown 行。

### S-AUDIT-04：VLESS Encryption 在管理链路丢失

固定核心有 VLESS 客户端 Encryption。MagicNet 原生 YAML 完整性检查接受带 encryption 的节点，但输出 JSON 不写此字段；分享链接完整性白名单连 encryption=none 也不接受；结构化出站白名单和表单缺该字段。

本轮对真实原生解析函数做隔离探针，仅替换框架 bootstrap；使用合成值，未启动内核或网络。

~~~text
yaml_complete_rc=0
{"type":"vless","tag":"Synthetic","server":"example.invalid","server_port":443,"uuid":"00000000-0000-0000-0000-000000000001"}
yaml_emit_rc=0
link_encryption_none_complete_rc=1
~~~

输入含非 none 的 encryption，输出却缺该字段。探针只证明此原生分支丢字段/拒绝，不证明完整转换器路径或实际握手。VE-001–006 要求所有已支持入口保真、长 key 不截断、核心检查与真实通信分层验收；不增加服务端 decryption 能力。

### S-AUDIT-05：配方接线与精确验收遗漏

补齐 $magicnet_routing 的边界、冲突、归属、订阅刷新后 reset 等专项；统一 tag 的 UTF-8 字节计量与域名规则规范化。补齐 magicnet_installer.zip 与另外两个核心包名称的字节/模块身份相同合同。

重建入口不再要求先递归初始化旧 MagicNet 实现。check/pack/build 只需 Markdown 依赖闭包；编译已发布 v1.8.0 的源码路径继续单独保留。

## 源码修复补记：当前未发行改动

以下改动针对固定基线中已确认的四类缺陷，仍是未发行源码。它们不证明 #426 的现场根因，也不替代 Recipkg 配方验收矩阵要求的完整场景。

| 缺陷 | 当前源码处理 | 限制 |
| --- | --- | --- |
| 同 tag 不同端点的节点被首项吞掉，并让总数比较误判转换不完整 | 计数和合并按规范 tag 与完整节点语义比较；同 tag、同配置可折叠；同 tag、不同配置在没有引用时按完整连接语义生成稳定 SHA-256 后缀；冲突 tag 被 `detour`、selector 成员或 `default` 引用时拒绝候选。安装恢复路径也改用新组装器接口。 | 不同原始 tag 即使连接配置相同仍保留，因为现有数据没有可靠来源归属，不能安全合并后把选择归给某一来源。逐来源 `parsed/imported/duplicate` 计数和真实转换器完整性仍未实现。 |
| WebUI、Rust、下载器对 fragment、host、默认端口及路径编码的身份不同 | WebUI、Rust 持久化和 shell 下载统一到 HTTPS 规范请求身份：移除 fragment、规范 scheme/host、默认端口和空路径，保留 ASCII path/query 字节顺序并按 UTF-8 字节编码原始非 ASCII 后缀。下载前先规范化、去重、检查最多五个唯一 URL；列表不合法或超限时不发起部分抓取。machine source usage 与缓存使用同一规范 URL 摘要。 | 未运行真实订阅网络请求、旧缓存迁移或 Android UI/设备回读；原始非 ASCII 主机的接受范围仍需按 runtime 合同单独核对。 |
| 已配置来源缺 metadata 时，UI 少显示来源行并按 metadata 数量计数 | 行与计数改由同一私密 inspector 的已配置 URL 列表决定；缺失或含糊 metadata 时保留该来源行并显示 unknown。 | 未运行浏览器或设备验收。 |
| VLESS `encryption` 在原生解析、分享链接、自定义出站和编辑器链路丢失 | 分享参数白名单及完整性检查接纳字段；YAML/链接转 JSON 保留它；结构化 override 只允许 VLESS 的受界字符串；编辑器提供私密输入并回读。 | 这不证明所有转换器格式/组合都支持，也不证明核心握手或真实服务器互通。 |

完整的逐来源批次观测 `subscription_batch_v1`、真实转换器跨来源归属、真实服务商多源输入、核心检查与设备验收仍是未完成合同。不得据当前静态改动关闭 #426 或把未发行源码写成 Android 修复已部署。

## 5. 全产品保留覆盖表

本表分母是既有根行为的全部 17 项日常流程，加首次安装、菜单、分发、独立重建边界。除标记“本轮深入提取”的条目，其余合同保留既有固定证据，本轮没有重新证明其全部实现。任何单项未验不能靠整体“覆盖”字样消除。

| 功能族 | 权威材料 | 本轮覆盖状态 / 后续验收 |
| --- | --- | --- |
| 首次安装、引导、升级恢复 | 根 BEHAVIOR、delivery | 保留；真实管理器与设备待验，M01/M12/M21/M39 |
| 服务生命周期、显式 tun/ebpf | runtime、engine、control | 保留；M02/M03/M19/M22，设备挂载与数据包未运行 |
| 订阅导入、缓存、刷新、清空 | runtime SUBSCRIPTION_CONTRACT | 本轮深入提取与合成探针；M04/M28/M30–M34 |
| 节点选择、urltest、代理链、业务 selector | runtime、policy POLICY_INVENTORY | 订阅碰撞/选择保留深入提取，其余保留；真实出口待验 |
| 应用策略与结构化分流 | BEHAVIOR、policy、control、webui | v1.8.0 增量路由审查；M05/M18/M38，真实 UID/应用未运行 |
| Wi-Fi / 热点 / DNS | runtime、engine、control | 保留；M06/M23/M24，多 OEM/IPv6/热点回程待验 |
| JSON 配置编辑与模板同步 | webui、control、policy | 保留；M07/M14，模板真实同步未运行 |
| 持久覆写与冲突回滚 | control MACHINE_CONTRACT、policy | 本轮核对增量归属；M07/M38，未运行 Rust 整套 |
| IPv6、MTU、UDP、CIDR与预检 | runtime、engine | 保留；M15，设备及另一 VPN 共存待验 |
| OEM 网络限制检查/修复/撤销 | runtime、control | 保留确认/候选/只读边界；M11/M24，真机待验 |
| 广告/域名规则与 WARP | policy、runtime | 保留；规则资源/真实 matcher 未重验 |
| Tailscale 生命周期与真实业务 | runtime、engine | 保留；M10/M25，DISCO/TSMP/应用连接分别待验 |
| 内嵌面板/连接管理/统计 | webui、control | 保留；旧证据不外推为当前浏览器通过 |
| 诊断、支持包、备份、终端 | control、webui | 订阅披露/错误边界深入提取，其余保留；M16 |
| eCapture 主动诊断 | control、BEHAVIOR | 保留既有用户主动边界；无 CA/MITM 回归，未抓包 |
| MCP 认证/私密工具/自动资源 | control MCP_CONTRACT / MCP_TOOL_SCHEMAS | 订阅 dispatcher 静态核对；M09/M34；本轮未启动 MCP 服务 |
| 官方模块后台更新 | delivery、control | 保留；M12/M13；未下载/安装正式更新 |
| 14 页、多语言、草稿与无障碍 | webui DESIGN / BUILD_PROMPT / SUBSCRIPTION_FLOW | 订阅链路深入提取，其他页保留；M08/M14/M35，浏览器/触屏待验 |
| 操作菜单、非交互与确认 | BEHAVIOR、delivery | 保留；未运行管理器音量键 |
| 性能与长期稳定性 | PERFORMANCE | 旧基线保留；M17/M26/M29，本轮无新性能数据 |
| VLESS Encryption | engine VLESS_ENCRYPTION | 核心静态证据+管理层解析缺陷探针；M36，真实互通未验 |
| 配方递归交付与独立重建 | BUILD_PROMPT、DEPENDENCIES、ACCEPTANCE | 本轮材料验证；M37；独立软件重建尚未执行 |

## 6. 重建输入与执行顺序

1. 只把根包及八包完整递归 Markdown 归档/完整 build 输出交给新的构建上下文；保留所有 M01–M39、SUB、C-SUB、UI-SUB、VE、POLICY 要求。源码审查索引不构成读取旧 MagicNet 实现的许可，也不能把旧测试实现当作重建依赖。
2. 允许复用已声明且固定的 sing-box 协议/密码学实现、规则数据和通用工具；在结果中列清来源/版本/许可及复用范围，不将复用内核或规则数据宣称为新写成果。
3. 从空实现目录先交付控制面/状态的兼容边界和合成夹具，再贯通订阅输入→各源→合并→check→事务→同代回读，以及 Encryption 保真。内部语言、类和模块组织仍可重选。
4. 完成其余既有功能并集成 Android 模块；执行全部所属包验收和根集成验收。原型、静态页或只包装旧 MagicNet 不算完成。
5. 每层单列通过/失败/跳过/未运行：材料检查、原实现静态证据、旧函数合成探针、真实转换器、核心 check、浏览器、Android 设备、真实业务流量、独立重建对比。先固定产物再对比，不能拿本轮旧函数探针当新实现结果。
6. 验证后按已有仓库布局交付源码、依赖锁、构建/测试命令、安装物和按要求编号的结果；进入已授权源码分支再更新主仓库 gitlink。准备配方这一步不修改当前源码固定点，不推送不存在的实现。

## 7. 标准库与依赖决策

本轮已读 Recipkg 标准库目录 README（观察内容 blob d9ef7c95477fb29a5dfe826045195a0f22d7d19c）。目录没有可替代 MagicNet 多源事务/Android 数据面的完整配方；jq/regex 等仍明确提取中，不能把有限样例当完整工具兼容保证。继续使用已核实的八包依赖图与原有 software-quality；本轮没有新的视觉方向决策，不为修订订阅行为强加额外设计依赖。jq 等通用工具与固定加密内核继续是明确的外部实现前提，不冒充已独立重建的配方组件。

## 8. 未决项与交付含义

仍缺 #426 失败批次的真实证据、真实转换器的全部复杂格式/Encryption 对照、Android 原生桥到内核的多源事务、实际加密服务器、多 OEM、热点 IPv6 和长时稳定性。最低全产品 Android/WebView 版本与性能预算仍未知。

0.3.0 已将本轮可提取行为和修正规则写成完整可交付输入；“可开始重建”不等于已经证明全产品一比一重建成功。已运行的命令和具体限制见 VERIFICATION.md；历史 v1.8.0 的构建/设备记录继续归属原版本，不改写成此轮新结果。

## 9. 2026-10-30 内核同步准备（配方 0.3.2）

当前主仓库为配方与发布入口；`magicnet-android@b113f5128549172da6cb1f6e62f0b42d31adb956` 包含最新前端和生命周期修复，内核从独立 fork 的固定 gitlink 构建。`MagicSingBox` 是默认配置仓库，继续使用 `e4ecf47499c35bf25e10d04257a21a4f7975ebad`。

构建读取 fork 的 `release/DEFAULT_BUILD_TAGS_OTHERS`、`release/LDFLAGS` 与父仓库的 `sing-box.version`，使用 `GOTOOLCHAIN=local`、`GOWORK=off`、`-mod=readonly`；Android arm64 为 CGO=0。产品显示版本和源码身份分别记录。现有启动器已提供 192/256/384/512 MiB 的 GOMEMLIMIT 分档并尊重用户覆盖，本轮优化以实际资源归属和释放为准。

新增的 CORE 合同要求同步固定上游及完整 WireGuard 差异、保留 AWG，覆盖握手失败回调与流绑定/关闭竞态。先提交合同，后记录经验证内核和实现提交；本节准备记录不改变历史 #426 的现场证据结论。


## 10. 2026-10-30 最终内核集成（配方 0.3.3）

最终 `magicnet-android@396d71df3bd98316324e3533e2d2106e7392250e` 基于 `0952cb01b001e41e1074c2e5f4a731a4ad42b222`，固定 `sing-box@ff669d45e6562a790a49ef066340dbed5df46363`；完整提交、tree、实际构建和产物摘要见 PROVENANCE.md / VERIFICATION.md。最新订阅、恢复与 UI 源码保留，消费仓只改核心 gitlink、版本及验收材料，MagicSingBox 与规则保持原固定点。

内核审查覆盖完整目标上游差异、sing-tun 版本锁和 WireGuard 复制源码。路由握手失败的资源清理使用已有关闭机制；多组真实 AttachConnection 屏障测试覆盖挂接与关闭重叠时的 remover 注册，不能外推为完全关闭后首次挂接的新合同。缓存 DNS 拒绝路径补回原有失败观测，WireGuard pause 读取当前 manager 状态并安全处理尚未初始化 manager 的情况，均有旧版反例与最终 race 回归。细节见[固定内核报告](https://github.com/LIghtJUNction/sing-box/blob/ff669d45e6562a790a49ef066340dbed5df46363/SPECS/TASKS/051-UPSTREAM_MERGE_235/IMPLEMENTATION_REPORT.md)。

受控 sing-tun A/B 验证 ACK 判定表删除和 FIN/RST 会话回收，同时保留活动/半关闭控制组。原始日志、共同测试和完整 runner 可从固定内核 validation 目录复跑；内存结论只属于已测路径。最终 canonical 核心由现有助手实际构建 Linux/Android 两目标，Linux 真实 check 和 loopback DNS 通过；设备网络、真实加密服务器和长期 RSS 仍未知。
