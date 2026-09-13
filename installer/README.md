# MagicNet Installer

刷入发布附件 `magicnet_installer.zip`，自动下载并安装 MagicNet 最新稳定版本。当前支持 Android arm64，在已启动系统的 Magisk、KernelSU、APatch 管理器内安装。

优先直连 GitHub；直连慢时并发测速候选 GitHub 代理，并按实测速率依次尝试。下载内容必须通过 GitHub 提供的 SHA-256、ZIP CRC 和模块 ID 校验后才交给当前管理器安装。GitHub API 必须能够通过可信 HTTPS 直连访问；测速失败的路径仍会尝试完整下载。

源码暂存 `tmpl/downloader_template/`，以后可迁移至 Kam。`kam-zip-validation.patch` 是配套 Kam ZIP 校验修复，构建使用固定 Kam 提交并应用补丁。

发布工作流先构建并发布 `downloader-template-v1.0.0`，再下载、导入模板，使用 Kam 初始化和构建安装器，验证后发布 `magicnet-installer-v1.0.0`。两个发布均不标记 Latest，确保 MagicNet 本体仍是下载器读取的最新版本。

手动构建：安装 Go 1.24+ 和 Kam，执行：

```sh
kam build tmpl/downloader_template
kam tmpl import templates/downloader_template.tar.gz --force
kam init /tmp/magicnet_installer -t templates/downloader_template.tar.gz --id magicnet_installer --project-name 'MagicNet Installer' --author LIghtJUNction --version 1.0.0
kam build /tmp/magicnet_installer
python3 scripts/test-downloader-installer.py /tmp/magicnet_installer/dist/magicnet_installer.zip
```

安装器只在刷入时运行，没有开机服务，安装后可删除下载器模块。已测试下载校验及管理器调用模拟；真机刷写仍需验证。
