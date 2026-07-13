# MagicNet

MagicNet 是一个 Android root TUN 透明代理模块，用 `sing-box` 和 `magicnet0` TUN 接管设备侧应用流量。它面向网络连通性验证、DNS 泄露检查、透明流量治理、分应用策略和自动化诊断。

> [!IMPORTANT]
> DNS 防泄露必读：请打开系统设置，搜索 `DNS`，找到“私人 DNS”“私密 DNS”“Private DNS”或类似表述，把私人 DNS 关闭，不要设置为自动加密。必须让 DNS 正常走 53 端口，让 MagicNet 模块接管并代理 DNS；否则 Android 系统或浏览器可能直接使用 DoT/DoH，导致 DNS 泄露检测仍然显示外部解析器。

> 需要 Magisk / KernelSU / APatch 等 root 管理器。当前版本：`v1.1.18`。Release 以发布页为准。

## 定位

MagicNet 不分发任何第三方连通性资源，也不内置可直接使用的外部出口。仓库只提供设备侧网络安全分析能力、规则框架、配置导入入口和自动化控制面。用户需要自行配置合法的自有测试资源。

## 当前主线

- 单核心：只启动和维护 `sing-box`。
- TUN：唯一透明代理路径，覆盖设备侧应用流量。
- 诊断：CLI / WebUI / MCP / support bundle 汇总运行状态、路由和 DNS 信息。

## 功能

- Android root 透明流量接管。
- TUN 透明流量策略。
- DNS 泄露检查和加密 DNS 配置模板。
- 国内/境外/AI/媒体/广告/局域网等规则分流框架。
- 分应用代理/旁路策略，支持黑名单和白名单模式。
- WebUI、CLI、MCP 三套控制面。
- 配置监听会在运行态配置变化后自动重新应用。
- 支持包导出会脱敏 URL、token、secret、password 等敏感字段。

## 安装

```bash
kam install LIghtJUNction/MagicNet
```

本地构建：

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init --recursive
chmod +x kam.sh
./kam.sh
```

## 首次配置

安装后写入你的合法自有测试配置：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/config"'
```

`cli setup` 会校验 URL、写入运行配置、更新设备侧配置、重载模块，并输出健康诊断结果。

## 添加节点

MagicNet 通过 `sing-box` 订阅导入节点，不在模块里手动逐个填写节点。安装后有两种入口：

- WebUI：打开模块 WebUI，进入“更多”里的“订阅”，一行一个填写合法订阅 URL，点击保存后会后台拉取并导入节点。
- CLI：执行 `su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'`。多订阅可用 `cli sub set-file sing-box <base64-lines>` 写入。

导入完成后，节点会写入 `sing-box` 配置的 `proxy` 选择器；节点选择、测速和切换在 `sing-box` WebUI 里完成。当前版本只维护 `sing-box`，Clash / mihomo 格式订阅也按 sing-box 来源导入。

## 常用 CLI

```bash
su -c /data/adb/modules/MagicNet/cli service status
su -c /data/adb/modules/MagicNet/cli service restart
su -c /data/adb/modules/MagicNet/cli core select sing-box
su -c /data/adb/modules/MagicNet/cli service restart sing-box
su -c /data/adb/modules/MagicNet/cli transparent set proxy
su -c /data/adb/modules/MagicNet/cli transparent set tun
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

MagicNet 现在只内置 sing-box。核心选择命令保留为兼容入口，使用 `cli core select sing-box` 写入 `.config/magicnet/current-core.conf`。旧的 `.disable_sing_box` 隐藏开关已经移除，不再作为禁用 sing-box 的设计。

## Clash-style subscription to sing-box

如果你的合法订阅仍标注为 Clash、Clash Premium 或 mihomo，直接把同一个订阅 URL 作为 sing-box 来源：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli sub update sing-box
```

MagicNet 会抓取常见 Clash-style 节点 payload，并重新生成 `.config/sing-box/config.json` 里的 sing-box `outbounds`。旧的 mihomo 配置目录不会再被写入或启动。

MagicNet 不按地区过滤订阅节点。导入后的节点统一放进 `proxy` 选择器；规则选择器只在 `proxy`、`direct`、`block` 之间切换，不再生成固定的 `hk`、`jp` 等地区桶。如果节点数量明显少于订阅内容，通常是订阅里包含当前 shell 导入器不支持的协议或字段；安装了 proxylink 时会优先用它生成 sing-box outbounds，以覆盖更多协议。

## 透明代理边界

TUN 是 MagicNet 当前唯一透明代理路径；CLI 和 WebUI 不再提供其它透明模式入口。

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

## 许可证

MIT，见 [LICENSE](LICENSE)。
