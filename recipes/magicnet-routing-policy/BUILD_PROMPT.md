# 默认路由、DNS 和规则数据

交付可被 engine 校验的默认配置和不可变的本地分类资产。参考模板 revision ba5793b41fd06704102116fe2536eef5988f2905（MagicSingBox），`config.json` SHA-256 为 `e269e2303cf1e23d3b4ce69dcb7cca39f0f53dc647c5d03aace4c4bd7f986be0`；规则集合 revision f3335f9420d07b8c50b26488df2a9492da6bbb44（MagicNetRules）。
复用上游规则数据需要其许可与可获取性；数据是外部前提，配方不含 .srs 或原配置源码。没有数据时应明确缺失，不用空文件替代真实分类。

先读 POLICY_INVENTORY.md 的公开标签/默认值。默认 tun-in/magicnet0 和 loopback mixed-in，本地管理 API；runtime 在显式模式切换中物化 ebpf，不能在这里加 auto/TProxy/Redirect。
proxy 与 AI 组没有合格节点默认 block，lan/cn-direct/国内类 direct，国外类 proxy，广告 block。导入节点不能与系统 selector/tag 碰撞。用户手选持久化，订阅更新后合法重建。
每个 named selector 仍可单独选择：Google、YouTube、GitHub、Discord、Netflix、Spotify、X/Twitter、WhatsApp、Telegram 与四个 AI 服务，不把它们折叠成一个国家出口。

## 规则次序

基础入口处理（53 端口 DNS 劫持、嗅探、DNS 协议劫持、ICMP 与 `0.0.0.0` 保护）→ 指定域名拒绝 → 显式 mode → LAN/保留地址保护 → 原生应用提示 → 广告分类 → 业务分类 → 一般国家 IP/final。
具体 AI 在一般 AI 前，Gemini/YouTube 在 Google 前，iCloud 在 Apple 前，Bing/开发/游戏服务在 Microsoft 前，游戏下载在游戏社区/登录前，Telegram 在一般通信前。已知外国服务域不能因解析到 CN IP 被错误直连。
大陆教育域名分类置于既有 DNS 防护之后、后续国外学术、AI、游戏、开发和媒体分类之前；具体插入点与范围见下节。其他既有规则保持相对次序。
业务 DNS 域分类与路由拥有相同条件/次序；IP/协议-only 不复制成 DNS 规则。以下指定域名拒绝只作用于路由，保持 DNS 捕获和解析配置。Direct 业务用本地加密 DNS，Proxy 用远端解析；手动 DNS profile 仍明确覆盖。
不能恢复泛 analytics/tracker/github/captive 子串匹配。国内连通性探针是显式例外，不等于任意 captive 域放行。

### 默认 DNS 出口与引导解析

规则模式下，未匹配显式 DNS 分类的查询使用 `doh-cloudflare`，其 HTTPS 连接必须经 `proxy`。模板的 `dns.final` 与 runtime 生成的默认 `evaluate/respond` 路径保持一致；新安装、升级、订阅刷新和重复应用 profile 都不得恢复直连 fallback。代理不可用或尚无节点时，默认查询失败，不自动交给本地解析器。

`bootstrap-local-dns` 保留为代理节点地址的引导解析器；受管配置缺少 `route.default_domain_resolver` 时指向它，已有显式 resolver 保留，避免将合法用户引导图强制重写。默认图不在连接代理之前依赖同一代理解析节点域名。国内分类、LAN/Tailnet 与显式 Direct 模式的 DNS 规则继续使用原有本地加密解析器。独立导入配置在默认 profile 下保留自己经过验证的 DNS 图；显式 DNS profile 保持既有选择语义。

诊断需要检查默认查询实际引用的 DNS server、detour 与配置的出站链，不能仅因服务器列表中存在某个公共 DNS 厂商或出站名为 proxy 就报告受保护。默认规则类型元数据、空匹配列表和其他中性值不能掩盖无条件直连。受管默认拒绝禁用 TLS 证书验证的远端；profile 应用失败恢复原持久化意图或原不存在状态，复用配置锁并诚实报告回滚失败。WebUI 初始默认值与机器响应一致。配置检查、锁定核心的隔离查询测试和 Android 实际流量结果分别记录；静态规则匹配不作为设备流量结论。

### 指定域名拒绝

默认模板用两个原生 `action: reject` 规则表达以下固定目标，使用完整域名匹配，不扩展到父域名或子域名：

| 精确域名 | 目标端口 |
| --- | --- |
| `flash.sec.miui.com` | 不限 |
| `fraud-detection.engine.miui.com` | 不限 |
| `eps.caict.ac.cn` | 不限 |
| `gateway-papa.cloud.weizhi.com` | 不限 |
| `dm.wo.com.cn` | 仅 `18080`，TCP/UDP |

前四个域名共享一条拒绝规则；第五个域名使用另一条规则，同时匹配域名与目标端口。保留基础入口处理的优先级：DNS 请求继续由既有 DNS 规则处理，ICMP 和 `0.0.0.0` 沿用原行为。拒绝规则位于 `rule`、`global`、`direct` 模式分流及应用、用户增量和业务规则之前，不能通过后续 selector 选择覆盖。

匹配依赖进入 sing-box 的流量带有可识别的目标域名。纯 IP 且无域名信息的连接、非目标域名以及 `dm.wo.com.cn` 的其他端口继续按原有规则处理。规则随固定内置模板分发，新安装与正常升级使用内置模板，无需额外执行社区模板更新；普通订阅刷新不删除这些规则。

### 大陆教育域名分类

使用 POLICY_INVENTORY.md 中列明并有官方来源的 16 个域名后缀，以 `domain_suffix` 匹配根域名及其子域名。范围包括 `edu.cn`、指定教育公共服务、慕课与教学平台、教育资讯及学术资源；不以 `edu`/`school` 等关键词匹配，也不扩大到所有 `.edu`、`.cn` 或共享 CDN。

新增路由是一条普通业务规则：`outbound: cn-direct`，省略 `action`，保持现有 `cn-direct` selector 默认 `direct` 及用户手选。插在目标端口 `853`、出口 `dns-guard` 的规则之后。DNS 增加同一组后缀，插在 `meta-category-doh` / `meta-category-ip-geo-detect` 分类规则之后，使用现有本地加密解析器；路由与 DNS 的后缀集合必须一致。

既有指定目标拒绝、模式、LAN/Tailnet、用户增量、应用分流、广告和 DNS 防护继续优先。教育分类优先于插入点之后的国外学术、AI、游戏、开发和媒体分类，避免这些较宽分类抢先接管清单中的站点。保留手动 DNS profile 的既有覆盖语义，按实际配置区分出口组选择与 DNS 解析器选择。

复用现有 selector、DNS server 和规则资产，不新增下载来源、`.srs` 数据或常驻服务。规则随固定内置模板进入新安装、升级和生成配置；普通订阅刷新保留规则与现有用户选择。在既有旧默认迁移清单中新增官方默认仓库、`dacc776dad4bd2519d5dd0dfbf3839713f9e438c` 和对应摘要的精确配对；保留原有配对，统一迁移至当前固定模板。用户自定义 repo、ref 或 digest 保持不变。未在清单中的站点、共享资源和缺少可识别域名的连接沿用原有分流，实际流量结果分层记录。

## 维护与分发

分类来源包含 MetaCubeX/meta-rules-dat、lyc8503/sing-box-rules、KaringX/karing-ruleset、HaGeZi light 广告/跟踪与 MagicNetRules 的统一/去重优化结果。版权/反盗版名单不是默认广告策略。
构建解析并记录不可变 upstream revision，打包本地规则；开机无需连接规则上游。普通订阅刷新不改变业务资产。缺分类、摘要错误、引用缺失必须失败。
模板仓库支持经验证的 GitHub/GitLab fork 与原子同步；固定 commit+SHA-256，不把“最新”当信任来源。

默认规则移除 `sukka-chatgpt-voice`：不生成或执行 `update_chatgpt_voice_rules.sh`，不下载、编译或打包其 JSON 资产及专用 IP/端口分流。历史模板和规则来源按现行库存筛选，构建与订阅刷新均不重新引入该分类。保留 `meta-openai`、`ai-chatgpt`、ChatGPT 域名和应用包名分流及对应 DNS；原先只命中 Voice IP 的连接继续匹配其余现有规则。

## 本包补充材料

- [POLICY_INVENTORY.md](POLICY_INVENTORY.md)

## 结构化增量分流（schema 1）

原有 JSON Merge Patch 对普通字段继续生效。保留扩展键 `$magicnet_routing` 只接受 `schema: 1`、`rules` 和 `outbounds`，在交给内核前编译并移除该键，不向内核透传。

~~~json
{"$magicnet_routing":{"schema":1,"rules":[{"kind":"domain","value":"example.com","outbound":"My route"},{"kind":"app","value":"com.example.reader","outbound":"My route"}],"outbounds":[{"type":"selector","tag":"My route","outbounds":["proxy","direct"],"default":"proxy"}]}}
~~~

最多 256 条规则、64 个自定义出口、每组 128 个成员；名称不为空、不含控制字符，最多 256 UTF-8 字节；域名使用 ASCII/Punycode 域后缀，应用使用带点包名。规则以 `(kind,value)` 唯一，目标必须存在。自定义 tag 不得覆盖订阅、内置出口或 endpoint；组/绕行引用不得缺失或成环。支持 selector/urltest 与 SOCKS、HTTP、Shadowsocks、Trojan、VLESS、VMess、Hysteria2、TUIC、AnyTLS 的受限结构化字段，最终以锁定内核的真实校验为准；不允许任意顶层内核字段混入这个扩展。WebUI 提供常用类型，复杂协议仍可经完整覆写编辑器处理。

编译保留原数组及其相对次序。应用与域名规则位于指定域名拒绝、显式模式、DNS 劫持、LAN 和 Tailnet 保护之后、普通业务分类之前。增量规则的 DNS 使用相同应用/域名条件与次序；用户增量的拦截目标拒绝解析，其余目标复制固定的加密 DNS 模板并显式 detour 到该目标，使自定义组切换时解析仍走该组。直接链默认选择本地加密 DNS 模板，其余选择远端模板；模板选择基于配置，运行时组选择不改写模板地址。缺模板或 DNS tag 碰撞必须拒绝，不能悄悄改用其他出口。

新出口、DNS server、路由与 DNS 规则的精确归属只保存在私密 checkpoint 的 `routing_owned`。重新生成时先去除自身上次生成项，再叠加当前意图，保留订阅与其他写者的新内容；已归属项被外部改成不同内容时返回 `override.routing_conflict`。撤销删除自己的项，不删除新增的订阅项。该 checkpoint 是恢复输入，不是公共状态接口。

错误码包括 `override.routing_invalid|routing_limit|routing_tag_collision|routing_target_missing|routing_cycle|routing_duplicate|routing_dns_missing|routing_conflict`。preview 失败不落盘。继续使用既有 revision、锁、set/apply/reset、原子发布与回滚协议，不新增机器写命令；停止的服务保持停止。`override.inspect.routing_targets` 只供显式私密编辑，返回 tag/type，不返回凭据。

### 本轮字段与界面一致性补充

VLESS 的受限结构化字段必须增加独立字符串 encryption，并按 engine 的 VLESS_ENCRYPTION.md 完整校验与保留；不为这一项随意开放其他未知字段。该要求修正旧白名单缺口，不代表 v1.8.0 编辑器已有支持。runtime 负责来源内/跨来源节点身份：同名不同连接语义不得互相覆盖，重排/刷新不能让用户选择漂移，系统 selector 继续受保护。

新 UI 与后端对 tag 统一按 256 UTF-8 字节上限检查，不能一端按 128 个 UTF-16 单元、另一端按 UTF-8 字节给出冲突结论。域名规则统一 trim 后转为 ASCII/Punycode 小写再按 (kind,value) 判重；不改变应用包名大小写，不把域名规范化套到 URL query。旧输入迁移导致语义重复时明确指出冲突，不能静默删除用户意图。这两项是重建修正；旧源码的 UI 与服务端规则不完全一致。
