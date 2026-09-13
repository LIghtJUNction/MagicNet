# MagicNet Installer

刷入发布附件 `magicnet_installer.zip`，自动下载并安装 MagicNet 最新稳定版本。当前支持 Android arm64，在已启动系统的 Magisk、KernelSU、APatch 管理器内安装。

优先直连 GitHub；直连慢时并发测速候选 GitHub 代理，并按实测速率依次尝试。下载内容必须通过 GitHub 提供的 SHA-256、ZIP CRC 和模块 ID 校验后才交给当前管理器安装。GitHub API 必须能够通过可信 HTTPS 直连访问；测速失败的路径仍会尝试完整下载。

下载器模板已内置于 Kam 0.6.14，MagicNet 发布工作流会直接导入该模板并构建安装器。

手动构建：安装 Go 1.24+ 和 Kam，执行：

```sh
kam installer /tmp/magicnet_installer --id magicnet_installer \
  --project-name 'MagicNet Installer' --author LIghtJUNction \
  --repository LIghtJUNction/MagicNet --asset MagicNet.zip --module-id MagicNet
kam build /tmp/magicnet_installer
python3 scripts/test-downloader-installer.py /tmp/magicnet_installer/dist/magicnet_installer.zip
```

安装器只在刷入时运行，没有开机服务，安装后可删除下载器模块。已测试下载校验及管理器调用模拟；真机刷写仍需验证。

下载时每秒显示百分比、已下载大小、平均速度和预计剩余时间；测速逐条展示结果及排序。直连达到阈值时会明确提示跳过代理测速。
