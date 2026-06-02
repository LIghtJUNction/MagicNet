# MagicNet

MagicNet 是一个 KAM 构建的 Android root 模块，用于在设备上以 TUN 模式运行 `mihomo` 或 `sing-box`。

> 需要 Magisk / KernelSU / APatch 等 root 管理器。当前 Git 版本支持 mihomo / sing-box 双内核按需构建，Release 以发布页为准。

## 当前状态

- `kam build` 已可完整构建模块。
- 默认同时包含 `mihomo` 和 `sing-box`，可用环境变量关闭任一内核。
- 已内置 GeoIP / GeoSite 构建下载和配置校验流程。
- 已修复热点共享场景：启动内核后会自动给热点网卡到 TUN 网卡添加精确转发规则，避免直接清空 Android FORWARD 链。
- Git 历史已清理，不再保存下载的内核、zip 产物、GeoIP / GeoSite / mmdb 等生成二进制。

## 功能

- Android TUN 透明代理。
- mihomo / sing-box 双内核。
- 内置 mihomo 规则集和 Geo 数据更新。
- 默认 WebUI 跳转，可在安装时选择；mihomo / sing-box 均使用 Clash API 兼容控制端。
- 内置 CLI：服务启停、日志、节点热切换、模式切换、订阅更新、连接管理。
- kamfw watchdog 保活：核心异常退出后自动拉起，并通过 Android 通知提示重启事件和看门狗失败事件。
- kamfw fswatch 配置监听：`.config` 变化后自动重新应用运行态配置、抓包规则、热点转发和 VPN 共存规则。
- TUN 分应用代理：基于 sing-box TUN `include_package` / `exclude_package`，支持黑名单和白名单模式。
- 热点客户端可跟随本机 TUN 代理转发。
- 可选 root VPN 共存模式，便于与 Tailscale、WireGuard、OpenVPN、ZeroTier、WARP 等隧道同时运行。

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

```bash
kam -S MagicNet
kam install MagicNet.zip
```

## 构建

```bash
git submodule update --init --recursive
kam build
```

默认构建两个内核：

```bash
MAGIC_MIHOMO=1 MAGIC_SINGBOX=1 kam build
```

只构建 mihomo：

```bash
MAGIC_MIHOMO=1 MAGIC_SINGBOX=0 kam build
```

只构建 sing-box：

```bash
MAGIC_MIHOMO=0 MAGIC_SINGBOX=1 kam build
```

构建产物位于：

```text
dist/MagicNet.zip
```

## 配置

mihomo 配置：

```text
/data/adb/modules/MagicNet/.config/mihomo/config.yaml
```

sing-box 配置：

```text
/data/adb/modules/MagicNet/.config/sing-box/config.json
```

sing-box 订阅链接：

```text
/data/adb/modules/MagicNet/.config/sing-box/subscription.url
```

Clash / mihomo 订阅链接：

```text
/data/adb/modules/MagicNet/.config/mihomo/subscription.url
```

首次配置只需要一条命令：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/sub"'
```

`cli setup` 会校验订阅 URL，同时写入 sing-box 与 Clash / mihomo，更新订阅，重载运行配置，并在最后输出健康诊断结果。模块 WebUI 首页的“保存并启用”使用同一条 CLI 路径。

模块 WebUI 也可以直接读取、填写、保存、复制 sing-box 与 Clash / mihomo 订阅链接。保存 mihomo 链接时会同步更新 `config.yaml` 中第一个 `proxy-provider` 的 `url`。

在 `subscription.url` 第一行填入订阅链接后，执行模块 `action.sh`，选择 `更新 sing-box 订阅节点`。MagicNet 会下载订阅，转换为 sing-box `outbounds`，并保留原有 TUN、DNS、路由和 Clash API 配置。

当前自动导入支持两类订阅：

- Clash / Mihomo YAML：从 `proxies` 读取 `ss`、`vmess`、`vless`、`trojan`、`hysteria2`。
- 通用分享链接订阅：支持明文或 base64 编码的 `vless://`、`hysteria2://` 链接。

不支持的节点会跳过并显示数量。下载订阅有明确超时；如果下载失败但本地已有 `subscription.yaml` 缓存，会使用缓存继续导入。

默认控制端：

```text
http://127.0.0.1:9090
```

默认本地面板路径（sing-box 默认使用 zashboard）：

```text
http://127.0.0.1:9090/ui/zashboard/#/setup?hostname=127.0.0.1&port=9090
```

sing-box 使用 `experimental.clash_api` 提供 Clash API 兼容控制端，默认内置 zashboard 面板。若修改 `secret`，面板里也要同步填写。

安装时不会强制覆盖用户已有配置；需要更新时按安装提示确认。

## CLI

模块内置可脚本化 CLI：

```bash
su -c /data/adb/modules/MagicNet/cli help
```

常用命令：

```bash
su -c /data/adb/modules/MagicNet/cli service status
su -c /data/adb/modules/MagicNet/cli service start
su -c /data/adb/modules/MagicNet/cli service ensure
su -c /data/adb/modules/MagicNet/cli service stop
su -c /data/adb/modules/MagicNet/cli service restart
su -c /data/adb/modules/MagicNet/cli service logs sing-box 120
su -c /data/adb/modules/MagicNet/cli config apply
```

`service start` 会同时启动 kamfw watchdog 和 fswatch。watchdog 默认每 30 秒执行一次 `service ensure`，当 sing-box / mihomo 进程都不在时自动拉起默认 TUN 内核；如果确实由 watchdog 拉起核心，会发送一条 Android 通知。MagicNet 同步启用 kamfw 的 `watchdog start --notify`，当 `service ensure` 本身失败时也会发出看门狗失败通知。fswatch 默认每 15 秒监听 `.config`，检测到配置变化后执行 `config apply`，重新应用 zashboard、分应用策略、抓包规则、热点转发和 VPN 共存规则。

`service stop` 与 `service restart` 会先停止 watchdog / fswatch，避免手动停止后被立即拉回。通知依赖 Android `cmd notification`，部分 ROM 不保证横幅弹出，但通知会按 kamfw 的 shell 通知路径发送。

节点和模式热切换走 Clash API，不需要重刷模块：

```bash
su -c /data/adb/modules/MagicNet/cli node list
su -c /data/adb/modules/MagicNet/cli node current
su -c /data/adb/modules/MagicNet/cli node delay
su -c '/data/adb/modules/MagicNet/cli node delay "节点名"'
su -c '/data/adb/modules/MagicNet/cli node use "节点名"'
su -c /data/adb/modules/MagicNet/cli mode rule
su -c /data/adb/modules/MagicNet/cli mode global
su -c /data/adb/modules/MagicNet/cli mode direct
```

自定义域名分流：

```bash
su -c /data/adb/modules/MagicNet/cli route list
su -c '/data/adb/modules/MagicNet/cli route add-domain proxy openai.com'
su -c '/data/adb/modules/MagicNet/cli route add-domain direct example.cn'
su -c '/data/adb/modules/MagicNet/cli route add-domain block ads.example.com'
su -c '/data/adb/modules/MagicNet/cli route remove-domain proxy openai.com'
su -c /data/adb/modules/MagicNet/cli route apply
```

`cli route` 管理高优先级 `DOMAIN-SUFFIX` 规则，支持 `proxy`、`direct`、`block` 三类目标，并会同时写入 sing-box 与 mihomo 运行配置。WebUI 的“分流”页使用同一套 CLI。

订阅、控制端、连接管理：

```bash
su -c /data/adb/modules/MagicNet/cli sub update-all
su -c /data/adb/modules/MagicNet/cli sub list
su -c /data/adb/modules/MagicNet/cli sub get sing-box
su -c /data/adb/modules/MagicNet/cli sub get mihomo
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/sub"'
su -c '/data/adb/modules/MagicNet/cli sub set sing-box "https://example.com/sub"'
su -c '/data/adb/modules/MagicNet/cli sub set mihomo "https://example.com/clash.yaml"'
su -c /data/adb/modules/MagicNet/cli sub file sing-box
su -c /data/adb/modules/MagicNet/cli sub file mihomo
su -c /data/adb/modules/MagicNet/cli api ui
su -c /data/adb/modules/MagicNet/cli api stats
su -c /data/adb/modules/MagicNet/cli api close-all
```

系统 CA 证书管理：

```bash
su -c /data/adb/modules/MagicNet/cli cert list
su -c /data/adb/modules/MagicNet/cli cert dir
su -c '/data/adb/modules/MagicNet/cli cert remove "9a5ba575.0"'
```

WebUI 支持选择或粘贴 PEM / DER 证书并安装到模块目录：

```text
/data/adb/modules/MagicNet/system/etc/security/cacerts
```

证书通过 root 模块的 systemless 覆盖机制进入 Android 系统 CA 目录，安装或移除后需要重启生效。若设备内存在 `openssl`，MagicNet 会自动生成 Android 需要的 subject-hash `.0` 文件名；否则请上传已经按 Android 规则命名的 `hash.0` 文件。

网络修复与诊断：

```bash
su -c /data/adb/modules/MagicNet/cli hotspot reload
su -c /data/adb/modules/MagicNet/cli vpn reload
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli repair
su -c /data/adb/modules/MagicNet/cli support bundle
su -c /data/adb/modules/MagicNet/cli diagnose
```

`cli health` 输出稳定的 `key=status<TAB>detail` 诊断项，WebUI 的“诊断”页会把这些项目整理成状态卡片，并给出重启 TUN、更新订阅、重载热点/VPN 共存等快捷修复按钮。覆盖项包括核心进程、TUN 网卡、watchdog、fswatch、Clash API、订阅、抓包规则、热点、外部 VPN、系统 CA、直连探测和代理探测。

`cli repair` 是安全的一键自修复：重新应用运行配置、重载抓包/热点/VPN 共存规则、确保 TUN 内核和 supervisor 在线、清空旧连接，最后直接输出 `cli health` 结果。它不会自动覆盖订阅链接、证书或用户规则。

`cli support bundle` 会生成脱敏支持包，包含模块版本、服务状态、健康诊断、连接与流量统计、订阅配置状态、自定义分流规则、抓包规则、分应用策略、证书列表、监听端口、接口/路由、Clash API 摘要和近期日志。URL、token、secret、password 等敏感字段会被替换为 `<redacted>`，WebUI“诊断”页可一键复制。

## TUN 分应用代理

MagicNet 不引入 TUN 外的 TPROXY / REDIRECT fallback；主路线就是 sing-box / mihomo TUN。分应用能力直接使用 sing-box TUN 入站的包名过滤。

策略文件：

```text
/data/adb/modules/MagicNet/.config/magicnet/app-mode.conf
/data/adb/modules/MagicNet/.config/magicnet/app-proxy.list
/data/adb/modules/MagicNet/.config/magicnet/app-bypass.list
```

默认是 `blacklist`：`app-bypass.list` 里的包名绕过 MagicNet TUN，适合保护 Tailscale、WireGuard、OpenVPN、ZeroTier、WARP 等 VPN App，避免流量回环。

```bash
su -c /data/adb/modules/MagicNet/cli app list
su -c /data/adb/modules/MagicNet/cli app mode blacklist
su -c '/data/adb/modules/MagicNet/cli app add com.example.bank bypass'
su -c '/data/adb/modules/MagicNet/cli app remove com.example.bank'
```

`whitelist` 模式只接管 `app-proxy.list` 里的包名：

```bash
su -c /data/adb/modules/MagicNet/cli app mode whitelist
su -c '/data/adb/modules/MagicNet/cli app add com.openai.chatgpt proxy'
```

`cli app ...` 会自动把策略应用到 sing-box TUN 配置；如果 sing-box 正在运行，重启内核后生效。

如需在双内核包里强制跳过 sing-box、直接使用 mihomo fallback，创建以下文件：

```text
/data/adb/modules/MagicNet/.disable_sing_box
```

该文件存在时，开机启动、`action.sh` 和安装阶段 WebUI 选择都会跳过 sing-box。

## 技术架构

```text
Android boot / action.sh
        |
        v
+------------------+
| kamfw runtime    |
| phase dispatcher |
+------------------+
        |
        v
+---------------------------+
| MagicNet lifecycle        |
| - choose sing-box first   |
| - fallback to mihomo      |
| - refresh description     |
| - apply network helpers   |
+---------------------------+
        |
        +---------------------------+
        |                           |
        v                           v
+------------------+        +------------------+
| sing-box core    |        | mihomo core      |
| TUN + Clash API  |        | TUN + Clash API  |
| :7892 / :9090    |        | fallback kernel  |
+------------------+        +------------------+
        |                           |
        +-------------+-------------+
                      v
              Android routing
                      |
        +-------------+-------------+
        |                           |
        v                           v
  hotspot helper              VPN coexist helper
  iptables/NAT                ip rule/main table
```

启动策略：

- 默认优先启动 sing-box。
- sing-box 不存在、被 `.disable_sing_box` 禁用或启动失败时，自动尝试 mihomo fallback。
- 两个内核不会默认同时接管 TUN，避免路由、DNS 和透明代理互相抢流量。
- `action.sh` 可以手动更新 sing-box 订阅、设置 WebUI、切换内核启动/停止并刷新模块描述。

## 网络拓扑

基础拓扑：

```text
App traffic
    |
    v
Android kernel routing
    |
    v
MagicNet TUN interface
    |
    v
sing-box / mihomo rule engine
    |
    +--> DIRECT --> wlan0 / rmnet_data*
    |
    +--> PROXY  --> remote proxy node
    |
    +--> BLOCK  --> reject/drop
```

局域网、热点、VPN 这类特殊流量不会简单粗暴全塞进代理。MagicNet 会尽量保持系统原有链路可用，只在需要时补精确规则。

## 热点共享

MagicNet 默认启用热点转发修复：

```text
MAGIC_HOTSPOT_FORWARD=1
```

模块会在内核启动后：

- 自动识别 TUN 网卡。
- 自动识别常见热点网卡。
- 向 `tetherctrl_FORWARD` 或 `FORWARD` 添加热点到 TUN 的转发规则。
- 向 `nat POSTROUTING` 添加 TUN 出口 masquerade。

如需关闭：

```bash
MAGIC_HOTSPOT_FORWARD=0
```

特殊机型可手动指定网卡：

```bash
MAGIC_HOTSPOT_IFACES="wlan2"
MAGIC_TUN_IFACES="Meta"
```

### 场景一：开启 MagicNet，同时开启手机热点

真实链路通常是：

```text
Laptop / tablet
    |
    | Wi-Fi hotspot
    v
Android hotspot iface
ap0 / wlan1 / swlan0
    |
    | FORWARD accept
    v
MagicNet TUN
tun0 / Meta
    |
    +--> DIRECT: LAN/private/system traffic
    |
    +--> PROXY: selected remote node
```

没有热点修复时，Android 的 `tetherctrl_FORWARD` 可能不允许热点客户端进入 TUN，表现为手机自己能代理，但电脑连热点不能代理。MagicNet 启动内核后会识别热点网卡和 TUN 网卡，只补热点到 TUN 的转发和 NAT 规则，不清空系统链。

如果某台设备热点网卡命名特殊，手动指定：

```bash
MAGIC_HOTSPOT_IFACES="swlan0"
MAGIC_TUN_IFACES="tun0"
```

## VPN 共存

Android 普通 `VpnService` 同一时间通常只能有一个前台 VPN；MagicNet 是 root 模块，核心问题变成路由、DNS 劫持和包名排除是否互相抢流量。

默认配置已在 mihomo / sing-box TUN 中排除常见 VPN App 包名，避免其它 VPN App 的握手和控制连接被 MagicNet 再次接管。已包含：

```text
Tailscale / WireGuard / OpenVPN / ZeroTier / Cloudflare WARP / sing-box for Android / NekoBox / v2rayNG / Clash
```

需要 root 路由共存时启用：

```bash
MAGIC_VPN_COEXIST=1
```

开启后模块会在启动内核后自动识别其它 `tun*`、`wg*`、`tailscale*`、`zt*`、`warp*` 类接口，并给这些接口地址补充 `ip rule ... lookup main`，让其它 VPN 的 overlay 地址继续走系统主路由表，不被 MagicNet 的自动路由吞掉。

特殊机型可显式指定外部 VPN 网卡：

```bash
MAGIC_VPN_COEXIST_IFACES="tailscale0 wg0"
```

如果想让 sing-box TUN 反过来走 Android 系统 VPN，sing-box 2026 当前文档要求使用 `route.override_android_vpn`；这属于链式代理模式，和默认的“互相旁路共存”不同，建议单独按设备网络拓扑调整。

### 场景二：MagicNet 开启时，同时开启 VPN 软件

典型例子：手机同时运行 MagicNet 和 Tailscale。

```text
Normal apps
    |
    v
MagicNet TUN
    |
    +--> proxy/direct by MagicNet rules

Tailscale app / control traffic
    |
    | excluded package
    v
Android main route
    |
    v
tailscale0
    |
    v
Tailnet peers
```

默认配置会排除常见 VPN App 包名，避免 VPN App 的握手连接被 MagicNet 再代理一次。启用 `MAGIC_VPN_COEXIST=1` 后，MagicNet 会扫描外部 VPN 网卡，例如 `tailscale0`、`wg0`、`tun0`、`warp0`，并为这些网卡地址补 `ip rule ... lookup main`，让 overlay 网络继续按 VPN 软件自己的路由走。

如果你的目标是“MagicNet 的代理出口再走另一个 VPN”，那是链式代理，不是默认共存。此时需要单独设计路由，例如 sing-box 的 `route.override_android_vpn` 或内核级策略路由。

## 工作流

仓库提供两个 GitHub Actions：

- `Validate MagicNet`：校验 `kam.toml`、Shell 脚本、mihomo YAML、sing-box JSON。
- `Build MagicNet`：初始化子模块、下载构建依赖、执行 `kam build`，并上传 `dist/*.zip` artifact。

工作流不会自动提交、不会自动更新子模块指针，也不会把构建产物写回 Git 历史。需要更新子模块时，请在对应子项目提交后，在父项目显式提交新的 submodule 指针。

手动发布时，在 `Build MagicNet` 工作流里勾选 `release`。如果仓库配置了以下 secret，工作流会生成并强制上传签名文件：

```text
KAM_PRIVATE_KEY
```

未配置 `KAM_PRIVATE_KEY` 时，工作流会发布未签名的 `MagicNet.zip`，并在日志里显示 warning。

## 子项目

- [MagicMihomo](https://github.com/LIghtJUNction/MagicMihomo)：mihomo 通用配置。
- [MagicSingBox](https://github.com/LIghtJUNction/MagicSingBox)：sing-box 通用配置。
- [kamfw](https://github.com/MemDeco-WG/kamfw)：运行时辅助库。

## 相关项目

- [yumebox](https://github.com/YumeLira/YumeBox)
- [Mimic-Node](https://github.com/LIghtJUNction/Mimic-Node)
- [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules)
- [Barabama/FreeNodes](https://github.com/Barabama/FreeNodes)
- [DustinWin/ruleset_geodata](https://github.com/DustinWin/ruleset_geodata)

## 许可证

MIT，见 [LICENSE](LICENSE)。
