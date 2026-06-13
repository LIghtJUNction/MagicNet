# MagicNet

MagicNet 是一个 Android root 网络安全分析模块，用于在真实设备上接管、审计和调试系统网络流量。它面向网络连通性验证、DNS 泄露检查、透明流量治理、热点共享审计、分应用流量策略和自动化诊断。

> 需要 Magisk / KernelSU / APatch 等 root 管理器。当前版本：`v1.1.0`。Release 以发布页为准。

## 定位

MagicNet 不分发任何第三方连通性资源，也不内置可直接使用的外部出口。仓库只提供设备侧网络安全分析能力、规则框架、配置导入入口和自动化控制面。用户需要自行配置合法的自有测试资源。

## 创新点

- 系统级透明流量审计：在 Android root 环境下接管设备网络路径，用统一的虚拟网卡 `magicnet0` 承载流量分析、路由治理和泄露验证。
- 双路径透明治理：支持默认虚拟网卡接管和显式 TProxy 模式，规则应用、清理和诊断全部可追踪，不做静默 fallback。
- 无内置外部资源发行：默认配置不捆绑第三方连通性资源，降低误用、失效和合规风险。
- 设备侧安全运维面：内置 Rust CLI、可选 MCP server、健康检查、支持包、热点转发、VPN 共存、系统 CA 管理和抓包规则。
- 自动化诊断闭环：通过 ADB、CLI、WebUI 和 MCP 将配置、状态、路由、监听端口、日志和连通性结果汇总成可复现证据。

## 功能

- Android root 透明流量接管，默认虚拟网卡名为 `magicnet0`。
- TUN / TProxy 两种透明流量模式，可显式切换。
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
su -c /data/adb/modules/MagicNet/cli transparent set tun
su -c /data/adb/modules/MagicNet/cli transparent set tproxy
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

核心选择由 `.config/magicnet/core.conf` 管理，使用 `cli core select <sing-box|mihomo>` 修改。旧的 `.disable_sing_box` 隐藏开关已经移除，不再作为禁用 sing-box 的设计。

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

目标状态是访问测试期间没有明文 DNS/DoT 流量从物理出口泄露。

## 设计取舍

MagicNet 借鉴成熟 Android root 网络模块的“核心启动器、透明规则分层、配置合法性检查、手动控制、日志可追踪”思路，但把对外定位收敛为网络安全分析与设备侧流量审计。TProxy、IPSET_LKM、VPN 共存和 MCP 都是显式启用或可选增强，不会在默认路径里隐式接管用户网络。

## 许可证

MIT，见 [LICENSE](LICENSE)。
