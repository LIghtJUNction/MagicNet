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

默认控制端：

```text
http://127.0.0.1:9090
```

默认本地面板路径：

```text
http://127.0.0.1:9090/ui/
```

sing-box 使用 `experimental.clash_api` 提供 Clash API 兼容控制端，方便复用 MetaCubeXD / Yacd 等 Clash 面板。若修改 `secret`，面板里也要同步填写。

安装时不会强制覆盖用户已有配置；需要更新时按安装提示确认。

如需在双内核包里强制跳过 sing-box、直接使用 mihomo fallback，创建以下文件：

```text
/data/adb/modules/MagicNet/.disable_sing_box
```

该文件存在时，开机启动、`action.sh` 和安装阶段 WebUI 选择都会跳过 sing-box。

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

## 工作流

仓库提供两个 GitHub Actions：

- `Validate MagicNet`：校验 `kam.toml`、Shell 脚本、mihomo YAML、sing-box JSON。
- `Build MagicNet`：初始化子模块、下载构建依赖、执行 `kam build`，并上传 `dist/*.zip` artifact。

工作流不会自动提交、不会自动更新子模块指针，也不会把构建产物写回 Git 历史。需要更新子模块时，请在对应子项目提交后，在父项目显式提交新的 submodule 指针。

手动发布时，在 `Build MagicNet` 工作流里勾选 `release`。签名需要仓库 secret：

```text
KAM_PRIVATE_KEY
```

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

GPL-3.0，见 [LICENSE](LICENSE)。
