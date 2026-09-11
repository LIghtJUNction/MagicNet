# 安装时填写订阅

安装脚本在恢复旧配置、更新配置模板和清理迁移备份之后，检查订阅来源。
没有来源时，调用 kamfw 的 `web_input_collect` 启动临时本地页面，再通过
kamfw 的 `launch browser` 打开当前 Android 用户的默认浏览器；没有设置默认
浏览器时，系统可能显示选择器。管理器安装没有 TTY 也会进入此流程。

已有远程订阅、本地订阅或明确的 standalone 配置时不重复询问，不覆盖升级
保留下来的订阅。空白或仅注释的订阅文件不视为已配置。Recovery、显式
`MAGICNET_NONINTERACTIVE=1` 和 `MAGIC_SINGBOX=0` 跳过网页；打开浏览器失败时
安装日志给出完整本机地址。缺少 BusyBox 功能或 CGI 自检失败会给出提示并继续
安装，不会自动下载工具，也不会修改 SELinux 或网络规则。

页面支持简体中文、繁体中文、英语、俄语、日语、韩语，自动选择浏览器语言，
并允许手动切换。明暗主题跟随系统，动画尊重“减少动态效果”设置。所有样式、
脚本均随模块打包，无 CDN、遥测、远程字体或统计请求。GitHub Star、Discord、
指南、问题反馈、作者主页和作者的 AI 服务均只在用户点击时打开；不会自动
Star，也不要求注册或购买服务才能配置。

保存将单个 HTTPS 订阅链接原子写入 `.config/sing-box/subscription.url`，权限为
600。支持 `+`、`&`、百分号编码等查询参数原样保留。离线校验拒绝凭据、片段、
控制字符和私网 IP 等输入；下载阶段仍由现有运行时执行 DNS 绑定和重定向检查。
安装器只保存来源，不下载订阅、不启动内核、不改变透明代理规则。保存后返回
安装器，安装完成后重启。未配置时继续沿用现有“不启动无订阅内核”的行为。

可以选择“稍后配置”；默认等待 180 秒，超时不会导致安装失败。通过
`MAGICNET_SETUP_TIMEOUT` 调整等待时间，允许 5–1800 秒。之后使用模块 WebUI 或
现有 `cli setup` 配置。临时服务仅监听 `127.0.0.1`，需要一次性令牌；保存、
跳过、普通退出会关闭监听并删除临时文件。强制杀死安装器时独立看门狗会关闭
监听，但可能残留仅 root 可读的临时目录。

## 开发和验证

通用收集服务作为 kamfw 扩展随模块打包，MagicNet 提供安装适配、HTTPS 校验和页面：

- `src/MagicNet/lib/kamfw-web/`（安装时暂存后写入本模块的 `lib/kamfw`）
- `src/MagicNet/lib/magicnet/install_web.sh`
- `src/MagicNet/lib/magicnet/install_subscription_validate.sh`
- `src/MagicNet/setup/{index.html,setup.css,setup.js}`

```sh
python3 scripts/test-kamfw-web-input.py
python3 scripts/test-install-web.py
node --check src/MagicNet/setup/setup.js
```

测试使用真实 BusyBox httpd/CGI；Android `am` 用可核对参数的替身替代。它们验证
保存、跳过、升级保留、超时、权限、校验和默认浏览器调用参数，不等同于真机
安装或完整发布包验收。页面另有离线 Chromium 布局及模拟 XHR 交互测试。

kamfw 上游仓库的 GitHub 应用写入权限不足，因此扩展暂存于 MagicNet 的
`lib/kamfw-web`，而不是修改或展开 git submodule。首次配置时，安装适配器把
三个扩展文件原子逐个写入新模块的 `lib/kamfw`，然后正常 `import web_input`。
页面启动由框架的 `launch browser` 执行；不需要先合并另一个仓库的 PR，现有
构建脚本刷新 kamfw 上游时也不会丢掉扩展来源。通用 API 与测试可独立移回上游。
