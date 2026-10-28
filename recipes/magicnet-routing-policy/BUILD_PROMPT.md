# 默认路由、DNS 和规则数据

交付可被 engine 校验的默认配置和不可变的本地分类资产。参考模板 revision e4ecf47499c35bf25e10d04257a21a4f7975ebad（MagicSingBox）；规则集合 revision f3335f9420d07b8c50b26488df2a9492da6bbb44（MagicNetRules）。
复用上游规则数据需要其许可与可获取性；数据是外部前提，配方不含 .srs 或原配置源码。没有数据时应明确缺失，不假造55份空规则。

先读 POLICY_INVENTORY.md 的公开标签/默认值。默认 tun-in/magicnet0 和 loopback mixed-in，本地管理 API；runtime 在显式模式切换中物化 ebpf，不能在这里加 auto/TProxy/Redirect。
proxy 与 AI 组没有合格节点默认 block，lan/cn-direct/国内类 direct，国外类 proxy，广告 block。导入节点不能与系统 selector/tag 碰撞。用户手选持久化，订阅更新后合法重建。
每个 named selector 仍可单独选择：Google、YouTube、GitHub、Discord、Netflix、Spotify、X/Twitter、WhatsApp、Telegram 与四个 AI 服务，不把它们折叠成一个国家出口。

## 规则次序

显式 mode → LAN/保留地址保护 → 原生应用提示 → 广告分类 → 业务分类 → 一般国家 IP/final。
具体 AI 在一般 AI 前，Gemini/YouTube 在 Google 前，iCloud 在 Apple 前，Bing/开发/游戏服务在 Microsoft 前，游戏下载在游戏社区/登录前，Telegram 在一般通信前。已知外国服务域不能因解析到 CN IP 被错误直连。
DNS 域分类与路由拥有相同条件/次序；IP/协议-only 不复制成 DNS 规则。Direct 业务用本地加密 DNS，Proxy 用远端解析；手动 DNS profile 仍明确覆盖。
不能恢复泛 analytics/tracker/github/captive 子串匹配。国内连通性探针是显式例外，不等于任意 captive 域放行。

## 维护与分发

分类来源包含 MetaCubeX/meta-rules-dat、lyc8503/sing-box-rules、KaringX/karing-ruleset、HaGeZi light 广告/跟踪、Sukka OpenAI Voice IP 与 MagicNetRules 的统一/去重优化结果。版权/反盗版名单不是默认广告策略。
构建解析并记录不可变 upstream revision，打包本地规则；开机无需连接规则上游。普通订阅刷新不改变业务资产。缺分类、摘要错误、引用缺失必须失败。
模板仓库支持经验证的 GitHub/GitLab fork 与原子同步；固定 commit+SHA-256，不把“最新”当信任来源。

## 本包补充材料

- [POLICY_INVENTORY.md](POLICY_INVENTORY.md)

## 结构化增量分流（schema 1）

原有 JSON Merge Patch 对普通字段继续生效。保留扩展键 `$magicnet_routing` 只接受 `schema: 1`、`rules` 和 `outbounds`，在交给内核前编译并移除该键，不向内核透传。

~~~json
{"$magicnet_routing":{"schema":1,"rules":[{"kind":"domain","value":"example.com","outbound":"My route"},{"kind":"app","value":"com.example.reader","outbound":"My route"}],"outbounds":[{"type":"selector","tag":"My route","outbounds":["proxy","direct"],"default":"proxy"}]}}
~~~

最多 256 条规则、64 个自定义出口、每组 128 个成员；名称不为空、不含控制字符，最多 256 UTF-8 字节；域名使用 ASCII/Punycode 域后缀，应用使用带点包名。规则以 `(kind,value)` 唯一，目标必须存在。自定义 tag 不得覆盖订阅、内置出口或 endpoint；组/绕行引用不得缺失或成环。支持 selector/urltest 与 SOCKS、HTTP、Shadowsocks、Trojan、VLESS、VMess、Hysteria2、TUIC、AnyTLS 的受限结构化字段，最终以锁定内核的真实校验为准；不允许任意顶层内核字段混入这个扩展。WebUI 提供常用类型，复杂协议仍可经完整覆写编辑器处理。

编译保留原数组及其相对次序。应用与域名规则位于显式模式、DNS 劫持、LAN 和 Tailnet 保护之后、普通业务分类之前。DNS 使用相同应用/域名条件与次序；拦截目标拒绝解析，其余目标复制固定的加密 DNS 模板并显式 detour 到该目标，使自定义组切换时解析仍走该组。直接链默认选择本地加密 DNS 模板，其余选择远端模板；模板选择基于配置，运行时组选择不改写模板地址。缺模板或 DNS tag 碰撞必须拒绝，不能悄悄改用其他出口。

新出口、DNS server、路由与 DNS 规则的精确归属只保存在私密 checkpoint 的 `routing_owned`。重新生成时先去除自身上次生成项，再叠加当前意图，保留订阅与其他写者的新内容；已归属项被外部改成不同内容时返回 `override.routing_conflict`。撤销删除自己的项，不删除新增的订阅项。该 checkpoint 是恢复输入，不是公共状态接口。

错误码包括 `override.routing_invalid|routing_limit|routing_tag_collision|routing_target_missing|routing_cycle|routing_duplicate|routing_dns_missing|routing_conflict`。preview 失败不落盘。继续使用既有 revision、锁、set/apply/reset、原子发布与回滚协议，不新增机器写命令；停止的服务保持停止。`override.inspect.routing_targets` 只供显式私密编辑，返回 tag/type，不返回凭据。

### 本轮字段与界面一致性补充

VLESS 的受限结构化字段必须增加独立字符串 encryption，并按 engine 的 VLESS_ENCRYPTION.md 完整校验与保留；不为这一项随意开放其他未知字段。该要求修正旧白名单缺口，不代表 v1.8.0 编辑器已有支持。runtime 负责来源内/跨来源节点身份：同名不同连接语义不得互相覆盖，重排/刷新不能让用户选择漂移，系统 selector 继续受保护。

新 UI 与后端对 tag 统一按 256 UTF-8 字节上限检查，不能一端按 128 个 UTF-16 单元、另一端按 UTF-8 字节给出冲突结论。域名规则统一 trim 后转为 ASCII/Punycode 小写再按 (kind,value) 判重；不改变应用包名大小写，不把域名规范化套到 URL query。旧输入迁移导致语义重复时明确指出冲突，不能静默删除用户意图。这两项是重建修正；旧源码的 UI 与服务端规则不完全一致。
