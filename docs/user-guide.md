# MagicNet 用户指南

MagicNet 的目标是让 Android root 设备通过一条可观察、可回滚的 `sing-box` TUN 路径完成代理、直连、应用分流和网络诊断。透明数据面固定为 `magicnet0`；模块不占用 Android 系统 VPN slot，也不提供 TProxy 或 eBPF 模式。

## 第一次使用：跟着新手引导完成

WebUI 首次打开会自动弹出“新手引导”，后续也可以从页面里的“新手引导”入口重新打开。引导只讲当前主线支持的流程，不会提供订阅 URL、节点、token、password 或示例密钥。

- 确认设备前提：模块已安装、Root 可用、Private DNS 已关闭，MagicNet 只走 `sing-box` + `magicnet0` TUN。
- 添加来源：在“订阅”里填写你自己的订阅 URL，或者导入本地配置/订阅文件。MagicNet 不提供订阅服务，也不生成节点。
- 交给 MagicNet 校验并应用：保存后由 MagicNet 拉取、解析、校验并生成运行配置；节点选择通过现有控制流程完成，不要手工改运行中的 `sing-box` 配置文件。
- 验证链路后再做进阶策略：优先看“运行状态”和“诊断”，确认基础链路已经可用，再考虑应用、Wi‑Fi、热点等策略；异常细节继续看“输出”。

## 安装与控制入口

从 [MagicNet Releases](https://github.com/LIghtJUNction/MagicNet/releases) 下载 ZIP，在 Magisk、KernelSU 或 APatch 中安装并重启。系统“私人 DNS / 私密 DNS / Private DNS”应关闭，避免 DoT 绕过模块的 DNS 路径。

安装后有四个控制入口：

- 模块 WebUI：普通用户的主要入口，负责首次订阅、节点、应用、Wi-Fi、热点、网络参数和诊断。
- CLI：`/data/adb/modules/MagicNet/cli`，适合终端和恢复操作。
- MagicBox：独立 Android 控制壳，通过 root 调用同一 CLI；它不包含代理核心。
- MCP：默认关闭的工作站自动化入口，必须经过 secret 认证。

首次配置完成后检查：

```bash
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
su -c 'ip link show magicnet0'
```

三项分别确认整体健康、透明路径和 TUN 接口。只看到进程运行不代表设备流量已经进入 TUN。

## URL 与本地订阅

### URL 来源

在 WebUI“订阅”中一行填写一个合法 URL，保存并启用。CLI 的单 URL 快捷入口是：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli sub status
```

保存过程会下载到候选区，解析节点，生成候选 sing-box 配置，执行校验并原子替换运行配置。任一步失败都会保留上一次有效来源和配置。

### 本地文件来源

WebUI 的“导入本地文件”支持完整 sing-box JSON、Clash YAML、base64 订阅、常见分享链接和转换器可识别的文本。文件内容在设备本地进入同一套候选校验流程，不需要先上传到公共 URL。

导入成功后，本地文件成为持久来源；后续刷新继续使用它。保存新 URL 会原子切回 URL 来源。导入或切换失败时，WebUI 会报告失败阶段，当前有效配置继续运行，不应手工覆盖 `.config/sing-box/config.json` 来绕过校验。

原生分享链接覆盖 VLESS、VMess、Trojan、Shadowsocks、SOCKS/SOCKS5、Hysteria2、AnyTLS 和 TUIC。VMess WebSocket 会分别保留服务器地址、Host、SNI 与 path；SOCKS 认证要求用户名和密码同时有效。

## 节点测试与自动组

订阅节点进入 `proxy` 选择器，并参与 `proxy-auto` 自动测速。AI 服务有各自的候选和自动组；无合格节点时保持 fail-closed，不会悄悄回落到不相关地区。

```bash
su -c /data/adb/modules/MagicNet/cli node list
su -c '/data/adb/modules/MagicNet/cli node test "节点名"'
su -c /data/adb/modules/MagicNet/cli node test-all
su -c /data/adb/modules/MagicNet/cli node current
```

WebUI 可查看延迟、手动选择节点或切回自动组。选择结果会持久化；订阅更新后不存在的节点会被安全重建为有效候选。

## 应用策略

三种策略的边界不同：

- `Proxy`：应用进入 `magicnet0`，并强制使用代理规则。
- `Direct`：应用仍进入 TUN，但使用 `direct` 出站；验证“不要走 MagicNet 代理”通常选它。
- `Bypass TUN`：应用完全离开 MagicNet。模块按所有 Android 用户解析包 UID，并让这些 UID 同时绕过 TUN 与 DNS 捕获，适合外部 VPN 或明确的共存需求。部分设备的 `netd` 会以 UID 0 代发系统 DNS；存在 Bypass UID 时，DNS 捕获链会保守保留 UID 0 直通，以维持这项边界。

```bash
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.browser direct'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'
su -c /data/adb/modules/MagicNet/cli app list
```

应用重装、工作资料用户新增或包 UID 变化后，执行 `cli app apply` 或在 WebUI 重新应用策略，使 UID 列表按当前用户重新解析。

## Wi-Fi SSID/BSSID 策略

Wi-Fi 策略改变的是 sing-box 工作模式：

- `blacklist`：命中名单时切到 `direct`，其他网络保持 `rule`。
- `whitelist`：只有命中名单时使用 `rule`，其他网络切到 `direct`。

```bash
su -c '/data/adb/modules/MagicNet/cli wifi add-ssid "Home WiFi"'
su -c '/data/adb/modules/MagicNet/cli wifi add-bssid "12:34:56:78:9A:BC"'
su -c /data/adb/modules/MagicNet/cli wifi mode blacklist
su -c /data/adb/modules/MagicNet/cli wifi enable
su -c /data/adb/modules/MagicNet/cli wifi status
```

`cli wifi disable` 停止自动切换并恢复 `rule`。SSID 可能重复，要求精确网络时优先使用 BSSID。

## 热点

MagicNet 不创建热点，也不替代 Android 的 DHCP/NAT。启用热点 Proxy 后，MagicNet 会把当前 tether 接口的 IPv4 入站策略路由到 `magicnet0`，再通过 `hotspot` selector 选择 Direct 或 Proxy：

```bash
su -c /data/adb/modules/MagicNet/cli hotspot status
su -c /data/adb/modules/MagicNet/cli hotspot enable
su -c /data/adb/modules/MagicNet/cli hotspot disable
```

Proxy 会暂时关闭 Android tether 硬件卸载，避免厂商/BPF 快速路径绕过 TUN；disable 和模块卸载会恢复此前系统值。热点仍异常时，应区分客户端 DHCP/NAT 问题、厂商转发未进入 TUN和代理节点问题。

## LAN 与 Tailscale 边界

私有网段默认由 `lan` 规则直连，MagicNet 不接管路由器、局域网服务或外部 VPN overlay 的控制面。若 LAN 服务需要代理，使用明确的域名/路由规则，不要把整个私网误设为远端代理。

userspace Tailscale endpoint 是 sing-box 配置的一部分，需要显式添加；MagicNet 会协调 endpoint CIDR 与 `magicnet0` 路由并保护一次性 auth key。安装系统级 Tailscale App 并不等同于配置该 endpoint。配置和验收见 [Tailscale 说明](tailscale.md)。

## 网络兼容与恢复

默认网络参数是双栈、IPv4 优先、MTU 1400、UDP 超时 5 分钟。IPv6 或 QUIC/UDP 异常时可临时切换：

```bash
su -c /data/adb/modules/MagicNet/cli network status
su -c '/data/adb/modules/MagicNet/cli network set ipv4_only 1400 5m'
```

网络切换后断流，使用当前 TUN 路径恢复，不要选择不存在的模式：

```bash
su -c /data/adb/modules/MagicNet/cli repair
su -c /data/adb/modules/MagicNet/cli transparent apply
su -c /data/adb/modules/MagicNet/cli service restart sing-box
```

`repair` 修复模块管理的配置/运行状态；`config apply` 会物化全部运行时配置，仅在有效的 sing-box 配置或本地规则集发生变化时重启核心，避免无关文件变化切断邮件和消息应用的后台长连接。`transparent apply` 会重应用 TUN 与 DNS 捕获并重启核心。需要完整恢复时再执行 `service restart sing-box`。

## 健康检查与支持

排障证据按以下顺序收集：

```bash
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
su -c /data/adb/modules/MagicNet/cli sub status
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

- 域名失败但 IP 可达：检查 Private DNS、`cli dns status` 和 DNS 相关诊断。
- TCP 正常、UDP/QUIC 异常：检查网络策略、MTU、节点 UDP 能力和 `ipv4_only` 对照结果。
- 某应用策略无效：检查包名、Android 用户、`cli app list`，再执行 `cli app apply`。
- 热点设备异常而手机正常：检查 `cli hotspot status`，确认 `route_status=ready`、`downstream_interfaces` 和 `policy_rule`，再确认 tether offload 已关闭且客户端流量进入 `magicnet0`。
- 更新订阅失败：保留原配置，查看 `cli sub status` 和支持包中的失败阶段，不要删除回滚现场。

支持包和 WebUI Issue 草稿会做脱敏，但提交前仍应人工检查。不要公开订阅 URL、token、MCP secret、password、完整节点地址、设备序列号或未经检查的完整日志。
