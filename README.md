<p align="center">
  <img src="./icon.png" alt="MagicNet Logo" width="180" />
</p>

<h1 align="center">MagicNet</h1>

<p align="center">
  <a href="./README.md">简体中文</a> · <a href="./README.en.md">English</a> · <a href="./README.ru.md">Русский</a>
</p>

<p align="center">
  给 root 过的 Android 手机，一个省心的 sing-box 透明代理
</p>

<p align="center">
  <a href="https://github.com/LIghtJUNction/MagicNet/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/LIghtJUNction/MagicNet?display_name=tag&sort=semver&style=flat-square" /></a>
  <a href="https://github.com/LIghtJUNction/MagicNet/actions/workflows/quality.yml"><img alt="Code Quality" src="https://github.com/LIghtJUNction/MagicNet/actions/workflows/quality.yml/badge.svg?branch=main" /></a>
  <a href="https://github.com/LIghtJUNction/MagicNet/actions/workflows/init.yml"><img alt="Build" src="https://github.com/LIghtJUNction/MagicNet/actions/workflows/init.yml/badge.svg?branch=main" /></a>
  <a href="./sing-box"><img alt="sing-box fork" src="https://img.shields.io/badge/core-sing--box%20fork-17181C?style=flat-square" /></a>
  <img alt="TUN and eBPF" src="https://img.shields.io/badge/dataplane-TUN%20%7C%20eBPF-6E56CF?style=flat-square" />
  <a href="./LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/LIghtJUNction/MagicNet?style=flat-square" /></a>
</p>

## 这是什么？

如果你的手机已经 root，又不想让代理 App 一直占着系统那个唯一的 VPN 位置，MagicNet 就是为你准备的。

它是一个 Magisk / KernelSU / APatch 模块，用我们自己维护的 [sing-box fork](sing-box) 在系统层面接管流量：哪些 App 走代理、哪些直连、连上家里 Wi-Fi 时怎么办、开热点给别人用时又怎么办——都可以按你的习惯来。

透明代理有两种方式可选：

- **`tun`（默认）**：创建一个叫 `magicnet0` 的虚拟网卡，稳妥、兼容性好，大多数人用它就够了。
- **`ebpf`**：直接在内核里挂钩子分流，适合想折腾、内核也支持的玩家。

两种模式需要你**手动、明确地**切换；切换使用带回滚的事务，失败时会尝试恢复旧状态，但恢复本身也可能失败，不能保证连接不中断。遇到失败，请检查 `cli transparent status`、`cli health` 和恢复诊断信息，不要反复切换模式。我们刻意没有做 `auto` 模式，也不再支持 TProxy、Redirect 或 netd `ALLOW_MULTI` 这些老路子——少即是多，出问题时也更好排查。

## 为什么你可能会喜欢它

**订阅随便丢进来就行。** 不用再到处找“sing-box 专用订阅”了。一行一个 HTTPS 链接，最多五个来源；Clash/Mihomo YAML、base64、一堆分享链接、sing-box JSON、纯文本，它都认得。手上那个 Clash 订阅直接贴进来，MagicNet 会自己解析节点，生成一份受控的 sing-box 配置。

**常见协议基本都覆盖了。** VLESS、VMess、Trojan、Shadowsocks、SOCKS、Hysteria2、AnyTLS、TUIC 都能原生导入；更冷门的格式可以交给可选的转换器处理。

> 老实说一句：内置的备用解析器只认常见的字面量字段和普通引号值。遇到不支持的协议、复杂的 TLS/传输选项、别名、块标量或需要转义的字段，就得靠完整转换器。如果转换器不可用或者失败了，MagicNet 会明确拒绝这份输入，**保留你当前能用的配置**，而不是硬着头皮塞一份坏的进去。

**内核是自己带的。** 仓库里固定了 sing-box 子模块和 Android arm64 构建，包含 MagicNet 需要的 eBPF inbound、Android 兼容修复和回归测试。不会去调用你系统里某个来路不明的 sing-box。

**eBPF 模式也能管热点。** eBPF 默认是 hybrid：本机流量走 local cgroup；确认有下游接口后，再通过 shared TC 接管热点流量。还没人连热点时，shared 会老老实实显示 pending，而不是假装已经就绪。

**分流策略贴近日常。** 每个 App 都可以设为 Proxy、Direct 或 Bypass；Wi-Fi 可以按 SSID/BSSID 自动切换策略（比如回家就直连）；热点可以选 Direct 或 Proxy。

**规则可以放在你自己的仓库里。** 默认使用固定 commit 和 SHA-256 校验的 `MagicSingBox` 配置模板；你也可以 fork 一份到 GitHub/GitLab，在自己的仓库里慢慢调规则，再原子同步到手机上。

**出了问题看得见。** 可选的物理出口 DNS/DoT 防护默认关闭；只有运行环境显式设置 `MAGIC_DNS_LEAK_GUARD=1` 且规则成功安装后，才会拦截相应直连流量。`cli health` 和 `cli transparent status` 会按真实情况报告——TUN 看 `magicnet0`，eBPF 看 capability、cgroup 和 TC。不知道的就说不知道，不会把“没查到”说成“一切正常”。

**WebUI、CLI、MCP 三种用法。** WebUI 和 MCP 复用 CLI 的受控操作；MCP 提供部分功能，包括服务控制、配置与订阅、应用策略、节点选择与测速、状态诊断和备份，并不保证覆盖所有 WebUI 操作。可用工具以 MCP 的 `tools/list` 返回结果为准。私密数据通过临时文件传递，支持包默认脱敏。WebUI 首页有一张“流量星座”，实时画出 设备 → 数据面 → sing-box → 出口 这条链路上已经确认的状态；按 `Ctrl/⌘ + K` 或 `/` 可以快速跳到任意页面。

## 五分钟上手

> **从旧版本升级到 v1.6.2 的朋友请注意：这次需要手动安装一次。** 为了符合 KernelSU Modules 的限制，版本码迁移成了 `10602`。先备份配置，然后在 root 管理器里直接安装 `MagicNet-full.zip`——**不要先卸载**。详情见 [版本码迁移说明](docs/releases/v1.6.2.md)。

1. 到 [Releases](https://github.com/LIghtJUNction/MagicNet/releases) 下载模块 ZIP，在 Magisk、KernelSU 或 APatch 里安装，然后重启。
2. 去系统设置里把“私人 DNS / 私密 DNS / Private DNS”**关掉**。注意是关闭，“自动”也不行。
3. 在 root 管理器里打开模块的 WebUI，进入“订阅”，贴上你的订阅 URL；或者导入本地的 Clash YAML、base64、分享链接、JSON 或文本。
4. 点“保存并启用”，等它跑完，然后去健康页看一眼：sing-box 和数据面都正常就大功告成。默认的 TUN 模式下应该能看到 `magicnet0`；如果你用的是 eBPF，会看到 local cgroup 状态，以及 shared 是 attached 还是 pending。

更喜欢命令行？在 root shell 里三行搞定：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
```

怎么算成功？`cli health` 里没有核心/数据面的阻塞项，`cli transparent status` 里 configured（你想要的）和 effective（实际生效的）状态都对得上。TUN 模式以 `magicnet0` 为准；eBPF 模式本来就不会有 `magicnet0`，看 capability、local cgroup 和 shared TC/interface 就好。

> MagicNet 只是工具，不提供任何节点、订阅或出口服务。请只使用你有权使用、并且符合当地法律和服务条款的资源。

想了解更多格式、协议和操作细节，请看 [用户指南](docs/user-guide.md)。

## 常用命令速查

```bash
# 看状态 / 修问题
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

# 应用策略：普通直连用 direct；要和别的 VPN App 共存时才用 bypass
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.browser direct'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'

# Wi-Fi 与热点
su -c '/data/adb/modules/MagicNet/cli wifi add-ssid "Home WiFi"'
su -c /data/adb/modules/MagicNet/cli wifi enable
su -c /data/adb/modules/MagicNet/cli hotspot enable
su -c /data/adb/modules/MagicNet/cli hotspot status

# 网络兼容 / 打包支持信息
su -c /data/adb/modules/MagicNet/cli network status
su -c '/data/adb/modules/MagicNet/cli network set ipv4_only 1400 5m'
su -c /data/adb/modules/MagicNet/cli support bundle
```

## 它管什么，不管什么

先把边界说清楚，免得踩坑：

- 物理出口上的直连 DNS/DoT（53/853 端口）拦截是可选防护，默认关闭。它要求运行环境显式设置 `MAGIC_DNS_LEAK_GUARD=1`，且设备支持并成功安装相应规则；不要将默认安装视为已经启用此防护。但浏览器自带的 DoH、以及其他 VPN App 有它们自己的流量路径，不在它的管辖范围内。做 DNS 泄露测试前，记得先关掉 Private DNS；抓包时以 `ip route get 1.1.1.1` 显示的真实物理出口为准。
- 它**不会**帮你开热点，也不替代厂商自带的 tethering/NAT，更不会自动接管其他 VPN 的 overlay 网络。
- 局域网流量默认走 `lan`/Direct。如果你用 userspace 版 Tailscale，需要手动配置一下，具体看 [Tailscale 说明](docs/tailscale.md)。

**断网了先别慌，也别来回切模式。** 保留现场，按顺序看看 configured/effective、有没有 rollback/pending、健康检查怎么说：

```bash
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

把这些结果（脱敏后）带上来找我们，排查会快很多。

## 怎么操作它

- **模块 WebUI**：装好模块后，在 Magisk、KernelSU 或 APatch 的模块页面就能打开。首次配置、应用/Wi-Fi/热点策略、节点、诊断，基本都在这里完成。
- **多语言**：WebUI 支持简体中文、English 和 Русский，切换后会记住你的选择。安装向导和模块操作菜单支持英文、俄语，以及原有的中文、日语和韩语；安装器默认跟随系统语言，交互安装时也可以手动选。
- **[MCP](docs/mcp.md)**：想从电脑上自动化控制真机的话可以用它。默认关闭，开启后需要 secret 认证。

终端菜单可以临时指定语言，比如用俄语打开：

```bash
su -c 'KAM_UI_LANGUAGE=ru sh /data/adb/modules/MagicNet/action.sh'
```

CLI 命令、状态字段、配置值和原始日志都保持英文原样，方便脚本和诊断工具读取；内置的第三方内核面板则跟随它自己的语言设置。

## 想自己构建？

如果你已经配置好了 [kam](https://github.com/MemDeco-WG/kamfw)，一行就能装：

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

构建产物在 `dist/MagicNet.zip`。打包结构和发布验收的细节见 [构建与发布包说明](docs/build.md)。

## 延伸阅读

- [用户指南](docs/user-guide.md)：安装、导入、节点、应用/Wi-Fi/热点和排障。
- [构建与发布包说明](docs/build.md)：发布 ZIP、依赖锁和包验收。
- [本机仿真、AVD 和真机验收](docs/local-simulation.md)：分层测试和安全的文件中转目录。
- [MCP 自动化说明](docs/mcp.md)：认证、端口转发、日志和启动故障排查。
- [架构说明](ARCHITECTURE.md)：仓库结构、运行架构、状态归属和故障边界。
- [贡献指南](CONTRIBUTING.md)：开发环境、质量检查和改动边界。
- [安全策略](SECURITY.md)：如何私下报告漏洞，以及我们坚持的安全原则。
- [kamfw 本地文档](src/MagicNet/lib/kamfw/README.md)：模块内嵌的运行时；上游项目在 [MemDeco-WG/kamfw](https://github.com/MemDeco-WG/kamfw)。

## 找到我们

<a href="https://donate.lmm.best/?project=magicnet"><img src="https://donate.lmm.best/badge.svg?project=magicnet&amp;currency=CNY&amp;lang=zh-CN&amp;period=all&amp;layout=compact&amp;theme=dark&amp;width=360&amp;title=MagicNet" alt="捐赠支持" width="360" /></a>

如果 MagicNet 帮到了你，欢迎请作者喝杯咖啡 ☕，也欢迎来聊聊：

- **Discord**：[加入官方群聊](https://discord.gg/asRwgK9FpA)
- **GitHub Issue**：提问时附上 `cli health`、`cli transparent status` 和 `cli support bundle` 的脱敏结果，能帮我们更快定位问题。
- **开发小广告**：MagicNet 的网络功能完全不依赖任何 LLM API。如果你恰好需要一个 OpenAI 兼容的多模型接口，可以试试 [LMM API Gateway](https://api.lmm.best)，[项目源码](https://github.com/TokenNotIncluded/api.lmm.best)现由 [TokenNotIncluded](https://github.com/TokenNotIncluded) 组织托管。

WebUI 里的“反馈问题 / 创建 Issue”会先选择问题类型，再自动生成对应的脱敏上下文。不过提交前还是请自己再过一眼——**千万别把订阅 URL、token、secret、password、完整节点地址或设备标识公开出去。**

## 许可证

MIT，详见 [LICENSE](LICENSE)。
