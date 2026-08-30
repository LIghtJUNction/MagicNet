# 构建与发布包说明

MagicNet 发布包维护显式 sing-box `tun|ebpf` 主线，默认仍为 `tun`/`magicnet0`。普通用户应安装 Releases 中的 ZIP；本页用于开发者生成并验收同结构产物。

## 构建

克隆时需要初始化项目的直接子模块；`sing-box` 自带的 Android、Apple 和桌面客户端子模块不参与 MagicNet 构建，无需递归拉取：

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init
kam build
```

构建机需要 Go 1.26.7 或更新版本。产物为 `dist/MagicNet.zip`。运行时可执行文件必须位于模块根 `bin/`，并保留 `cli -> bin/magicnet-cli` 兼容入口。默认发布构建必须包含 `bin/sing-box` 和默认 `.config/sing-box/config.json`。

fork 的默认发布标签必须包含 `with_ebpf`，同时保留 TUN 能力。`scripts/build-sing-box.sh` 会验证 fork revision、clean worktree、tag 字符和产物元数据；Android/arm64 产物缺少 `with_ebpf` 时 package smoke 必须失败。

`MAGIC_SINGBOX=0` 只适合跳过 sing-box 源码编译钩子的局部开发场景；缺少核心的 ZIP 不是可发布的 MagicNet 包。

## 发布包验收

```bash
scripts/package-smoke.sh dist/MagicNet.zip
scripts/package-install-smoke.sh dist/MagicNet.zip
```

包检查覆盖运行时布局、模块入口、权限、默认配置、安装迁移、敏感文件排除、`with_ebpf` 构建元数据和旧透明路径清理。它会拒绝 `.local/bin` 旧布局、独立 `magicnet-ebpf`、mihomo/TProxy 等已移除资产，以及 `MAGIC_MIHOMO`、`MAGIC_HOTSPOT_FORWARD`、`MAGIC_VPN_COEXIST` 等旧运行时导出。

当前热点策略由 `cli hotspot {status|enable|disable}` 管理 sing-box `hotspot` selector，不依赖旧环境变量。

完整本机回归可运行：

```bash
scripts/pre-commit.sh
```

这是较重的检查，包含 Rust、shell、配置、WebUI 和包测试。日常聚焦修改运行相关脚本即可，完整入口用于大改或发布前验收。

## WebUI 与依赖锁

WebUI 构建钩子运行前端单元测试、TypeScript 类型检查和生产构建，任一步失败都会中止打包。

sing-box 不再下载上游预编译包。根目录 `sing-box/` 是 `LIghtJUNction/sing-box` 的源码子模块，父仓库 gitlink 固定审核过的提交；根目录 `sing-box.version` 固定该提交对应的语义化基础版本。`scripts/build-sing-box.sh` 使用 fork 内的默认构建标签，分别为 CI 配置校验和模块包编译 Linux amd64、Android arm64 二进制。更新 fork 后必须同步提交新的 gitlink；若基础版本变化，也要更新 `sing-box.version`：

```bash
git -C sing-box fetch origin testing
git -C sing-box checkout origin/testing
git add sing-box
```

外部发布资产由 `hooks/lib/release_locks.sh` 固定 tag、资产名和 SHA-256。升级 yq、jq、ecapture 或 zashboard 时，应审核目标资产并在同一锁文件中同步更新锁定值；构建不得把“最新版本”查询当作信任来源。

## 本机私有配置

仓库根 `.env` 仅用于本机私有变量。不得把 `.env`、订阅 URL、token、secret 或 password 写入补丁、文档、测试夹具、日志或发布包。

本机约定的订阅变量是 `MAGICNET_SINGBOX_SUBSCRIPTION_URL`。需要应用到真机时，只把值写入设备私有路径 `/data/adb/modules/MagicNet/.config/sing-box/subscription.url`，不要在命令输出或交付说明中回显内容。

## 发布前最低证据

- `kam build` 成功并生成 `dist/MagicNet.zip`。
- 两个 package smoke 均通过。
- ZIP 不包含 `.env`、本地状态、临时文件、TProxy/Redirect 或独立 eBPF helper；`bin/sing-box` 元数据包含 `with_ebpf`。
- 在 arm64 真机安装并重启后，`cli health` 与 `cli transparent status` 通过；TUN 额外验证 `ip link show magicnet0`，eBPF 则验证 capability、local cgroup 与 shared TC/interface 状态。
- MCP 若随发布验收启用，必须使用 secret 认证，验收后关闭或轮换 secret。
