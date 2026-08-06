# 本机仿真、AVD 和真机验收

MagicNet 是 Android root 模块。本机和 x86_64 AVD 能发现打包、脚本、配置与控制面问题；arm64 真机仍是 TUN、SELinux、vendor 网络栈和真实启动链的最终验收环境。

## 分层入口

```bash
kam test quick
kam test package
kam test fake-magisk
kam test local
kam test avd
```

- `quick`：检查项目配置、Rust CLI/MCP 和默认 sing-box JSON。
- `package`：构建缺失 ZIP，并运行 package 与 install smoke。
- `fake-magisk`：在临时目录模拟模块安装、启动、supervisor、CLI、认证 MCP 和配置改写。
- `local`：组合 quick、package 与 fake-magisk。
- `avd`：只面向 `emulator-*` 或显式 `ANDROID_SERIAL`，安装真实 ZIP 并替换为同架构测试运行时。

完整仓库回归是 `scripts/pre-commit.sh`，会运行较多 Rust、shell、WebUI 和包测试；大改或发布前再执行。

## 聚焦本机检查

```bash
kam build
scripts/package-smoke.sh dist/MagicNet.zip
scripts/package-install-smoke.sh dist/MagicNet.zip
scripts/fake-magisk-smoke.sh dist/MagicNet.zip
```

保留 fake-magisk 失败现场：

```bash
MAGICNET_FAKE_KEEP=1 scripts/fake-magisk-smoke.sh dist/MagicNet.zip
```

脚本会输出临时目录；重点检查模块 `.log/service.log`、`.log/mcp-server.log` 和 mock 命令记录。仿真不应使用真实订阅或设备 secret。

## AVD/rootAVD

推荐 API 33/34 x86_64 Google APIs 或 Play Store AVD，并用 rootAVD 注入 Magisk。x86_64 AVD 可以证明 Magisk 目录、脚本和同架构替代核心可运行，不能证明发布 ZIP 内 arm64 二进制在真机正常。

安装包统一通过可检查的中转目录：

```bash
adb shell 'mkdir -p /sdcard/Download/MagicNet'
adb push dist/MagicNet.zip /sdcard/Download/MagicNet/MagicNet.zip
adb shell 'su -c "MAGICNET_NONINTERACTIVE=1 magisk --install-module /sdcard/Download/MagicNet/MagicNet.zip"'
adb reboot
adb wait-for-device
```

不要使用 `/data/local/tmp`。本项目设备可能不允许该目录写入；任何其他临时补丁、配置或日志中转也使用 `/sdcard/Download/MagicNet/`。

配置测试订阅并验收：

```bash
adb shell 'su -c "/data/adb/modules/MagicNet/cli setup \"https://example.com/subscription\""'
adb shell 'su -c "/data/adb/modules/MagicNet/cli health"'
adb shell 'su -c "/data/adb/modules/MagicNet/cli transparent status"'
adb shell 'su -c "ip link show magicnet0"'
```

AVD 通过标准不是单纯“服务进程存在”，而是 `health` 无阻塞项、透明状态为 TUN、`magicnet0` 存在，且日志能解释架构限制。若 AVD 脚本明确跳过不适用于 x86_64 的真机数据面检查，应记录为限制而不是伪造通过。

## 认证 MCP 验收

```bash
adb shell 'su -c "/data/adb/modules/MagicNet/cli mcp enable 127.0.0.1 8766"'
adb shell 'su -c "/data/adb/modules/MagicNet/cli mcp status"'
adb forward tcp:8766 tcp:8766
MCP_TEST_SECRET="$(adb shell 'su -c "/data/adb/modules/MagicNet/cli mcp secret"' | tr -d '\r\n')"
curl -fsS http://127.0.0.1:8766/mcp \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${MCP_TEST_SECRET}" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
unset MCP_TEST_SECRET
```

禁止用无认证请求作为 MCP 通过证据。服务、转发与客户端启动问题见 [MCP 自动化说明](mcp.md)。

## arm64 真机

KernelSU 示例：

```bash
adb shell 'mkdir -p /sdcard/Download/MagicNet'
adb push dist/MagicNet.zip /sdcard/Download/MagicNet/MagicNet.zip
adb shell 'su -M -c "MAGICNET_NONINTERACTIVE=1 /data/adb/ksu/bin/ksud module install /sdcard/Download/MagicNet/MagicNet.zip"'
adb reboot
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
```

重启后验收：

```bash
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli health"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli transparent status"'
adb shell 'su -M -c "ip link show magicnet0"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli sub status"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli diagnose"'
```

按本次改动增加应用、Wi-Fi、热点、DNS、MCP 或 Tailscale 的专项验收。DNS 泄露抓包应先用 `ip route get 1.1.1.1` 找到真实物理出口，不能固定假设接口名。

## 清理与敏感信息

任务结束后清理本次中转文件，保留目录便于用户检查：

```bash
adb shell 'rm -f /sdcard/Download/MagicNet/MagicNet.zip'
adb forward --remove tcp:8766
```

若还推送了其他文件，只删除本次创建的明确文件名，不递归删除整个目录。订阅 URL、token、MCP secret、设备序列号和未经脱敏的完整日志不得进入仓库、Issue 或 PR；支持材料优先使用 `cli support bundle` 并人工复核。
