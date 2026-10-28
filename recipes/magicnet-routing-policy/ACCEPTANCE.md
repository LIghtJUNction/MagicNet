# 策略验收

- 缺任意引用分类、损坏摘要、错误 tag/selector、保留名字碰撞、空 AI 候选分别失败；无可用节点不得默认 direct。
- 逐例执行实际 engine matcher 的 first-match：显式 rule/global/direct、LAN、广告、ChatGPT/Gemini/Grok/Claude、Voice TCP/UDP、iCloud/Apple、Bing/Microsoft、游戏下载/游戏、Telegram、外国域+CN IP 重叠。
- 只含 analytics/tracker/github/captive 子串的无关域不被旧关键词策略误分流。
- DNS/route 域分类一一对应，IP/protocol-only 不成为 DNS 错规则；Direct/Proxy 的解析器归属正确。
- 导入合法节点后，各 named selector 含合法候选，用户选择恢复；删除节点后的选择仍有效。
- 离线开机使用 bundled 规则；普通订阅刷新前后规则摘要不变；新构建才引入显式固定的新资产。
- userspace Tailscale 只匹配真实 peer/accepted route/MagicDNS，不抢普通 CGNAT；LAN 原规则仍在。

## 增量路由与订阅交互验收

| ID | 输入/操作 | 预期 |
| --- | --- | --- |
| POLICY-A01 | 256/257 条规则、64/65 个出口、128/129 个组成员；tag 的 UTF-8 256/257 字节边界 | 合法边界可预览，越界明确失败且零写；UI 与后端同规则，不能用字符数替代字节数 |
| POLICY-A02 | 重复域名大小写、重复 (kind,value)、缺目标、订阅/内置/endpoint 同 tag、detour/组引用成环 | 规范化后校验，分别返回 routing_duplicate/target_missing/tag_collision/cycle 等已定义错误；不覆盖原项 |
| POLICY-A03 | 自定义应用/域名与模式、DNS 劫持、LAN、Tailnet、普通业务规则重叠 | 保护规则先于用户增量，增量先于普通业务；原数组相对顺序与内容不变 |
| POLICY-A04 | direct/proxy/block/自定义 selector，缺加密 DNS 模板、生成 DNS tag 碰撞 | DNS 与目标一致，block 拒绝解析；缺模板/冲突拒绝，不悄悄换出口 |
| POLICY-A05 | 应用后订阅新增节点，再重复物化和 reset | 自定义项恰好一份；新增订阅项不丢；reset 只撤自己拥有的项，现有手选保持合法 |
| POLICY-A06 | 外部修改已归属项；stale revision；保存后激活失败；服务原本停止 | routing_conflict/revision conflict 明确，不覆盖外部变更；pending 与回滚可见，停止意图保持 |
| POLICY-A07 | 结构化 VLESS Encryption 的长合法值/非法值、独立 TLS 开关、保存回读/订阅刷新 | 按 engine VE-005 保真且真实 check；非法值零写；不删除 encryption 以换取校验成功 |

这些是补齐的重建验收，本轮未运行 Rust/真实核心/设备路由矩阵；旧测试代码存在不算本轮通过。

本次只读取模板/文档与公开库存，没有重新下载分类或运行 matcher；全部功能验收未验证。
