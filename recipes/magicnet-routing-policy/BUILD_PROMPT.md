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
