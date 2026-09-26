# 验证证据与边界

本地实际工具链：Rust/Cargo **1.98.1**、Node **22.16.0**、Python **3.13**、系统 Chromium。CI 固定 Rust 1.98.1、Node 24。

当前宿主机基线：kamfw 12 项、业务引擎/订阅 22 项、CLI 进程协议 8 项、前端协议 8 项、界面集成 11 项通过。界面测试覆盖四页、320/375/768/1440 像素及真实 host CLI 的导入/替换/删除/错误/草稿行为。构建、格式化和 Clippy 以实际命令为准，不把上面的数字当作永久常量。

事务故障注入在 Store 修改前后 48 个位置中断并恢复。它不模拟全部真实文件系统的扇区损坏、内核断电排序、fork/exec 竞争或 Android 网络回收。native readiness 只有存活观察，诊断明确保留 `network_health: unknown`。

首次本地浏览器导航被环境策略拦截（ERR_BLOCKED_BY_ADMINISTRATOR），没有更改浏览器策略。随后改为离线加载已有 bundle，通过 Node 绑定连接本机 CLI；没有访问外部网络，也没有将其描述为 WebView/CSP 验收。

旧生产基线在 PR 辅助提交 `c3eb5d76ef9f7222cface7647be6f25672838d49` 的 Android KernelSU Acceptance 运行 `36226900776` 失败。日志中一个明确的 CI 问题是模块目录中的 Node 探针不能解析 `@playwright/test`；同时还有行为探针未通过。不能把所有失败归咎于依赖问题，更不能把此候选版的宿主机通过解释成旧版 Android 问题已修复。

完整切换必须使用同一提交对应的 Android 安装、升级、重启、停服/卸载恢复和真实设备证据。`cutover.json` 中阻塞项当前全部保持未接受。
