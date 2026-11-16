# 策略验收

- 缺任意引用分类、损坏摘要、错误 tag/selector、保留名字碰撞、空 AI 候选分别失败；无可用节点不得默认 direct。
- 逐例执行实际 engine matcher 的 first-match：显式 rule/global/direct、LAN、广告、ChatGPT/Gemini/Grok/Claude、iCloud/Apple、Bing/Microsoft、游戏下载/游戏、Telegram、外国域+CN IP 重叠。
- 只含 analytics/tracker/github/captive 子串的无关域不被旧关键词策略误分流。
- 业务 DNS/route 域分类一一对应，IP/protocol-only 不成为 DNS 错规则；指定域名拒绝保留既有 DNS 配置，Direct/Proxy 的解析器归属正确。
- 导入合法节点后，各 named selector 含合法候选，用户选择恢复；删除节点后的选择仍有效。
- 离线开机使用 bundled 规则；普通订阅刷新前后规则摘要不变；新构建才引入显式固定的新资产。
- userspace Tailscale 只匹配真实 peer/accepted route/MagicDNS，不抢普通 CGNAT；LAN 原规则仍在。

## 增量路由与订阅交互验收

| ID | 输入/操作 | 预期 |
| --- | --- | --- |
| POLICY-A01 | 256/257 条规则、64/65 个出口、128/129 个组成员；tag 的 UTF-8 256/257 字节边界 | 合法边界可预览，越界明确失败且零写；UI 与后端同规则，不能用字符数替代字节数 |
| POLICY-A02 | 重复域名大小写、重复 (kind,value)、缺目标、订阅/内置/endpoint 同 tag、detour/组引用成环 | 规范化后校验，分别返回 routing_duplicate/target_missing/tag_collision/cycle 等已定义错误；不覆盖原项 |
| POLICY-A03 | 标准模板中，自定义应用/域名与指定域名拒绝、模式、DNS 劫持、LAN、Tailnet、普通业务规则重叠；另测交错自定义数组 | 标准模板中保护规则先于用户增量，增量先于普通业务；交错数组在最后一个保护规则后插入，较早业务保留原优先级；原数组相对顺序与内容不变 |
| POLICY-A04 | direct/proxy/block/自定义 selector，缺加密 DNS 模板、生成 DNS tag 碰撞 | DNS 与目标一致，block 拒绝解析；缺模板/冲突拒绝，不悄悄换出口 |
| POLICY-A05 | 应用后订阅新增节点，再重复物化和 reset | 自定义项恰好一份；新增订阅项不丢；reset 只撤自己拥有的项，现有手选保持合法 |
| POLICY-A06 | 外部修改已归属项；stale revision；保存后激活失败；服务原本停止 | routing_conflict/revision conflict 明确，不覆盖外部变更；pending 与回滚可见，停止意图保持 |
| POLICY-A07 | 结构化 VLESS Encryption 的长合法值/非法值、独立 TLS 开关、保存回读/订阅刷新 | 按 engine VE-005 保真且真实 check；非法值零写；不删除 encryption 以换取校验成功 |

## 0.2.1 历史验证范围

这些是补齐的重建验收，本轮未运行 Rust/真实核心/设备路由矩阵；旧测试代码存在不算本轮通过。

本次只读取模板/文档与公开库存，没有重新下载分类或运行 matcher；全部功能验收未验证。

## 0.2.2 指定域名拒绝验收

以下为验收要求；每轮实际结果按模板、配置生成、真实核心、设备与网络层分别记录于根配方 VERIFICATION.md。

| ID | 输入/操作 | 预期 |
| --- | --- | --- |
| POLICY-A08 | 四个不限端口的精确域名，TCP/UDP 的 80、443、18080 端口；分别选择 rule/global/direct，并叠加应用或用户增量 direct 规则 | 在既有基础入口处理之后命中原生 reject，先于模式、应用、增量与业务分流；后续 selector 选择不覆盖拒绝 |
| POLICY-A09 | `dm.wo.com.cn` 的 TCP/UDP 18080，以及 80、443、18079、18081 | 仅目标端口 18080 命中新增拒绝；其余端口继续按原有规则处理 |
| POLICY-A10 | 五个域名的父域名、子域名、相近拼写、无关域名与无域名信息的纯 IP 连接 | 不命中新规则，沿用原有分流；不使用 domain_suffix、关键词或共享 IP 扩大匹配 |
| POLICY-A11 | 相同目标的 53 端口流量和已识别 DNS 协议、ICMP、`0.0.0.0`；比较仅添加指定目标拒绝前后的 DNS 配置 | 基础入口规则保持优先；指定目标拒绝保留原 DNS 捕获和解析配置，不增加 DNS 拒绝规则 |
| POLICY-A12 | 从固定模板生成新安装和升级配置，再做普通订阅刷新；检查发布包中的模板与固定来源 | 两条拒绝规则及次序保留，来源与摘要可追溯；无需额外社区模板更新；用锁定核心校验生成配置，设备结果另记 |

## 0.2.3 专用 ChatGPT Voice 规则清理验收

| ID | 输入/操作 | 预期 |
| --- | --- | --- |
| POLICY-A13 | 检查维护入口、构建调用、默认模板、规则清单与最终安装包 | 不含 `update_chatgpt_voice_rules.sh`、`sukka-chatgpt-voice` JSON 或专用路由引用；其余分类的引用与摘要校验继续有效 |
| POLICY-A14 | ChatGPT 域名分类和应用包名的 TCP/UDP 请求，选择与恢复 `ai-chatgpt` | `meta-openai`、应用包名规则及对应 DNS 保留；`ai-chatgpt` 候选与用户选择保持原义，无合格节点仍为 block |
| POLICY-A15 | 从含历史 Voice 数据的规则来源构建、Voice 上游不可用，再执行普通订阅刷新 | 不请求该上游，不重新生成或打包该分类；仅曾命中 Voice IP 的连接按其余现有规则处理 |

## 0.2.4 大陆教育域名分类验收

范围以 POLICY_INVENTORY.md 的 16 个后缀为准。以下为验收要求，模板匹配、生成配置、锁定核心、模拟器与真机结果分别记录；官网来源核验只用于确认域名及用途。

| ID | 输入/操作 | 预期 |
| --- | --- | --- |
| POLICY-A16 | 16 个根域名及各自子域名，在规则模式且无前序命中时访问；比较路由与 DNS 后缀集合 | 根域名和子域名均进入 `cn-direct`，组默认 `direct`；DNS 使用现有本地加密解析器；两份后缀集合完全一致 |
| POLICY-A17 | `school.edu`、`unrelated.cn`、`school.edu.cn.example.com`、`notchsi.com.cn`、共享 CDN 域名和无域名信息的纯 IP 连接 | 新教育规则不命中；继续按原有分流；不使用关键词、全 `.edu`/`.cn` 或共享 IP 扩大范围 |
| POLICY-A18 | 教育域名与显式 global/direct、LAN/Tailnet、用户或应用分流、广告、DNS 分类防护及目标端口 853 重叠；回归既有五个拒绝目标 | 所有既有前序规则保持优先；原拒绝规则保留；教育业务规则位于路由 853 防护之后，DNS 位于 DoH/IP 检测分类防护之后 |
| POLICY-A19 | 清单内域名同时命中插入点之后的国外学术、AI、游戏、开发及媒体分类 | 路由先选择教育 `cn-direct`，DNS 先选择教育解析器；清单外域名仍按各自既有分类处理 |
| POLICY-A20 | 生成新安装/升级配置、订阅刷新和重复物化；预先手选 `cn-direct`；对照旧官方默认 pin 与自定义 repo/ref/digest，检查配置并用锁定核心校验 | 教育路由与 DNS 规则各一条，路由保留 `outbound: cn-direct` 且省略 `action`，后缀与次序不丢；现有手选保留；精确旧默认 pin 迁移至当前模板，自定义记录不变；selector、DNS server 和规则数据依赖集合不因本功能增加 |

## 默认 DNS 出口验收

使用合成域名、本地 DNS 与代理夹具验证查询路径；不依赖公开泄露测试站点的分类命中。配置、真实核心和设备流量分别记录结果。

| ID | 输入/操作 | 预期 |
| --- | --- | --- |
| POLICY-A21 | 规则模式下查询未命中任意分类的 A/AAAA 域名；从旧默认配置生成，再重复应用默认 profile | 默认 DNS 选择 `doh-cloudflare` 且经 `proxy`；`dns.final` 与生成的默认响应路径一致；重复应用不新增重复规则 |
| POLICY-A22 | 禁用代理或使用无节点的默认模板后，再查询未知域名 | 查询失败，直连 bootstrap 夹具没有收到该域名；无节点的 `proxy` 默认仍为 `block` |
| POLICY-A23 | 代理节点使用域名；并查询国内分类、LAN/Tailnet、显式 Direct 模式域名 | 引导解析仍走 `bootstrap-local-dns`，代理节点解析不递归依赖代理；除 POLICY-A30 的 mDNS 范围外，既有 DNS 规则与次序保持 |
| POLICY-A24 | 默认 DNS 指向直连解析器但存在未使用的代理 DNS；无条件规则的默认类型元数据和空匹配值；proxy 标签绑定直连/缺失/重复/循环出站；其他厂商合法代理解析器 | 诊断按默认引用和出站链判断，直连默认或无条件规则不报告受保护；中性字段不绕过检查，真实条件的显式直连策略保留；默认无节点 block 阻止回退；厂商名不成为通过条件 |
| POLICY-A25 | 更新订阅、切换 profile、升级模板、独立 DNS 图、TLS insecure 远端、apply 失败/回滚失败/并发配置锁、WebUI 未收到状态 | 托管默认保持代理 fallback 并验证 TLS；失败保留原配置与 profile 或诚实报告回滚失败，不越过共享锁写入；显式 profile/独立图/自定义 pin 保留；UI 初始值与机器默认一致 |

## 0.2.6 稳定插入、mDNS 与规则资产验收

以下是验收要求。分别记录配置生成、真实核心、Android 组播与网络流量结果；合成夹具通过不能代替设备连通性证据。

| ID | 输入/操作 | 预期 |
| --- | --- | --- |
| POLICY-A26 | 应用 direct/proxy 与相同条件、相反出口的业务规则重叠；业务规则分别显式写 `action: route` 和省略 action；增加与目标应用无关的重叠业务对 | 标准模板中应用选择先于两种业务写法；显式 action 不获得额外优先级，无关流量的原先首条命中不变 |
| POLICY-A27 | 保护规则与业务交错；指定拒绝、mode、DNS、ICMP、保留 IP、LAN 与自定义 tag 的 Tailnet；包含 `[sniff, LAN, resolve, route-options, business]`，另测无 LAN 或无保护规则 | 删除本次托管项后原数组逐项一致；新项位于最后保护规则之后，不越过 `resolve` 与 `route-options`，保留解析与连接准备；应用策略无保护时插在开头；已有 Tailnet 域名规则不依赖后续 LAN 保护，交错数组中较早业务保留原优先级 |
| POLICY-A28 | 应用、域名、广告三个物化入口的全部六种排列，各执行两次；再清空各自策略 | 各排列收敛为应用直连、应用代理、自定义域名、广告允许、广告拦截；每项仅一份，重复执行不漂移，清空只撤自身项，保留其他业务与目的地 DNS 策略 |
| POLICY-A29 | 非空自定义域名策略；移除 sniff；清空策略；注入规则生成或最终原子发布失败 | 域名规则位于 sniff 之后；无 sniff 时非空策略失败且原文件不变，空策略仍可撤销旧项；生成或发布失败不发布半成品，暂存文件清理 |
| POLICY-A30 | `.local` 主机名、服务名及清单内 IPv4/IPv6 链路本地 PTR；分别使用 Rule/Direct/Global 并叠加公共 DNS 分类；另测无接口、无响应 | 六个后缀选择唯一 `lan-mdns`，先于模式公网 DNS；原生 mDNS 使用本地组播，无公共或系统 DNS 后备；接口或响应不可用时诚实失败 |
| POLICY-A31 | `printer.local.example.com`、`localdomain`、相邻 IPv4/IPv6 反向区域、普通私网 PTR、`home.arpa`、`.lan`、`ts.net` 和未知公网域名 | mDNS 不越过后缀边界；其他局域网名称与私网反向区域保持既有策略，Tailnet MagicDNS 不被接管；未知公网默认仍经代理解析，节点引导保持独立 |
| POLICY-A32 | 模板生成、新安装、升级、订阅刷新、重复应用 DNS profile 和 Tailscale 注入；检查锁定核心配置 | mDNS 服务器与六后缀规则各一份，保留模式前优先级；现有 DNS 默认与引导图保留，已验证独立导入图仍遵守 POLICY-A25；核心检查与实际组播结果分别记录 |
| POLICY-A33 | 按库存固定 revision/release/manifest 摘要获取并打包规则；注入损坏摘要、缺引用分类；离线启动和普通订阅刷新 | 来源与摘要一致，错误摘要或缺失分类导致构建失败；本地资产可离线加载，普通订阅刷新不改规则摘要，不能用空分类替代真实资产 |

## 有界规则归一化验收

以下条目定义本轮维护验收；实际执行结果、配置身份与网络测量另记根 VERIFICATION.md。

| ID | 输入/操作 | 预期 |
| --- | --- | --- |
| POLICY-A34 | 托管 sniff/DNS 对之前放置紧邻的纯 53 劫持；端口和 inbound 分别使用标量/列表、inbound 省略或完整覆盖；另提供旧版已生成的同形快速规则 | 不再插入被完整覆盖的快速规则，已有同形冗余项可移除；嗅探和协议 DNS 后备保留，其他前序规则不变 |
| POLICY-A35 | 53 前驱只覆盖部分 inbound、带额外条件、端口无效或不含 53；在覆盖规则与 sniff 之间放置状态动作；自定义 inbound 或缺少紧随 DNS 劫持 | 只在原有托管匹配条件成立时维护快速规则；条件或部分覆盖不跳过它，覆盖判断不跨状态动作；自定义规则不获得新策略 |
| POLICY-A36 | route/outbound 与 dns/server 各构造同目标相邻规则，组合 scalar/list、重复 tag、显式和省略 action；对输入副本归一化两次 | 合并结果按原顺序稳定去重，输入对象不变，第二次结果相同；保持原有匹配目标，出口、DNS server、final 和规则集定义不变 |
| POLICY-A37 | 相邻规则含不同目标、network/invert 等额外条件、状态动作、空或非字符串 tag；同时运行实际打包模板的归一化与锁定核心检查 | 非等价和非法规则保持分离，保留原有优先级；模板中已完整覆盖的 53 快速规则不重复。记录顶层规则变化与实际核心结果，内部匹配次数和互联网速度使用各自证据 |
