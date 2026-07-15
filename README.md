# MagicNet

<div align="center">
  <p>
    <a href="kam.toml"><img alt="MagicNet v1.1.20" src="https://img.shields.io/badge/MagicNet-v1.1.20-31c2f2" /></a>
    <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-green.svg" /></a>
    <a href="Cargo.toml"><img alt="Rust workspace" src="https://img.shields.io/badge/Rust-workspace-f46623?logo=rust&logoColor=white" /></a>
    <a href="webui/package.json"><img alt="Vue WebUI" src="https://img.shields.io/badge/WebUI-Vue%203-42b883?logo=vue.js&logoColor=white" /></a>
    <a href="kam.toml"><img alt="Built with KAM" src="https://img.shields.io/badge/Built%20with-KAM-8b5cf6" /></a>
    <a href="https://discord.gg/vXffnGge6"><img alt="Official Discord" src="https://img.shields.io/badge/Discord-official%20chat-5865F2?logo=discord&logoColor=white" /></a>
    <a href="https://github.com/LIghtJUNction/MagicNet/releases"><img alt="Release downloads" src="https://img.shields.io/github/downloads/LIghtJUNction/MagicNet/total?label=downloads&logo=github" /></a>
  </p>
</div>

<p align="center">
  <a href="#成果">成果</a>
  · <a href="#快速开始">快速开始</a>
  · <a href="#cli">CLI</a>
  · <a href="#dns-防泄露">DNS</a>
  · <a href="#mcp-自动化">MCP</a>
</p>

> [!IMPORTANT]
> DNS 防泄露必读：请打开系统设置，搜索 `DNS`，找到“私人 DNS”“私密 DNS”“Private DNS”或类似表述，把私人 DNS 关闭，不要设置为自动加密。必须让 DNS 正常走 53 端口，让 MagicNet 接管并代理 DNS；否则 Android 系统或浏览器可能直接使用 DoT/DoH，导致 DNS 泄露检测仍然显示外部解析器。

MagicNet 是一个 Android root 网络编排模块，把设备流量或显式代理流量接入 `sing-box` 策略平面。MagicNet 不包含 Android 应用侧 `VpnService.establish()`，不会由 MagicNet App 独占系统 VPN slot；默认兼容路径仍可通过 root/sing-box `magicnet0` TUN 接管、分流、代理或拒绝流量。

当前主线已经收敛为 **sing-box + 用户态编排**。`sing-box` 是唯一代理核心；MagicNet 提供 `proxy`、`external-tun`、`hybrid` 和兼容 `tun` 四种运行模式。下一代设计详见 [docs/next-gen-architecture.md](docs/next-gen-architecture.md)。旧的 TProxy 主路径、多核心切换和抓包代理功能都不再作为主线能力维护。

需要 Magisk / KernelSU / APatch 等 root 管理器。当前版本：`v1.1.20`。Release 以发布页为准。

## 成果

MagicNet 不分发任何第三方连通性资源，也不内置可直接使用的外部出口。你需要接入合法、合规、自有的节点或订阅。

## 快速开始

```bash
kam install LIghtJUNction/MagicNet
```

也可以安装发行仓库里的模块包：

```bash
kam -S MagicNet
kam install MagicNet.zip
```

安装后写入你的合法 `sing-box` 订阅或节点源：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
```

`cli setup` 会校验 URL、写入订阅源、更新 `sing-box` 配置、应用透明模式，并输出健康诊断结果。模块 WebUI 首页的“保存并启用”使用同一条 CLI 路径。

## 添加节点

MagicNet 通过 `sing-box` 订阅导入节点，不在模块里手动逐个填写节点。安装后有两种入口：

- WebUI：打开模块 WebUI，进入“更多”里的“订阅”，一行一个填写合法订阅 URL，点击保存后会后台拉取并导入节点。
- CLI：执行 `su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'`。多订阅可用下方 `sub set-file sing-box` 写入。

导入完成后，节点会写入 `sing-box` 配置的 `proxy` 选择器；节点选择、测速和切换在 `sing-box` WebUI 里完成。当前版本只维护 `sing-box`，Clash / mihomo 格式订阅也按 sing-box 来源导入。

## 运行模式

推荐零冲突代理模式（不占用系统 VPN，可与 Clash / WireGuard / sing-box VPN 共存）：

```bash
su -c /data/adb/modules/MagicNet/cli transparent set proxy
```

其它编排模式：

```bash
su -c /data/adb/modules/MagicNet/cli transparent set external-tun
su -c /data/adb/modules/MagicNet/cli transparent set hybrid
su -c /data/adb/modules/MagicNet/cli transparent set tun
```

## 核心功能

- TUN 透明代理：通过 `magicnet0` 接管设备侧应用流量。
- DNS 防泄露：直连 53/853 出口拦截，泄露检测域名强制远端 DoH。
- 单核心：只维护 `sing-box`，不再维护多核心、多透明路径。
- 诊断面：CLI、WebUI、MCP、support bundle、路由和 DNS 状态检查。

## 安装

### 使用 kam

```bash
kam install LIghtJUNction/MagicNet
```

### Termux / 本地构建安装

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init --recursive
chmod +x kam.sh
./kam.sh
```

以上方式安装的是 Git 构建版本。

### Release 包

当前 release 下载页：<https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.1.20>

直接下载当前模块包：<https://github.com/LIghtJUNction/MagicNet/releases/download/v1.1.20/MagicNet.zip>

```bash
kam -S MagicNet
kam install MagicNet.zip
```

## 构建

```bash
git submodule update --init --recursive
kam build
```

构建产物位于：

```text
dist/MagicNet.zip
```

本机仿真、AVD/rootAVD 和真机验收流程见 [docs/local-simulation.md](docs/local-simulation.md)。

## CLI

模块内置可脚本化 CLI：

```bash
su -c /data/adb/modules/MagicNet/cli help
```

常用命令：

```bash
su -c /data/adb/modules/MagicNet/cli service status
su -c /data/adb/modules/MagicNet/cli service start
su -c /data/adb/modules/MagicNet/cli service stop
su -c /data/adb/modules/MagicNet/cli service restart
su -c /data/adb/modules/MagicNet/cli core select sing-box
su -c /data/adb/modules/MagicNet/cli service restart sing-box
su -c /data/adb/modules/MagicNet/cli transparent status
su -c /data/adb/modules/MagicNet/cli transparent set tun
su -c /data/adb/modules/MagicNet/cli config apply
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli diagnose
```

`cli core select sing-box` 只保留为兼容入口，会写入 `.config/magicnet/current-core.conf`。MagicNet 不再接受其它核心名；需要指定某次启动的核心时，直接执行 `cli service restart sing-box`。

订阅、状态和诊断：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli sub update sing-box
su -c /data/adb/modules/MagicNet/cli sub update-all
su -c /data/adb/modules/MagicNet/cli sub list
su -c /data/adb/modules/MagicNet/cli api stats
su -c /data/adb/modules/MagicNet/cli api close-all
su -c /data/adb/modules/MagicNet/cli support bundle
su -c /data/adb/modules/MagicNet/cli ecapture status
su -c /data/adb/modules/MagicNet/cli ecapture tls 15 all all
su -c '/data/adb/modules/MagicNet/cli ecapture pcap 15 wlan0 tcp port 443'
```

多订阅可以通过 WebUI 订阅页写入，也可以把多行 URL base64 后写入：

```bash
printf '%s\n' \
  'https://example.com/sub-a' \
  'https://example.com/sub-b' |
  base64 -w0
su -c '/data/adb/modules/MagicNet/cli sub set-file sing-box <base64-lines>'
su -c /data/adb/modules/MagicNet/cli sub update sing-box
```

导入器会更新 `.config/sing-box/config.json` 中的 `outbounds`。历史 `.config/mihomo` 文件不会被读取、迁移或保留。

MagicNet 不按地区过滤订阅节点。导入后的节点统一放进 `proxy` 选择器；规则选择器只在 `proxy`、`direct`、`block` 之间切换，不再生成固定的 `hk`、`jp` 等地区桶。如果节点数量明显少于订阅内容，通常是订阅里包含当前 shell 导入器不支持的协议或字段；安装了 proxylink 时会优先用它生成 sing-box outbounds，以覆盖更多协议。

自定义规则：

```bash
su -c /data/adb/modules/MagicNet/cli route list
su -c '/data/adb/modules/MagicNet/cli route add-domain proxy example.com'
su -c '/data/adb/modules/MagicNet/cli route add-domain direct example.cn'
su -c '/data/adb/modules/MagicNet/cli route add-domain block ads.example.com'
su -c /data/adb/modules/MagicNet/cli route apply
```

## DNS 防泄露

常用真机抓包方式：

```bash
adb shell 'su -M -c "timeout 10 tcpdump -ni rmnet_data0 \"port 53 or port 853\""'
```

不同设备的蜂窝出口可能是 `rmnet_data0`、`rmnet_data3` 或其它接口。先用以下命令确认出口：

```bash
adb shell 'su -M -c "ip route get 1.1.1.1; ip -br link"'
```

目标状态是访问测试期间没有明文 DNS/DoT 流量从物理出口偷偷跑出去。MagicNet 会在物理出口接口上拦截直连 53/853，避免绕过 TUN 的系统 DNS、root shell DNS 或浏览器回退 DNS 直接出网。若需要临时关闭这道闸门，可设置 `MAGIC_DNS_LEAK_GUARD=0` 后重新应用配置。

DNS 配置保留 `bootstrap-local-dns` 用于代理节点域名、局域网、国内直连域名和连通性检测，避免“代理还没连上，代理节点域名却要求先走代理”的自引用死循环。代理域名、AI、GFW、海外媒体和其它需要代理的业务域名仍走远端 DoH，并按规则使用代理 detour。

DNS 泄露检测站点会生成一次性探测域名，并根据收到查询的递归解析器判断是否泄露。为了避免这类探测域名被 `bootstrap-local-dns` 或运营商 DNS 解析，模板在所有国内/本地 DNS 规则之前放置高优先级规则，将 BrowserScan、BrowserLeaks、IPLeak、DNSLeakTest、Perfect Privacy、Surfshark、Whoer、DoILeak、Bash.ws、DNS.SB、NextDNS test 等泄露检测域名强制交给 `doh-cloudflare`。`doh-cloudflare` 本身配置了 `detour: proxy`，所以这些探测查询会从代理出口的远端 DoH 发出，而不是从手机本地运营商 DNS 发出。

## MCP 自动化

MagicNet 可在设备上启动 MCP server，供本机 agent 通过 ADB 转发调用：

```bash
adb forward tcp:8766 tcp:8766
su -c /data/adb/modules/MagicNet/cli mcp enable
su -c /data/adb/modules/MagicNet/cli mcp secret
```

MCP 工具可管理配置源、封锁名单、备份、状态检查、eCapture 网络分析和脱敏上下文。默认关闭，需要用户显式启用。MCP server 启动时会生成 `MAGICNET_MCP_SECRET` 并以 `0600` 权限保存在模块私有配置中；客户端请求需要带 `Authorization: Bearer <secret>` 或 `X-MagicNet-MCP-Secret: <secret>`。只有 root 命令行应读取这个 secret，可用 `cli mcp rotate-secret` 轮换。

`cli ecapture tls` 会调用随模块打包的 [gojue/eCapture](https://github.com/gojue/ecapture) Android arm64 二进制，在限定时间内把 TLS 明文事件写入 `.log/ecapture-tls-events.log`；`cli ecapture pcap` 会在指定接口生成 `.log/ecapture.pcapng`。这属于 root 诊断能力，需要目标内核支持对应探针；它不会改变 MagicNet 的透明代理路径。

## 技术边界

- 运行模式只维护 MagicNet 自身数据面，不接管热点转发、外部 VPN overlay 或厂商 tethering 规则。
- `proxy`/`external-tun` 模式不创建 MagicNet 管理的 TUN；`hybrid`/`tun` 模式使用 sing-box `magicnet0` TUN。
- 发布前请用 `tcpdump` 验证物理出口没有 `port 53 or port 853` 泄露。
- 多核心切换、多透明路径、热点代理模式和 VPN 共存模式都不是当前主线能力。

## 工作流

仓库提供两个 GitHub Actions：

- `Validate MagicNet`：校验 `kam.toml`、Shell 脚本和底层运行配置。
- `Build MagicNet`：初始化子模块、下载构建依赖、执行 `kam build`，并上传 `dist/*.zip` artifact。

工作流不会自动提交、不会自动更新子模块指针，也不会把构建产物写回 Git 历史。需要更新子模块时，请在对应子项目提交后，在父项目显式提交新的 submodule 指针。

## 子项目

- [MagicSingBox](https://github.com/LIghtJUNction/MagicSingBox)：sing-box 运行配置模板。
- [MagicBox](MagicBox)：Android 控制壳，面向 TUN-only MagicNet 模块。
- [kamfw](https://github.com/MemDeco-WG/kamfw)：运行时辅助库。

## 社区

- 官方 Discord 群聊：[https://discord.gg/vXffnGge6](https://discord.gg/vXffnGge6)

## 参考与致谢

- [yumebox](https://github.com/YumeLira/YumeBox)
- [Mimic-Node](https://github.com/LIghtJUNction/Mimic-Node)
- [DustinWin/ruleset_geodata](https://github.com/DustinWin/ruleset_geodata)
- [CHIZI-0618/box4magisk](https://github.com/CHIZI-0618/box4magisk)
- [taamarin/box_for_magisk](https://github.com/taamarin/box_for_magisk)
- [Fanju6/NetProxy-Magisk](https://github.com/Fanju6/NetProxy-Magisk)
- [Fanju6/Proxylink](https://github.com/Fanju6/Proxylink)
- [TanakaLun/IPSET_LKM](https://github.com/TanakaLun/IPSET_LKM)

## 许可证

MIT，见 [LICENSE](LICENSE)。
