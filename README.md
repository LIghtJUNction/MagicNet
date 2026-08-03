<p align="center">
  <img src="./icon.png" alt="MagicNet Logo" width="180" />
</p>

<h1 align="center">MagicNet</h1>

<p align="center">
  Android root 设备上的 sing-box TUN 网络工作台
</p>

MagicNet 是 Android root 网络模块：用 `sing-box` 的 `magicnet0` TUN 接管、分流和代理设备流量。

需要 Magisk、KernelSU、APatch 等 root 管理器。它不使用 Android 应用的 `VpnService.establish()`，不会独占系统 VPN slot。

## 推广

- [作者的中转站](https://api.lmm.best): 测试迭代中，源代码已开源，购买token表示支持
> 感谢各位“股东”的投资
> 联系我，领取10刀余额

- [AI 自动推广系统](https://bizbot.zvo.cn/)：探索 AI 驱动的自动推广工具与工作流。


## 开始前

请先在系统设置里搜索“私人 DNS”“私密 DNS”或“Private DNS”，并关闭它。

不要设为“自动”。私人 DNS 可能绕过 MagicNet 的 DNS 处理，使 DNS 泄露检测仍显示外部解析器。

MagicNet 不提供节点、订阅或外部出口。请只使用你有权使用、且符合当地法律和服务条款的资源。

## 快速开始

在已 root 的设备终端中执行：

```bash
su
kam install LIghtJUNction/MagicNet
```

安装完成后，写入合法的 `sing-box` 订阅地址：

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
```

查看状态：

```bash
su -c /data/adb/modules/MagicNet/cli health
```

`health` 应显示 `sing-box`、`magicnet0` TUN 和配置的状态。遇到问题时先保存输出，再查看下方的诊断命令。

## 能做什么

- 通过 `magicnet0` TUN 接管设备应用流量。
- 用 `sing-box` 导入 URL 或本地文件订阅、选择节点和执行路由规则。
- 拦截物理出口上的直连 DNS/DoT（53/853），减少 DNS 绕过。
- 为已经进入 TUN 的热点转发流量选择 Direct 或 Proxy 出口。
- 按应用设置代理、直连或 Bypass TUN，便于与外部 VPN 共存。
- 提供 WebUI、CLI、MCP 和支持包，便于日常控制与排查。

当前主线只维护 `sing-box` 和 `magicnet0` TUN，不恢复 TProxy 或多核心路径。热点 Proxy 模式会暂时关闭 Android tether 硬件卸载，确保转发流量进入 TUN；关闭 Proxy 或卸载模块时恢复原系统值。应用的 `bypass` 策略会按 Android 用户动态解析包 UID 并把指定应用排除在 TUN 之外，MagicNet 仍不会占用或管理 Android 的系统 VPN slot。

## 安装

### 1. 用 kam 安装

```bash
kam install LIghtJUNction/MagicNet
```

这是最短的安装路径。

### 2. 安装发布包

从 [Releases](https://github.com/LIghtJUNction/MagicNet/releases) 下载模块包后执行：

```bash
kam -S MagicNet
kam install MagicNet.zip
```

### 3. 从源码安装

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init --recursive
chmod +x kam.sh
./kam.sh
```

这会安装当前 Git 构建版本。只想生成模块包时，改用 `kam build`；产物在 `dist/MagicNet.zip`。

## 常用命令

以下命令都在 root shell 中执行：

```bash
# 写入或替换订阅
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'

# 检查核心、TUN、配置和订阅状态
su -c /data/adb/modules/MagicNet/cli health

# 查看透明代理是否运行在 magicnet0 TUN
su -c /data/adb/modules/MagicNet/cli transparent status

# 查看 UDP / IPv6 策略（默认双栈、IPv4 优先、MTU 1400、UDP 5m）
su -c /data/adb/modules/MagicNet/cli network status

# 网络或节点不支持 IPv6 时切换兼容模式
su -c '/data/adb/modules/MagicNet/cli network set ipv4_only 1400 5m'

# 查看热点流量当前走 Direct 还是 Proxy
su -c /data/adb/modules/MagicNet/cli hotspot status

# 允许热点流量使用 Proxy；disable 可恢复 Direct
su -c /data/adb/modules/MagicNet/cli hotspot enable

# 让指定应用走代理、直连或绕过 MagicNet TUN
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'

# 重启 sing-box
su -c /data/adb/modules/MagicNet/cli service restart sing-box

# 导出脱敏诊断包
su -c /data/adb/modules/MagicNet/cli support bundle
```

模块 WebUI 的“保存并启用”和“导入本地文件”走同一套验证、原子激活和失败回滚流程。本地文件支持 Clash YAML、base64、分享链接及转换器可识别的文本格式；导入成功后会持久使用本地源，直到保存新的 URL 来源。

## DNS 与使用边界

MagicNet 会拦截物理出口的直连 53/853 流量，并将泄露检测域名交给远端 DoH。关闭 Private DNS 才能让这条路径完整生效。

需要确认时，可先找到实际出口接口，再抓包检查：

```bash
adb shell 'su -M -c "ip route get 1.1.1.1; ip -br link"'
adb shell 'su -M -c "timeout 10 tcpdump -ni rmnet_data0 \"port 53 or port 853\""'
```

不同设备的蜂窝接口不一定叫 `rmnet_data0`，请以第一条命令的输出为准。

MagicNet 不创建热点、不接管厂商 tethering/NAT，也不接管外部 VPN overlay。启用热点 Proxy 时，它只暂时关闭 Android tether 硬件卸载，让厂商转发流量进入 `magicnet0`；`cli hotspot disable` 和模块卸载都会恢复此前系统值。之后可用 `cli hotspot {status|enable|disable}` 在 Direct 和 Proxy 之间切换。

## 反馈问题

WebUI 的“反馈问题 / 创建 Issue”会先选择问题类型，再收集对应的脱敏上下文：

- App 无法联网：近期连接的进程、规则、代理链和 sing-box 日志尾部；目标地址、连接 ID 与私有节点名会被过滤。
- 命令或操作报错：上一条命令的安全分类、执行阶段、后台状态和错误输出。
- 订阅或节点异常：订阅状态、选择器摘要和相关日志。
- DNS、TUN 或分流异常：健康检查、DNS、网络与透明代理状态。

生成的正文会复制到剪贴板，并以同一份内容打开 GitHub。提交前仍建议快速检查一次正文。

## 文档

- [构建与发布包说明](docs/build.md)
- [本机仿真、AVD 和真机验收](docs/local-simulation.md)
- [MCP 自动化说明](docs/mcp.md)
- [下一代架构](docs/next-gen-architecture.md)
- [MagicBox](MagicBox)：Android 控制壳
- [kamfw](https://github.com/MemDeco-WG/kamfw)：运行时辅助库

## 社区

- Discord：[加入官方群聊](https://discord.gg/asRwgK9FpA)
- 问题反馈请附上 `cli health` 和 `cli support bundle` 的结果，并删除其中不应公开的信息。

## 许可证

MIT，见 [LICENSE](LICENSE)。
