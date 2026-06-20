# MagicNet

MagicNet 是一个 Android root 网络安全分析模块，用于在真实设备上接管、审计和调试系统网络流量。它面向网络连通性验证、DNS 泄露检查、透明流量治理、热点共享审计、分应用流量策略和自动化诊断。

> [!IMPORTANT]
> DNS 防泄露必读：请打开系统设置，搜索 `DNS`，找到“私人 DNS”“私密 DNS”“Private DNS”或类似表述，把私人 DNS 关闭，不要设置为自动加密。必须让 DNS 正常走 53 端口，让 MagicNet 模块接管并代理 DNS；否则 Android 系统或浏览器可能直接使用 DoT/DoH，导致 DNS 泄露检测仍然显示外部解析器。

> 需要 Magisk / KernelSU / APatch 等 root 管理器。当前版本：`v1.1.6`。Release 以发布页为准。

## 定位

MagicNet 不分发任何第三方连通性资源，也不内置可直接使用的外部出口。仓库只提供设备侧网络安全分析能力、规则框架、配置导入入口和自动化控制面。用户需要自行配置合法的自有测试资源。

## 创新点

- 系统级透明流量审计：在 Android root 环境下接管设备网络路径，用统一的虚拟网卡 `magicnet0` 承载流量分析、路由治理和泄露验证。
- 双路径透明治理：支持默认虚拟网卡接管和实验 eBPF 模式，规则应用、清理和诊断全部可追踪，不做静默 fallback。
- 无内置外部资源发行：默认配置不捆绑第三方连通性资源，降低误用、失效和合规风险。
- 设备侧安全运维面：内置 Rust CLI、可选 MCP server、健康检查、支持包、热点转发、VPN 共存、系统 CA 管理和抓包规则。
- 自动化诊断闭环：通过 ADB、CLI、WebUI 和 MCP 将配置、状态、路由、监听端口、日志和连通性结果汇总成可复现证据。

## 功能

- Android root 透明流量接管，默认虚拟网卡名为 `magicnet0`。
- `auto` / TUN / eBPF 三种透明流量策略。默认 `auto` 会优先检查 eBPF 数据面，完整可用才启用；否则直接走 TUN 兜底。mihomo 仅支持 TUN，sing-box 支持 TUN 和 MagicNet eBPF 路径。
- DNS 泄露检查和加密 DNS 配置模板。
- 国内/境外/AI/媒体/广告/局域网等规则分流框架。
- 分应用代理/旁路策略，支持黑名单和白名单模式。
- 热点客户端 `proxy` / `direct` 两种模式。
- VPN 共存模式，便于与 Tailscale、WireGuard、OpenVPN、ZeroTier、WARP 等隧道同时运行。
- WebUI、CLI、MCP 三套控制面。
- watchdog 保活和配置监听，运行态配置变化后自动重新应用。
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

## 常用 CLI

```bash
su -c /data/adb/modules/MagicNet/cli service status
su -c /data/adb/modules/MagicNet/cli service restart
su -c /data/adb/modules/MagicNet/cli core select sing-box
su -c /data/adb/modules/MagicNet/cli core select mihomo
su -c /data/adb/modules/MagicNet/cli service restart sing-box
su -c /data/adb/modules/MagicNet/cli service restart mihomo
su -c /data/adb/modules/MagicNet/cli transparent set auto
su -c /data/adb/modules/MagicNet/cli transparent set tun
su -c /data/adb/modules/MagicNet/cli transparent set ebpf
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

核心选择由 `.config/magicnet/core.conf` 管理，使用 `cli core select <sing-box|mihomo>` 修改。旧的 `.disable_sing_box` 隐藏开关已经移除，不再作为禁用 sing-box 的设计。

## eBPF 模式要求

eBPF 模式不是 sing-box 的原生开关，而是 MagicNet 的透明治理路径。它要求 Android 内核具备完整的 BPF / cgroup BPF 能力，并由 MagicNet 自身的 eBPF loader 完成挂载、TCP bridge 转交和 DNS 53 专用重定向。

- Android 12 之前：大量老旧内核，例如 Linux 4.19 / 5.4，默认没有开启 BTF 支持，eBPF 模式通常不可用或只能用于开发者实验。
- Android 12 / Android 13 及之后：谷歌对新内核，例如 Linux 5.10 / 5.15+，要求启用 `CONFIG_DEBUG_INFO_BTF=y`，较新的手机通常原生带 BTF，更适合作为 eBPF 模式目标设备。
- 真机仍需通过 `cli health` / `cli diagnose` 检查 `CONFIG_BPF`、`CONFIG_BPF_SYSCALL`、`CONFIG_CGROUP_BPF`、bpffs、cgroup 和 MagicNet eBPF loader。检查失败时应回落到 TUN。
- 当前 MagicNet eBPF 数据面通过 cgroup/connect 记录并改写 TCP 连接，通过 sock_ops 建立原始目的地索引，再由本地 TCP bridge 转交给 sing-box mixed 入站；用户修改 sing-box mixed 端口时，loader 会从配置解析端口，不需要硬编码。
- DNS 透明接管已经进入 eBPF 路径：TCP 53 在 connect 阶段改写到本地 sing-box DNS 入站，UDP 53 通过 cgroup/udp sendmsg 改写到同一入口。DNS 入站端口默认 1053，可从配置解析或用 `MAGICNET_EBPF_DNS_PORT` 覆盖。
- 全量 UDP 暂不走 eBPF 透明代理。QUIC、游戏、WebRTC、VoIP 等协议仍以 TUN 作为完整兜底路径。严格 eBPF 失败时必须回落到 TUN，避免半可用透明代理导致断网。
- UDP sendmsg 挂载成功不等于厂商内核一定会改写所有 UDP syscall 路径。发布前必须用 `tcpdump` 抓物理出口验证 `port 53 or port 853`；若仍看到明文 DNS 外发，应切回 TUN。

## MCP 自动化

```bash
adb forward tcp:8766 tcp:8766
su -c /data/adb/modules/MagicNet/cli mcp enable
```

MCP 工具可管理配置源、黑名单、备份、状态检查和脱敏上下文。默认关闭，需要用户显式启用。

## 社区

- 官方 Discord 群聊：[https://discord.gg/vXffnGge6](https://discord.gg/vXffnGge6)

## DNS 泄露验证

```bash
adb shell 'su -M -c "ip route get 1.1.1.1; ip -br link"'
adb shell 'su -M -c "timeout 10 tcpdump -ni rmnet_data0 \"port 53 or port 853\""'
```

目标状态是访问测试期间没有明文 DNS/DoT 流量从物理出口泄露。MagicNet 会在物理出口接口上拦截直连 53/853，避免绕过 TUN/eBPF 的 DNS 直接出网；如需临时关闭，可设置 `MAGIC_DNS_LEAK_GUARD=0` 后重新应用配置。

DNS 模板保留 `bootstrap-local-dns` 作为启动和直连例外：它解析代理节点域名、局域网、国内直连域名和连通性检测，避免代理尚未建立时让 DNS detour 到代理造成自引用循环，也避免国内网站拿到错误 CDN。代理域名、AI、GFW 和海外媒体仍按规则走海外 DoH 和代理 detour；如果把 `default_domain_resolver` 指向走代理的 DNS，可能出现 `DNS query loopback in transport[...]` 并导致大量站点超时。

## 设计取舍

MagicNet 借鉴成熟 Android root 网络模块的“核心启动器、透明规则分层、配置合法性检查、手动控制、日志可追踪”思路，但把对外定位收敛为网络安全分析与设备侧流量审计。eBPF、IPSET_LKM、VPN 共存和 MCP 都是显式启用或可选增强，不会在默认路径里隐式接管用户网络。

## 许可证

MIT，见 [LICENSE](LICENSE)。
