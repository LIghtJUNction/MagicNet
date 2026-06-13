# 本机仿真测试

MagicNet 是 Android root 模块，最终验收必须在 Magisk、KernelSU 或 APatch 真机运行时完成。本机测试的目标是提前发现打包、路径、脚本阶段、MCP、CLI 和配置改写问题，不能替代 SELinux、AVB、vendor HAL、内核、TUN 或真实启动链验证。

## 测试分层

推荐按三层跑：

1. 仓库内仿真：在 Linux 主机上解包模块，模拟 Magisk 安装和启动脚本，验证 `bin/` 路径、`cli`、MCP、配置改写和常见 shell 行为。
2. AVD/rootAVD：在 Android Studio Emulator 中注入 Magisk，安装真实模块 zip，验证 `/data/adb/modules/MagicNet`、`post-fs-data.sh`、`service.sh`、overlay 和 logcat。
3. 真机验收：用目标 root 管理器安装 zip，重启后验证服务、端口、TUN/核心、网络、MCP 和日志。

先跑本机仿真，再跑 AVD/rootAVD，最后跑真机。不要把普通 `adb root`、Superuser 或可写 `/system` 当成 Magisk 模块运行时。

## 统一入口：kam test

仓库提供 `scripts/kam-test.sh`，Kam CLI 提供 `kam test` 作为统一入口：

```bash
kam test quick
kam test package
kam test fake-magisk
kam test local
kam test avd
```

模式说明：

- `quick`：验证 `kam.toml`、Rust CLI/MCP crate、默认 mihomo YAML 和 sing-box JSON。
- `package`：构建缺失的 zip 后运行 `scripts/package-smoke.sh` 和 `scripts/package-install-smoke.sh`。
- `fake-magisk`：在 Linux 主机上解包模块，替换成本机 debug CLI/MCP，mock Android/root 命令并验证脚本、MCP、supervisor、配置改写和诊断路径。
- `local`：顺序运行 `quick + package + fake-magisk`。
- `avd`：只使用 `emulator-*` 设备或显式 `ANDROID_SERIAL`，通过 Magisk CLI 安装 `dist/MagicNet.zip`，重启后验证模块落点、旧路径清理、CLI/MCP/status 和日志采集。
- `rootavd-setup`：对默认 API 33 x86_64 AVD ramdisk 执行 rootAVD 注入。

AVD 测试默认优先使用专用 SDK：

```bash
MAGICNET_ANDROID_SDK_ROOT="$HOME/.android-sdk-magicnet"
MAGICNET_AVD_NAME="MagicNet_API_33"
MAGICNET_ROOTAVD_DIR="$HOME/.cache/magicnet-tools/rootAVD"
```

如果这些变量未设置，脚本会先找 `~/.android-sdk-magicnet`，再回退到宿主 `ANDROID_SDK_ROOT`。这样可以避免系统全局 SDK 和 rootAVD 专用 AVD 混用导致 `Broken AVD system path`。

`kam test avd` 是非交互安装：脚本会通过 `MAGICNET_NONINTERACTIVE=1 magisk --install-module` 安装模块，避免卡在音量键语言选择界面。安装前会清理模拟器里的旧 `MagicNet` 模块目录，确保每次测试都是干净安装。

注意 ABI 边界：当前发布包里的 `bin/magicnet-cli`、`bin/magicnet-mcp-server`、`bin/sing-box`、`bin/mihomo` 是 Android arm64。API 33 x86_64 AVD 可以验证真实 Magisk 安装、脚本阶段、目录结构和控制面；脚本会临时构建并推送 x86_64 CLI/MCP，并下载带 sha256 digest 的 x86_64 sing-box/mihomo release 资产做运行时启动检查。x86_64 AVD 能证明控制面和同架构核心在 Magisk 模块目录下可运行，但不能证明发布包内 arm64 核心在真机上一定可运行。完整 arm64 核心验收仍需要 arm64 AVD、Waydroid arm64 镜像或真机。

## 仓库内仿真

构建模块：

```bash
kam build
```

检查包结构和二进制 ABI：

```bash
scripts/package-smoke.sh dist/MagicNet.zip
```

模拟安装器迁移、权限和保留配置：

```bash
scripts/package-install-smoke.sh dist/MagicNet.zip
```

模拟 Magisk/KernelSU 模块目录和启动阶段：

```bash
scripts/fake-magisk-smoke.sh dist/MagicNet.zip
```

完整本地回归：

```bash
scripts/pre-commit.sh
```

`fake-magisk-smoke.sh` 会：

- 解包 zip 到临时模块目录。
- 用本机 debug 版 `magicnet-cli` 和 `magicnet-mcp-server` 替换 Android arm64 二进制。
- mock `ip`、`iptables`、`getprop`、`resetprop`、`mihomo`、`sing-box` 等 Android/root 命令。
- 验证 `cli -> bin/magicnet-cli`、MCP HTTP JSON-RPC、`post-fs-data.sh` 回退启动、supervisor、TUN/TProxy 配置改写、热点和 VPN 共存规则。

保留失败现场：

```bash
MAGICNET_FAKE_KEEP=1 scripts/fake-magisk-smoke.sh dist/MagicNet.zip
```

保留后脚本会输出临时目录，重点看：

```bash
sed -n '1,200p' /tmp/magicnet-fake-magisk.*/module/.log/service.log
sed -n '1,200p' /tmp/magicnet-fake-magisk.*/module/.log/mcp-server.log
sed -n '1,200p' /tmp/magicnet-fake-magisk.*/mock-commands.log
```

仿真脚本不写入真实订阅。需要真实订阅时只在 AVD 或真机命令行输入，不要写进仓库、文档、测试夹具或 CI secret 以外的地方。

## AVD/rootAVD

AVD 是无真机时最接近 Magisk 语义的桌面方案。它能控制 `ramdisk.img`、`system.img`、`userdata-qemu.img` 和 emulator 启动参数；rootAVD 负责把 Magisk 注入 AVD 使用的 ramdisk。

建议基线：

- Android Studio Emulator。
- Platform-Tools。
- API 33 或 API 34 的 x86_64 Google APIs/Play Store AVD。
- rootAVD。

启动 AVD：

```bash
emulator @Pixel_7_API_33 -writable-system -no-snapshot
```

注入 Magisk：

```bash
git clone https://gitlab.com/newbit/rootAVD.git
cd rootAVD
./rootAVD.sh system-images/android-33/google_apis_playstore/x86_64/ramdisk.img
```

安装 MagicNet：

```bash
adb push dist/MagicNet.zip /sdcard/Download/MagicNet.zip
adb shell 'su -c "magisk --install-module /sdcard/Download/MagicNet.zip"'
adb reboot
adb wait-for-device
```

验证模块落点：

```bash
adb shell 'su -c "ls -la /data/adb/modules/MagicNet"'
adb shell 'su -c "cat /data/adb/modules/MagicNet/module.prop"'
adb shell 'su -c "legacy=/data/adb/modules/MagicNet/.local/\"bin\"; test ! -e \"$legacy\" && echo legacy_bin_absent"'
```

配置合法订阅并启动：

```bash
adb shell 'su -c "/data/adb/modules/MagicNet/cli setup \"https://example.com/subscription\" "'
adb shell 'su -c "/data/adb/modules/MagicNet/cli service restart sing-box"'
adb shell 'su -c "/data/adb/modules/MagicNet/cli service status"'
```

启用 MCP：

```bash
adb shell 'su -c "/data/adb/modules/MagicNet/cli mcp enable 127.0.0.1 8766"'
adb forward tcp:8766 tcp:8766
curl -sS -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  http://127.0.0.1:8766/mcp
```

采集日志：

```bash
adb logcat -b all -v threadtime > logs/avd-boot.log
adb shell 'su -c "tail -n 200 /data/adb/modules/MagicNet/.log/service.log"'
adb shell 'su -c "tail -n 200 /data/adb/modules/MagicNet/.log/mcp-server.log"'
adb shell 'su -c "/data/adb/modules/MagicNet/cli diagnose"'
```

AVD/rootAVD 的通过标准是：模块目录存在、`cli` 可运行、脚本阶段执行、MCP 可调用、配置能应用、日志可解释。它不能证明真机上的 vendor、SELinux、AVB、内核 TUN 或 OEM 网络栈一定可用。

## Waydroid 备选

Linux/Wayland 环境可以用 Waydroid 做容器化 Android 测试。它适合 CI 风格的 ADB 自动化，但宿主需要 binder 和 ashmem 或 memfd 支持。Waydroid 可以替换自定义 `system.img` 和 `vendor.img`，也有社区 Magisk 集成脚本。

基本流程：

```bash
waydroid session start
adb connect 127.0.0.1:5555
adb devices
```

完成 Magisk 集成后，安装和验证命令与 AVD 类似。Waydroid 默认 Android 基线和图形/内核依赖与真机差异较大，只作为补充测试台。

## 真机验收清单

真机仍是最终准绳。KernelSU 示例：

```bash
adb push dist/MagicNet.zip /sdcard/Download/MagicNet.zip
adb shell 'su -M -c "MAGICNET_NONINTERACTIVE=1 /data/adb/ksu/bin/ksud module install /sdcard/Download/MagicNet.zip"'
adb reboot
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
```

重启后检查：

```bash
adb shell 'su -M -c "cd /data/adb/modules/MagicNet && ./cli mcp status && ./cli service status"'
adb shell 'su -M -c "ss -lntp 2>/dev/null | grep -E \"8766|7892|9090\" || true"'
adb shell 'su -M -c "ping -c 1 -W 3 www.baidu.com >/dev/null && echo network_ok || echo network_fail"'
```

MCP JSON-RPC：

```bash
adb shell 'su -M -c "printf \"%s\" \"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":1,\\\"method\\\":\\\"tools/list\\\",\\\"params\\\":{}}\" | curl -fsS --max-time 5 -H \"Content-Type: application/json\" --data-binary @- http://127.0.0.1:8766/mcp"'
```

通过标准：

- `cli -> bin/magicnet-cli`。
- 不存在旧运行时 bin 目录。
- `cli mcp status` 显示 `pid=<number>`。
- `cli service status` 至少能解释当前核心、watchdog、fswatch 状态。
- `127.0.0.1:8766`、核心 API 端口按配置监听。
- 基础网络不被模块破坏。

## 敏感信息规则

- 订阅 URL、token、secret、设备序列号和完整日志不要写进仓库。
- 文档和测试夹具只使用 `https://example.com/subscription` 这类占位符。
- 向 issue 或 PR 贴日志前先跑 `cli support bundle`，或手动脱敏 URL、token、secret、password。
