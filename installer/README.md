# MagicNet Installer

在已启动系统的 Magisk、KernelSU 或 APatch 管理器中刷入 `magicnet_installer.zip`。安装后的模块是 **MagicNet**（`id=MagicNet`），不再安装独立的 `magicnet_installer` 下载器模块。当前发布包支持 Android arm64。

`magicnet_installer.zip` 与同次发布的 `MagicNet-core.zip`、`MagicNet.zip` 内容完全一致：包含安装脚本、配置模板、组件清单和组件下载助手。管理器从一开始就使用 MagicNet 的模块目录，直接完成本体安装，不嵌套调用管理器，也不再额外下载核心 ZIP。

组件清单固定在当前发布版本，并逐个校验 SHA-256。优先复用当前安装目录或上一版 MagicNet 中内容相同的组件，其次使用校验通过的本地组件缓存；只有缺失或变化的组件才会下载。升级只改脚本时不需要重新下载 sing-box、WebUI 等未变化的组件。首次安装且没有缓存时，仍需下载全部必需组件。

需要下载时优先测试 GitHub 直连；直连慢或实际下载失败时，测速并尝试 GitHub 代理。安装日志显示路径测速、组件复用、缓存命中和下载进度。安装器不再需要调用 GitHub latest API 来寻找另一个安装包，也不会跨版本拼装组件。

完全离线安装使用 `MagicNet-full.zip`。

构建（先使用 KAM 构建完整的 `dist/MagicNet.zip`）：

```sh
GO111MODULE=off CGO_ENABLED=0 GOOS=android GOARCH=arm64 \
  go build -trimpath -ldflags='-s -w -buildid=' \
  -o /tmp/magicnet-components ./installer/components
python3 scripts/package-components.py dist/MagicNet.zip \
  --helper /tmp/magicnet-components --output dist
python3 scripts/test-downloader-installer.py dist/magicnet_installer.zip
```

打包后统一签名全部最终附件。发布检查会拒绝错误模块 ID、递归安装器、重复携带组件或与核心包不一致的安装器。

以前刷入的 `magicnet_installer` 残留是另一个模块，可在管理器中单独卸载；不要卸载 MagicNet 本体。新安装器不会再创建该残留。自动测试覆盖包身份、安装目录及重启后的目录提升模拟、组件复用与失败路径；不等同于真机刷写验证。
