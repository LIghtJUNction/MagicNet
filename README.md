# MagicNet

MagicNet 是 Android root 网络模块：用 `sing-box` 的 `magicnet0` TUN 接管、分流和代理设备流量。

需要 Magisk、KernelSU、APatch 等 root 管理器。它不使用 Android 应用的 `VpnService.establish()`，不会独占系统 VPN slot。

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
- 用 `sing-box` 导入订阅、选择节点和执行路由规则。
- 拦截物理出口上的直连 DNS/DoT（53/853），减少 DNS 绕过。
- 提供 WebUI、CLI、MCP 和支持包，便于日常控制与排查。

当前主线只维护 `sing-box` 和 TUN。不会维护 TProxy、多核心切换、热点代理或 VPN 共存模式。

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

# 重启 sing-box
su -c /data/adb/modules/MagicNet/cli service restart sing-box

# 导出脱敏诊断包
su -c /data/adb/modules/MagicNet/cli support bundle
```

模块 WebUI 的“保存并启用”也会走同一套订阅配置流程。导入后，在 sing-box WebUI 中选择节点和查看连接。

## DNS 与使用边界

MagicNet 会拦截物理出口的直连 53/853 流量，并将泄露检测域名交给远端 DoH。关闭 Private DNS 才能让这条路径完整生效。

需要确认时，可先找到实际出口接口，再抓包检查：

```bash
adb shell 'su -M -c "ip route get 1.1.1.1; ip -br link"'
adb shell 'su -M -c "timeout 10 tcpdump -ni rmnet_data0 \"port 53 or port 853\""'
```

不同设备的蜂窝接口不一定叫 `rmnet_data0`，请以第一条命令的输出为准。

MagicNet 只管理自身的数据面，不接管热点转发、外部 VPN overlay 或厂商 tethering 规则。

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
