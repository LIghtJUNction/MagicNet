# 构建细节

MagicNet 当前发布包只维护 `sing-box` + `magicnet0` TUN 主线。构建产物必须把运行时可执行文件放在模块根目录的 `bin/` 下，并保留 `cli -> bin/magicnet-cli` 兼容入口。

```bash
kam build
scripts/package-smoke.sh dist/MagicNet.zip
scripts/package-install-smoke.sh dist/MagicNet.zip
```

`scripts/package-smoke.sh` 会拒绝旧版运行时布局和旧功能开关，包括：

- `.local/bin` 中的运行时二进制。
- `.local/subscriptions.env` 中的本地订阅缓存。
- `.config/kamfw/.envrc` 中的 `MAGIC_MIHOMO`、`MAGIC_HOTSPOT_FORWARD`、`MAGIC_VPN_COEXIST` 等旧运行时导出。
- mihomo、TProxy、抓包代理和旧透明路径相关文件。

这里拒绝的是旧版 `.envrc` 运行时导出。当前热点策略由 `cli hotspot {status|enable|disable}` 管理 sing-box 的 `hotspot` selector，不依赖 `MAGIC_HOTSPOT_FORWARD`。

## 本地私有配置

仓库根目录的 `.env` 只用于本机私有变量，例如订阅地址或构建机私有参数。不要把 `.env`、订阅 URL、token、secret 或 password 写入文档、测试夹具、提交记录或发布包。

需要把本机订阅应用到真机时，读取 `.env` 中的 `MAGICNET_SINGBOX_SUBSCRIPTION_URL`，再写入设备侧：

```text
/data/adb/modules/MagicNet/.config/sing-box/subscription.url
```

## 注意

`MAGIC_SINGBOX=0` 只应作为开发者临时调试构建钩子的开关使用，不是发布包或运行时禁用 sing-box 的设计。默认构建必须包含 `bin/sing-box` 和默认 `.config/sing-box/config.json`。

WebUI 构建钩子会运行 `npm run check` 或 `bun run check`，依次执行前端单元测试、TypeScript 类型检查和生产构建。任何一项失败都会中止模块打包。

## 发布依赖锁

构建钩子只接受 `hooks/lib/release_locks.sh` 中已审核的固定 tag、资产名和 SHA-256。升级 yq、jq、sing-box、ecapture 或 zashboard 时，先独立审核发布资产，再在同一锁文件中同时更新这三项；不要把远端 release digest 或“最新版本”查询作为信任来源。
