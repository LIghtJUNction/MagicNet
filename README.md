<p align="center">
  <img src="./icon.png" alt="MagicNet Logo" width="180" />
</p>

<h1 align="center">MagicNet</h1>

<p align="center">
  Android root 设备上的 sing-box 透明网络工作台
</p>

<p align="center">
  <a href="https://github.com/LIghtJUNction/MagicNet/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/LIghtJUNction/MagicNet?display_name=tag&sort=semver&style=flat-square" /></a>
  <a href="https://github.com/LIghtJUNction/MagicNet/actions/workflows/quality.yml"><img alt="Code Quality" src="https://github.com/LIghtJUNction/MagicNet/actions/workflows/quality.yml/badge.svg?branch=main" /></a>
  <a href="https://github.com/LIghtJUNction/MagicNet/actions/workflows/init.yml"><img alt="Build" src="https://github.com/LIghtJUNction/MagicNet/actions/workflows/init.yml/badge.svg?branch=main" /></a>
  <a href="./sing-box"><img alt="sing-box fork" src="https://img.shields.io/badge/core-sing--box%20fork-17181C?style=flat-square" /></a>
  <img alt="TUN and eBPF" src="https://img.shields.io/badge/dataplane-TUN%20%7C%20eBPF-6E56CF?style=flat-square" />
  <a href="./LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/LIghtJUNction/MagicNet?style=flat-square" /></a>
</p>

MagicNet 用 root 管理的 [sing-box fork](sing-box) 接管、分流和代理 Android 设备流量，不占用系统 VPN slot。默认使用 `tun`；需要时可显式切换到 `ebpf`。主线只支持这两种模式，不包含 `auto`、TProxy、Redirect 或 netd `ALLOW_MULTI` 路径。

## 核心特色

- **订阅内容不限定为 sing-box 格式**：支持一行一个公网 HTTPS 订阅链接，最多五个来源。下载内容可识别 Clash/Mihomo YAML、base64、常见分享链接集合、sing-box JSON 和纯文本。
- **直接兼容 Clash/Mihomo 订阅**：无需先找“sing-box 专用订阅”。把同一个合法 Clash/Mihomo 订阅 URL 交给 MagicNet，模块会解析节点并生成受控的 sing-box 配置。
- **覆盖常见节点协议**：原生导入 VLESS、VMess、Trojan、Shadowsocks、SOCKS、Hysteria2、AnyTLS 与 TUIC；可选转换器可处理额外格式。
- **自带 sing-box fork 内核**：仓库固定内核子模块和 Android arm64 构建，包含 MagicNet 使用的 eBPF inbound、Android 兼容修复与回归测试，不调用系统中来源不明的 sing-box。
- **TUN 与 eBPF 两套透明数据面**：TUN 创建 `magicnet0`；eBPF 默认使用 hybrid，同时启用 local cgroup，并在确认下游接口后通过 shared TC 接管热点流量；没有下游接口时 shared 保持 pending。两种模式显式、互斥、原子切换，失败会回滚。
- **应用、Wi-Fi 与热点策略**：应用可设为 Proxy、Direct 或 Bypass；Wi-Fi 可按 SSID/BSSID 切换策略；热点可选择 Direct 或 Proxy。
- **配置模板仓库**：默认使用固定 commit 和 SHA-256 的 `MagicSingBox` 配置，也可改为自己的 GitHub/GitLab fork，在仓库中维护规则后原子同步。
- **DNS 与故障边界可见**：拦截物理出口上的明文 DNS/DoT，`cli health` 和 `cli transparent status` 分别按 TUN 接口或 eBPF capability/cgroup/TC 报告真实状态。
- **WebUI、CLI、MagicBox 与 MCP**：同一套受控命令覆盖日常配置、节点测试、诊断、备份和自动化；私密 payload 使用临时文件传递，支持包默认脱敏。

## 安装与首次成功运行

1. 从 [Releases](https://github.com/LIghtJUNction/MagicNet/releases) 下载模块 ZIP，在 Magisk、KernelSU 或 APatch 的模块页面安装并重启。
2. 在系统设置中关闭“私人 DNS / 私密 DNS / Private DNS”，不要保留为“自动”。
3. 打开 root 管理器提供的模块 WebUI，在“订阅”中保存合法的 URL，或导入本地 Clash YAML、base64、分享链接、JSON 或文本订阅。
4. 等待“保存并启用”完成，在 WebUI 健康页确认 sing-box 与当前数据面正常。默认 TUN 应建立 `magicnet0`；eBPF 应显示 local cgroup 状态及 shared attached/pending 状态。

也可以在 root shell 中完成 URL 配置和验收：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
```

成功状态应同时满足：`cli health` 没有核心/Dataplane 阻塞项，`cli transparent status` 的 configured/effective 状态准确。TUN 以 `magicnet0` 为准；eBPF 不能要求 `magicnet0`，而应报告 capability、local cgroup 与 shared TC/interface。MagicNet 不提供节点、订阅或外部出口，请只使用你有权使用且符合当地法律与服务条款的资源。

详细格式、协议和操作说明见 [用户指南](docs/user-guide.md)。

## 常用命令

```bash
# 状态与恢复
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
su -c /data/adb/modules/MagicNet/cli transparent set tun
su -c /data/adb/modules/MagicNet/cli transparent set ebpf
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
su -c /data/adb/modules/MagicNet/cli hotspot status

# 网络兼容与支持包
su -c /data/adb/modules/MagicNet/cli network status
su -c '/data/adb/modules/MagicNet/cli network set ipv4_only 1400 5m'
su -c /data/adb/modules/MagicNet/cli support bundle
```

## 网络边界

MagicNet 会拦截物理出口上的直连 DNS/DoT（53/853），但浏览器内置 DoH 和外部 VPN 有自己的流量边界。关闭 Private DNS 后再做泄露测试；抓包接口应以 `ip route get 1.1.1.1` 的实际物理出口为准。

MagicNet 不创建热点，不替代厂商 tethering/NAT，也不自动接管外部 VPN overlay。局域网默认走 `lan`/Direct；userspace Tailscale endpoint 需要显式配置，边界与验收见 [Tailscale 说明](docs/tailscale.md)。

断网时不要反复切换模式。保留当前现场，依次查看 configured/effective、rollback/pending 与健康状态：

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
git submodule update --init
kam build
```

产物位于 `dist/MagicNet.zip`。构建、包结构和发布验收见 [构建与发布包说明](docs/build.md)。

## 文档

- [用户指南](docs/user-guide.md)：安装、导入、节点、应用/Wi-Fi/热点与排障。
- [构建与发布包说明](docs/build.md)：发布 ZIP、依赖锁和包验收。
- [本机仿真、AVD 和真机验收](docs/local-simulation.md)：分层测试与安全传输目录。
- [MCP 自动化说明](docs/mcp.md)：认证、端口转发、日志和启动故障检查。
- [架构概览](ARCHITECTURE.md)：仓库模块、依赖方向和稳定边界；详细运行架构见 [当前架构](docs/next-gen-architecture.md)。
- [贡献指南](CONTRIBUTING.md)：开发环境、质量检查和改动边界。
- [安全策略](SECURITY.md)：私密漏洞报告方式和需要保持的安全属性。
- [MagicBox](MagicBox)：适用于 Android 系统的控制外壳；独立 APK 与源码位于子模块仓库。
- [kamfw 本地文档](src/MagicNet/lib/kamfw/README.md)：模块内嵌运行时；上游项目见 [MemDeco-WG/kamfw](https://github.com/MemDeco-WG/kamfw)。

## 社区与支持

- Discord：[加入官方群聊](https://discord.gg/asRwgK9FpA)
- GitHub Issue：建议附上 `cli health`、`cli transparent status` 和 `cli support bundle` 的脱敏结果。
- 开发支持：MagicNet 的网络功能不依赖 LLM API；如需 OpenAI 兼容的多模型接口，可以使用作者维护的 [LMM API Gateway](https://api.lmm.best)。

WebUI 的“反馈问题 / 创建 Issue”会先选择问题类型，再按类型生成脱敏上下文。提交前仍应检查正文，不要公开订阅 URL、token、secret、password、完整节点地址或设备标识。

## 许可证

MIT，见 [LICENSE](LICENSE)。
