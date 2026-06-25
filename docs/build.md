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

## 本地私有配置

仓库根目录的 `.env` 只用于本机私有变量，例如订阅地址或构建机私有参数。不要把 `.env`、订阅 URL、token、secret 或 password 写入文档、测试夹具、提交记录或发布包。

需要把本机订阅应用到真机时，读取 `.env` 中的 `MAGICNET_SINGBOX_SUBSCRIPTION_URL`，再写入设备侧：

```text
/data/adb/modules/MagicNet/.config/sing-box/subscription.url
```

## 注意

`MAGIC_SINGBOX=0` 只应作为开发者临时调试构建钩子的开关使用，不是发布包或运行时禁用 sing-box 的设计。默认构建必须包含 `bin/sing-box` 和默认 `.config/sing-box/config.json`。
