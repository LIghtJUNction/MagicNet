# UI 验收

1. 在 13 页分别打开 light/dark、zh-CN/en/ru 与六种尺寸；可见文字、层级、窄屏无横向主布局溢出，节点/编辑器内部滚动除外；不漏掉工具/输出/流量路径。
2. 无 native bridge 明确预览，连接断开/状态错 JSON/请求失败后旧绿色 live 状态清为 unknown；不得显示虚构成功。
3. Ctrl/Command+K、/、Esc、键盘导航、modal trap、取消、嵌套工具进入 palette/onboarding 后恢复原可见焦点；编辑器里 / 不抢输入。
4. 配置读取失败不能保存；修改后切页/语言/主题不丢草稿；reload/import/template-sync 有取消；保存期间新输入不被旧结果覆盖；草稿不进浏览器持久存储。
5. 双提交、native 超时但未退出、晚回调、输出洪泛/空事件/两流溢出时，旧操作仍持有槽且不会覆盖新状态；真实结束后 callbacks 与缓冲清理。
6. URL/SSID/BSSID/private inspector canary 只在对应编辑器出现，不进 reactive stdout、通用诊断、错误对话框或 issue 正文。
7. module-update accepted 后关闭重进，从设备状态恢复；stage 成功只显示 reboot_required。相同请求幂等，失败保留 retry/恢复提示，不自动重启。
8. Tailscale 暂停/恢复/登出、network-access 共享包审阅/确认、热点 direct/proxy、tun/ebpf 失败回滚，各自结果与退出码/机器快照一致。
9. 小屏键盘避让、44px 触控、标题/标签/屏幕阅读器/reduced motion、焦点/颜色对比与长俄语文案实际检查。
10. 按根 PERFORMANCE 的相同模式测生产 bundle 和页面实际可见时间，并记录 native/non-native、缓存、样本和错误，不拿开发服务器或设备断连预览作为真机操作延迟。

本次仅有原实现生产预览/基线记录；这些重建 UI 验收均未执行。
