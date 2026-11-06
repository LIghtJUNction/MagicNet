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
| POLICY-A03 | 自定义应用/域名与指定域名拒绝、模式、DNS 劫持、LAN、Tailnet、普通业务规则重叠 | 指定域名拒绝与保护规则先于用户增量，增量先于普通业务；原数组相对顺序与内容不变 |
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
| POLICY-A23 | 代理节点使用域名；并查询国内分类、LAN/Tailnet、显式 Direct 模式域名 | 引导解析仍走 `bootstrap-local-dns`，代理节点解析不递归依赖代理；显式直连 DNS 规则及其先后顺序保持 |
| POLICY-A24 | 默认 DNS 指向直连解析器但存在未使用的代理 DNS；无条件规则的默认类型元数据和空匹配值；proxy 标签绑定直连/缺失/重复/循环出站；其他厂商合法代理解析器 | 诊断按默认引用和出站链判断，直连默认或无条件规则不报告受保护；中性字段不绕过检查，真实条件的显式直连策略保留；默认无节点 block 阻止回退；厂商名不成为通过条件 |
| POLICY-A25 | 更新订阅、切换 profile、升级模板、独立 DNS 图、TLS insecure 远端、apply 失败/回滚失败/并发配置锁、WebUI 未收到状态 | 托管默认保持代理 fallback 并验证 TLS；失败保留原配置与 profile 或诚实报告回滚失败，不越过共享锁写入；显式 profile/独立图/自定义 pin 保留；UI 初始值与机器默认一致 |
