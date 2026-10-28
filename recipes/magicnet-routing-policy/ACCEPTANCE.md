# 策略验收

- 缺任意引用分类、损坏摘要、错误 tag/selector、保留名字碰撞、空 AI 候选分别失败；无可用节点不得默认 direct。
- 逐例执行实际 engine matcher 的 first-match：显式 rule/global/direct、LAN、广告、ChatGPT/Gemini/Grok/Claude、Voice TCP/UDP、iCloud/Apple、Bing/Microsoft、游戏下载/游戏、Telegram、外国域+CN IP 重叠。
- 只含 analytics/tracker/github/captive 子串的无关域不被旧关键词策略误分流。
- DNS/route 域分类一一对应，IP/protocol-only 不成为 DNS 错规则；Direct/Proxy 的解析器归属正确。
- 导入合法节点后，各 named selector 含合法候选，用户选择恢复；删除节点后的选择仍有效。
- 离线开机使用 bundled 规则；普通订阅刷新前后规则摘要不变；新构建才引入显式固定的新资产。
- userspace Tailscale 只匹配真实 peer/accepted route/MagicDNS，不抢普通 CGNAT；LAN 原规则仍在。

本次只读取模板/文档与公开库存，没有重新下载分类或运行 matcher；全部功能验收未验证。
