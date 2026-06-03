# MagicNet

MagicNet 是一个 Android root 网络安全分析模块，用于在真实设备上接管、审计和调试系统网络流量。它面向网络连通性验证、DNS 泄露检查、透明流量治理、热点共享审计、分应用流量策略和自动化诊断。

> 需要 Magisk / KernelSU / APatch 等 root 管理器。当前版本：`v1.1.0`。Release 以发布页为准。

## 界面预览

![MagicNet mobile management panel](docs/assets/screenshots/magicnet-mobile-audit.png)

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

构建产物位于：

```text
dist/MagicNet.zip
```

## 首次配置

安装后写入你的合法自有测试配置：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/config"'
```

`cli setup` 会校验 URL、写入运行配置、更新设备侧配置、重载模块，并输出健康诊断结果。模块 WebUI 首页的“保存并启用”使用同一条 CLI 路径。

这些路径是兼容性实现细节；普通用户优先使用 WebUI 或 CLI，不需要手工编辑。

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
su -c /data/adb/modules/MagicNet/cli transparent set tun
su -c /data/adb/modules/MagicNet/cli transparent set tproxy
su -c /data/adb/modules/MagicNet/cli hotspot set proxy
su -c /data/adb/modules/MagicNet/cli hotspot set direct
su -c /data/adb/modules/MagicNet/cli config apply
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli diagnose
```

配置、连接和诊断：

```bash
su -c /data/adb/modules/MagicNet/cli sub update-all
su -c /data/adb/modules/MagicNet/cli sub list
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/config"'
su -c /data/adb/modules/MagicNet/cli api stats
su -c /data/adb/modules/MagicNet/cli api close-all
su -c /data/adb/modules/MagicNet/cli support bundle
```

自定义域名分流：

```bash
su -c /data/adb/modules/MagicNet/cli route list
su -c '/data/adb/modules/MagicNet/cli route add-domain proxy example.com'
su -c '/data/adb/modules/MagicNet/cli route add-domain direct example.cn'
su -c '/data/adb/modules/MagicNet/cli route add-domain block ads.example.com'
su -c /data/adb/modules/MagicNet/cli route apply
```

## MCP 自动化

MagicNet 可在设备上启动 MCP server，供本机 agent 通过 ADB 转发调用：

```bash
adb forward tcp:8765 tcp:8765
su -c /data/adb/modules/MagicNet/cli mcp enable
```

MCP 工具可管理配置源、黑名单、备份、状态检查和脱敏上下文。默认关闭，需要用户显式启用。

## 网络安全分析工作流

1. 写入合法自有测试配置。
2. 启动模块并确认 `service status`。
3. 使用 `health` / `diagnose` 收集进程、接口、路由、监听端口、控制端和日志。
4. 使用 `tcpdump` 或模块抓包规则验证 DNS/DoT 是否外泄。
5. 分别测试本地站点直连、外部站点连通、AI 服务访问和热点客户端路径。
6. 导出 `support bundle`，获得脱敏后的复现材料。

## DNS 泄露验证

常用真机抓包方式：

```bash
adb shell 'su -M -c "timeout 10 tcpdump -ni rmnet_data0 \"port 53 or port 853\""'
```

不同设备的蜂窝出口可能是 `rmnet_data0`、`rmnet_data3` 或其它接口。先用以下命令确认出口：

```bash
adb shell 'su -M -c "ip route get 1.1.1.1; ip -br link"'
```

目标状态是访问测试期间没有明文 DNS/DoT 流量从物理出口泄露。

## 热点与 VPN 共存

热点代理模式会识别热点网卡和 `magicnet0`，只补充必要的转发和 NAT 规则，不清空 Android 系统链。

VPN 共存模式会扫描 `tun*`、`wg*`、`tailscale*`、`zt*`、`warp*` 等外部隧道接口，并补充策略路由，让 overlay 网络继续按原 VPN 软件的路由走。

## 设计取舍

MagicNet 借鉴成熟 Android root 网络模块的“核心启动器、透明规则分层、配置合法性检查、手动控制、日志可追踪”思路，但把对外定位收敛为网络安全分析与设备侧流量审计。TProxy、IPSET_LKM、VPN 共存和 MCP 都是显式启用或可选增强，不会在默认路径里隐式接管用户网络。

## 工作流

仓库提供两个 GitHub Actions：

- `Validate MagicNet`：校验 `kam.toml`、Shell 脚本和底层运行配置。
- `Build MagicNet`：初始化子模块、下载构建依赖、执行 `kam build`，并上传 `dist/*.zip` artifact。

工作流不会自动提交、不会自动更新子模块指针，也不会把构建产物写回 Git 历史。需要更新子模块时，请在对应子项目提交后，在父项目显式提交新的 submodule 指针。

## 子项目

- 底层运行配置子项目 A。
- 底层运行配置子项目 B。
- [kamfw](https://github.com/MemDeco-WG/kamfw)：运行时辅助库。

## 参考与致谢

- [yumebox](https://github.com/YumeLira/YumeBox)
- [Mimic-Node](https://github.com/LIghtJUNction/Mimic-Node)
- [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules)
- [DustinWin/ruleset_geodata](https://github.com/DustinWin/ruleset_geodata)
- [CHIZI-0618/AndroidTProxyShell](https://github.com/CHIZI-0618/AndroidTProxyShell)
- [CHIZI-0618/box4magisk](https://github.com/CHIZI-0618/box4magisk)
- [taamarin/box_for_magisk](https://github.com/taamarin/box_for_magisk)
- [Fanju6/NetProxy-Magisk](https://github.com/Fanju6/NetProxy-Magisk)
- [Fanju6/Proxylink](https://github.com/Fanju6/Proxylink)
- [TanakaLun/IPSET_LKM](https://github.com/TanakaLun/IPSET_LKM)

## 许可证

MIT，见 [LICENSE](LICENSE)。
