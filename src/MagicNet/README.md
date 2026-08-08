# MagicNet

MagicNet 是 Android root 设备上的 sing-box TUN 网络模块。它通过 root 管理的 `magicnet0` 接管设备流量，提供订阅导入、节点选择、应用/Wi-Fi/热点策略、DNS 防泄露、WebUI、CLI 和 MCP。

当前模块只维护 `sing-box` + `magicnet0` TUN，不包含 TProxy、eBPF 或其他透明路径，也不会调用应用侧 `VpnService.establish()` 占用系统 VPN slot。

## 安装后必做

1. 在系统设置关闭“私人 DNS / 私密 DNS / Private DNS”，不要保留为“自动”。
2. 打开 root 管理器的模块 WebUI，在“订阅”保存合法 URL，或导入本地 Clash YAML、base64、分享链接、JSON/文本订阅。
3. 等待候选配置校验和原子激活完成。
4. 检查：

```bash
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
su -c 'ip link show magicnet0'
```

MagicNet 不提供节点、订阅或外部出口。请只配置你有权使用的资源。

## 订阅与节点

URL 快捷入口：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli sub status
su -c /data/adb/modules/MagicNet/cli sub update sing-box
```

WebUI 的 URL 保存和本地文件导入共用校验、原子替换与失败回滚。导入成功后本地文件会保持为当前来源，直到保存新的 URL。原生导入覆盖常见 VLESS、VMess、Trojan、Shadowsocks、SOCKS、Hysteria2、AnyTLS 和 TUIC 节点。

```bash
su -c /data/adb/modules/MagicNet/cli node list
su -c /data/adb/modules/MagicNet/cli node test-all
su -c /data/adb/modules/MagicNet/cli node current
```

节点进入 `proxy` 与自动测速组；服务专用组没有合格节点时保持 fail-closed。

## 应用、Wi-Fi 与热点

```bash
# Proxy 强制代理；Direct 仍进 TUN 但直连；Bypass 完全离开 TUN 与 MagicNet DNS
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.browser direct'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'

# 按 SSID/BSSID 在 rule 与 direct 间切换
su -c '/data/adb/modules/MagicNet/cli wifi add-ssid "Home WiFi"'
su -c /data/adb/modules/MagicNet/cli wifi enable
su -c /data/adb/modules/MagicNet/cli wifi status

# 热点客户端选择 Proxy；disable 恢复 Direct
su -c /data/adb/modules/MagicNet/cli hotspot enable
su -c /data/adb/modules/MagicNet/cli hotspot status
```

应用策略按 Android 多用户解析 UID。Bypass UID 同时绕过 TUN 与 DNS 捕获，主要用于外部 VPN 共存；普通“不走代理”优先选择 Direct。

热点由 Android/OEM 创建和 NAT。MagicNet 只管理已经进入 TUN 的转发流量；Proxy 期间临时关闭 tether 硬件卸载，disable 或卸载时恢复原值。

## 网络与恢复

```bash
su -c /data/adb/modules/MagicNet/cli network status
su -c '/data/adb/modules/MagicNet/cli network set ipv4_only 1400 5m'
su -c /data/adb/modules/MagicNet/cli repair
su -c /data/adb/modules/MagicNet/cli transparent apply
su -c /data/adb/modules/MagicNet/cli service restart sing-box
```

断网时保留现场，不要切换到不存在的透明模式。验收以 `cli health`、`cli transparent status` 和 `magicnet0` 为准。

## MCP

MCP 默认关闭并要求 secret 认证：

```bash
su -c '/data/adb/modules/MagicNet/cli mcp enable 127.0.0.1 8766'
su -c /data/adb/modules/MagicNet/cli mcp status
su -c /data/adb/modules/MagicNet/cli mcp logs 120
su -c /data/adb/modules/MagicNet/cli mcp rotate-secret
```

工作站需执行 `adb forward tcp:8766 tcp:8766`，并通过客户端支持的安全机制附加 Bearer 或 `X-MagicNet-MCP-Secret` 认证头。不要把 secret 写入仓库或日志。

## 支持

```bash
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

提交 Issue 前检查脱敏结果，不要公开订阅 URL、token、secret、password、完整节点地址或设备标识。

可以按当前 Wi-Fi 的 SSID 或 BSSID 自动切换 sing-box `rule` / `direct` 模式。黑名单命中时使用 `direct`，离开后恢复 `rule`：

```bash
su -c '/data/adb/modules/MagicNet/cli wifi add-ssid "Home WiFi"'
su -c /data/adb/modules/MagicNet/cli wifi enable
su -c /data/adb/modules/MagicNet/cli wifi status
```

也可在 WebUI“模块控制”页启用和维护名单。`cli wifi disable` 会停止自动切换并恢复 `rule`。

MagicNet 现在只内置 sing-box。核心选择命令保留为兼容入口，使用 `cli core select sing-box` 写入 `.config/magicnet/current-core.conf`。旧的 `.disable_sing_box` 隐藏开关已经移除，不再作为禁用 sing-box 的设计。

## Clash-style subscription to sing-box

如果你的合法订阅仍标注为 Clash、Clash Premium 或 mihomo，直接把同一个订阅 URL 作为 sing-box 来源：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli sub update sing-box
```

MagicNet 会抓取常见 Clash-style 节点 payload，并重新生成 `.config/sing-box/config.json` 里的 sing-box `outbounds`。旧的 mihomo 配置目录不会再被写入或启动。

MagicNet 新安装默认按节点名过滤 `免费`、`free`、`HK`、`香港`、`TW`、`台湾`，可在 WebUI 的订阅页删除部分关键词，或清空并保存以关闭过滤。过滤规则会同时作用于新下载、缓存回放与配置修复后的节点列表。导入后的其余节点统一放进 `proxy` 选择器；AI 选择器固定排除中国大陆、香港和台湾标签，并按美国、日本、其他地区的顺序排列候选节点。规则选择器只在 `proxy`、`direct`、`block` 之间切换，不再生成固定的地区桶。如果节点数量明显少于订阅内容，也可能是订阅里包含当前 shell 导入器不支持的协议或字段；安装了 proxylink 时会优先用它生成 sing-box outbounds，以覆盖更多协议。

## 透明代理边界

MagicNet 目前只支持 `tun` 透明模式，使用 `sing-box` `magicnet0` TUN 接管透明流量。旧配置中的 `proxy`、`external-tun`、`hybrid` 会安全归一为 `tun`，CLI 不再接受这些模式。

- 分应用策略分为三类：`Proxy` 强制走代理；`Direct` 仍进入 TUN，但强制走 `direct` 出站；`Bypass TUN` 则让应用完全离开 MagicNet。
- WebUI 的“全局接管”对应黑名单语义：默认应用进入 TUN，`Bypass TUN` 名单走系统网络；“仅名单接管”对应白名单语义：只有 `Proxy` 和 `Direct` 名单进入 TUN。
- Root 命令行模式会把包名解析为 Android UID，再通过 TUN 的 `include_uid` / `exclude_uid` 执行边界，避免包名过滤在重启后失效。共享同一 UID 的应用会一起生效。
- `Bypass TUN` 不等于断网或阻止访问。应用离开 MagicNet 后会使用系统上游网络；如果上游网络或另一个 VPN 能访问 Google，加入 Bypass 后的 Chrome 仍然可以访问。
- 要验证 Chrome 没有使用 MagicNet 代理，请在 WebUI“应用策略”中选择 `Direct`，或执行 `cli app add com.android.chrome direct`。只有多 VPN 共存或明确需要完全避开 MagicNet 时才选择 `Bypass TUN`。
- 默认网络策略是双栈、DNS 优先 IPv4、`mixed` TUN 栈、MTU `1400` 和 UDP 会话超时 `5m`。
- 可在 WebUI 的“UDP / IPv6”卡片切换，或执行 `cli network set <ipv4_only|prefer_ipv4|prefer_ipv6> <1280-1500> <1m|3m|5m|10m|15m|30m>`。
- `ipv4_only` 是网络或代理节点不支持 IPv6 时的兼容回退；切回双栈会自动移除 MagicNet 管理的 IPv6 拦截规则。
- 可用性以 `cli health` 和物理出口抓包为准。
- 发布前请用 `tcpdump` 验证没有 `port 53 or port 853` 泄露。

## MCP 自动化

```bash
adb forward tcp:8766 tcp:8766
su -c /data/adb/modules/MagicNet/cli mcp enable
su -c /data/adb/modules/MagicNet/cli mcp secret
```

MCP 工具可管理配置源、黑名单、备份、状态检查和脱敏上下文。默认关闭，需要用户显式启用。MCP server 启动时会生成 `MAGICNET_MCP_SECRET` 并以 `0600` 权限保存在模块私有配置中；客户端请求需要带 `Authorization: Bearer <secret>` 或 `X-MagicNet-MCP-Secret: <secret>`。只有 root 命令行应读取这个 secret，可用 `cli mcp rotate-secret` 轮换。

## 社区

- 官方 Discord 群聊：[https://discord.gg/vXffnGge6](https://discord.gg/vXffnGge6)

## DNS 泄露验证

```bash
adb shell 'su -M -c "ip route get 1.1.1.1; ip -br link"'
adb shell 'su -M -c "timeout 10 tcpdump -ni rmnet_data0 \"port 53 or port 853\""'
```

目标状态是访问测试期间没有明文 DNS/DoT 流量从物理出口泄露。MagicNet 会在物理出口接口上拦截直连 53/853，避免绕过 TUN 的 DNS 直接出网；如需临时关闭，可设置 `MAGIC_DNS_LEAK_GUARD=0` 后重新应用配置。

DNS 模板保留 `bootstrap-local-dns` 作为启动和直连例外：它解析代理节点域名、局域网、国内直连域名和连通性检测，避免代理尚未建立时让 DNS detour 到代理造成自引用循环，也避免国内网站拿到错误 CDN。代理域名、AI、GFW 和海外媒体仍按规则走海外 DoH 和代理 detour；如果把 `default_domain_resolver` 指向走代理的 DNS，可能出现 `DNS query loopback in transport[...]` 并导致大量站点超时。

DNS 泄露检测站点会生成一次性探测域名，并根据收到查询的递归解析器判断是否泄露。为了避免这类探测域名被 `bootstrap-local-dns` 或运营商 DNS 解析，模板在所有国内/本地 DNS 规则之前放置高优先级规则，将 BrowserScan、BrowserLeaks、IPLeak、DNSLeakTest、Perfect Privacy、Surfshark、Whoer、DoILeak、Bash.ws、DNS.SB、NextDNS test 等泄露检测域名强制交给 `doh-cloudflare`。`doh-cloudflare` 本身配置了 `detour: proxy`，所以这些探测查询会从代理出口的远端 DoH 发出，而不是从手机本地运营商 DNS 发出。

## 设计取舍

MagicNet 借鉴成熟 Android root 网络模块的“核心启动器、透明规则分层、配置合法性检查、手动控制、日志可追踪”思路，但把对外定位收敛为网络安全分析与设备侧流量审计。IPSET_LKM 和 MCP 都是显式启用或可选增强，不会在默认路径里隐式接管用户网络。

## 使用说明与免责声明

- MagicNet 仅用于合法的自有网络和自有设备测试，请勿用于未经授权的网络、设备或其他违法用途。
- 用户需自行确认配置来源、网络策略和实际用途合法合规，并对配置与使用结果负责。
- root 权限和网络栈改动可能造成断网、配置损坏或设备行为异常；操作前请备份现有模块配置，并保留可用的恢复方式。
- 本软件按现状提供，不保证持续可用、适合特定用途或在所有设备与系统版本上正常工作。

## 许可证

MIT，见 `LICENSE`。
