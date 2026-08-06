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

Discord：[https://discord.gg/asRwgK9FpA](https://discord.gg/asRwgK9FpA)

## 许可证

MIT，见 `LICENSE`。
