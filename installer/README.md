# MagicNet Installer

刷入 `magicnet_installer.zip`，安装的是 **MagicNet**，不是一个需要二次安装的下载器模块。包内 `module.prop` 从一开始就是 `id=MagicNet`；管理器直接安装到 `MagicNet`，不再嵌套调用 `install_module`。

这个 ZIP 与同一发布中的 `MagicNet-core.zip`、`MagicNet.zip` 字节一致，只需下载其中一个。它包含小型核心、组件清单和组件下载器，不包含 sing-box、CLI、WebUI 等大型组件的重复副本，也不再下载第二个核心 ZIP。清单锁定这个安装包对应的发布版本，不会混用另一版的组件。

安装时依次校验并复用当前安装目录、旧 MagicNet 目录、离线包内文件和本地组件缓存；仅下载缺失或内容变化的组件。校验依据是文件内容的 SHA-256，不是仅比较版本号。直连良好时跳过代理测速；否则比较候选代理并尝试下载，保留测速和进度输出。组件全部验证通过后才写入，校验失败不会继续显示安装完成。

旧 `magicnet_installer` 模块仅在 MagicNet 的组件安装、配置迁移和安装向导均成功后标记为由管理器卸载。只处理模块 ID 精确匹配且不是符号链接的旧目录；不会删除旧 MagicNet 或订阅配置。

## 构建

在项目根目录完成正常 KAM 构建后，再拆分组件；不要再用独立的 `kam installer --id magicnet_installer` 模板：

```sh
kam build
GO111MODULE=off CGO_ENABLED=0 GOOS=android GOARCH=arm64 \
  go build -trimpath -ldflags='-s -w -buildid=' \
  -o /tmp/magicnet-components ./installer/components
python3 scripts/package-components.py dist/MagicNet.zip \
  --helper /tmp/magicnet-components --output dist \
  --repository LIghtJUNction/MagicNet
python3 scripts/test-downloader-installer.py dist/magicnet_installer.zip \
  --core dist/MagicNet-core.zip
```

发布时先完成上述变换及检查，再签名最终附件。`MagicNet-full.zip` 仍是完整离线安装包。Android arm64 的 Magisk、KernelSU、APatch 管理器沿用同一 MagicNet 安装入口。

`python3 scripts/test-installer-identity.py` 使用真实组件程序和生成的安装脚本，在主机上模拟管理器选择模块 ID、安装暂存及重启晋升；覆盖首次安装、升级复用、损坏组件、旧安装器清理与最终发布包检查。这不是 Android 真机刷写验证。

Component downloads cancel a response body after 20 seconds without received bytes and try another route. Continued progress resets this idle deadline; the existing overall request timeout remains. Each failed attempt removes its partial file, and no alternate route bypasses the release-pinned size/SHA-256 checks. ZIP compression is explicitly level 9 even for prebuilt entry metadata.
