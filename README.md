<p align="center">
  <img src="./icon.png" alt="MagicNet Logo" width="180" />
</p>

<h1 align="center">MagicNet</h1>

<p align="center">
  Android root 设备上的 sing-box TUN 网络工作台
</p>

MagicNet 用 root 管理的 `sing-box` `magicnet0` TUN 接管、分流和代理 Android 设备流量。它不调用应用侧 `VpnService.establish()`，不会占用系统 VPN slot；当前主线只有 TUN，不包含 TProxy 或 eBPF 透明路径。

## 开源激励计划
- 前往https://api.lmm.best
- 接受挑战
- 完成挑战，中途我可以赠送一些小费
（提交issue/pr）
- 由我审核
- 审核通过，可兑换token使用

## 安装与首次成功运行

1. 从 [Releases](https://github.com/LIghtJUNction/MagicNet/releases) 下载模块 ZIP，在 Magisk、KernelSU 或 APatch 的模块页面安装并重启。
2. 在系统设置中关闭“私人 DNS / 私密 DNS / Private DNS”，不要保留为“自动”。
3. 打开 root 管理器提供的模块 WebUI，在“订阅”中保存合法的 URL，或导入本地 Clash YAML、base64、分享链接、JSON 或文本订阅。
4. 等待“保存并启用”完成，在 WebUI 健康页确认 sing-box 已运行且 `magicnet0` 已建立。

也可以在 root shell 中完成 URL 配置和验收：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
```

成功状态应同时满足：`cli health` 没有核心/TUN 阻塞项，`cli transparent status` 显示 TUN 路径，系统存在 `magicnet0`。MagicNet 不提供节点、订阅或外部出口，请只使用你有权使用且符合当地法律与服务条款的资源。

## 用户能做什么

- URL 与本地文件使用同一套校验、原子激活和失败回滚流程；切换来源不会留下半写入配置。
- 原生导入 Clash YAML、base64 和常见分享链接，包括 VLESS、VMess、Trojan、Shadowsocks、SOCKS、Hysteria2、AnyTLS 与 TUIC；可选转换器可覆盖更多格式。
- 在 `proxy`、自动测速组和服务专用组之间测试、选择与持久化节点。
- 按应用设置 `Proxy`、`Direct` 或 `Bypass TUN`。MagicNet 会按 Android 多用户动态解析 UID；Bypass 同时离开 TUN 与 MagicNet DNS 捕获。
- 按 Wi-Fi SSID/BSSID 使用黑名单或白名单，在 `rule` 与 `direct` 间自动切换。
- 为已经进入 TUN 的热点转发流量选择 Direct 或 Proxy；Proxy 期间暂时关闭 Android tether 硬件卸载，禁用或卸载时恢复原值。
- 在 CLI、WebUI、MagicBox 或 MCP 中管理配置，并用健康检查、脱敏支持包和 Issue 草稿排障。

完整操作见 [用户指南](docs/user-guide.md)。

## 常用命令

```bash
# 状态与恢复
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
su -c /data/adb/modules/MagicNet/cli repair
su -c /data/adb/modules/MagicNet/cli service restart sing-box

# 订阅与节点
su -c /data/adb/modules/MagicNet/cli sub status
su -c /data/adb/modules/MagicNet/cli sub update sing-box
su -c /data/adb/modules/MagicNet/cli node test-all

# 应用策略；bypass 适合与外部 VPN 共存，普通直连优先用 direct
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.browser direct'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'

# Wi-Fi 与热点
su -c '/data/adb/modules/MagicNet/cli wifi add-ssid "Home WiFi"'
su -c /data/adb/modules/MagicNet/cli wifi enable
su -c /data/adb/modules/MagicNet/cli hotspot enable

# 网络兼容与支持包
su -c /data/adb/modules/MagicNet/cli network status
su -c '/data/adb/modules/MagicNet/cli network set ipv4_only 1400 5m'
su -c /data/adb/modules/MagicNet/cli support bundle
```

## 网络边界

MagicNet 会拦截物理出口上的直连 DNS/DoT（53/853），但浏览器内置 DoH 和外部 VPN 有自己的流量边界。关闭 Private DNS 后再做泄露测试；抓包接口应以 `ip route get 1.1.1.1` 的实际物理出口为准。

MagicNet 不创建热点，不替代厂商 tethering/NAT，也不自动接管外部 VPN overlay。局域网默认走 `lan`/Direct；userspace Tailscale endpoint 需要显式配置，边界与验收见 [Tailscale 说明](docs/tailscale.md)。

断网时不要切换到不存在的透明模式。保留当前现场，依次查看：

```bash
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

## 控制界面

- 模块 WebUI：安装模块后由 Magisk、KernelSU 或 APatch 的模块页面打开，覆盖首次配置、应用/Wi-Fi/热点策略、节点与诊断。
- [MagicBox](MagicBox)：适用于 Android 系统的控制外壳；它需要已安装的 MagicNet，通过 root 调用 MagicNet CLI，不内置代理核心。
- [MCP](docs/mcp.md)：适合从工作站自动化控制真机，默认关闭且要求 secret 认证。

## 开发安装

已配置 [kam](https://github.com/MemDeco-WG/kamfw) 时可以直接安装：

```bash
kam install LIghtJUNction/MagicNet
```

从源码构建：

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init --recursive
kam build
```

产物位于 `dist/MagicNet.zip`。构建、包结构和发布验收见 [构建与发布包说明](docs/build.md)。

## 文档

- [用户指南](docs/user-guide.md)：安装、导入、节点、应用/Wi-Fi/热点与排障。
- [构建与发布包说明](docs/build.md)：发布 ZIP、依赖锁和包验收。
- [本机仿真、AVD 和真机验收](docs/local-simulation.md)：分层测试与安全传输目录。
- [MCP 自动化说明](docs/mcp.md)：认证、端口转发、日志和启动故障检查。
- [当前架构](docs/next-gen-architecture.md)：TUN 数据面、控制面、状态面和故障隔离。
- [MagicBox](MagicBox)：适用于 Android 系统的控制外壳；独立 APK 与源码位于子模块仓库。
- [kamfw 本地文档](src/MagicNet/lib/kamfw/README.md)：模块内嵌运行时；上游项目见 [MemDeco-WG/kamfw](https://github.com/MemDeco-WG/kamfw)。

## 社区与支持

- Discord：[加入官方群聊](https://discord.gg/asRwgK9FpA)
- GitHub Issue：建议附上 `cli health`、`cli transparent status` 和 `cli support bundle` 的脱敏结果。

WebUI 的“反馈问题 / 创建 Issue”会按问题类型生成脱敏上下文。提交前仍应检查正文，不要公开订阅 URL、token、secret、password、完整节点地址或设备标识。

## 推广

- [作者的中转站](https://api.lmm.best)：测试迭代中，源代码已开源；购买 token 表示支持。
- [AI 自动推广系统](https://bizbot.zvo.cn/)：探索 AI 驱动的自动推广工具与工作流。

提交 Issue 或 PR 有机会获得奖励。

## 许可证

MIT，见 [LICENSE](LICENSE)。
