# UI 验收

1. 在 14 页分别打开 light/dark、zh-CN/en/ru 与六种尺寸；可见文字、层级、窄屏无横向主布局溢出，节点/编辑器内部滚动除外；节点与代理组有独立入口，不漏掉工具/输出/流量路径。
2. 无 native bridge 明确预览，连接断开/状态错 JSON/请求失败后旧绿色 live 状态清为 unknown；不得显示虚构成功。
3. Ctrl/Command+K、/、Esc、键盘导航、modal trap、取消、嵌套工具进入 palette/onboarding 后恢复原可见焦点；编辑器里 / 不抢输入。
4. 配置读取失败不能保存；修改后切页/语言/主题不丢草稿；reload/import/template-sync 有取消；保存期间新输入不被旧结果覆盖；草稿不进浏览器持久存储。
5. 双提交、native 超时但未退出、晚回调、输出洪泛/空事件/两流溢出时，旧操作仍持有槽且不会覆盖新状态；真实结束后 callbacks 与缓冲清理。
6. URL/SSID/BSSID/private inspector canary 只在对应编辑器出现，不进 reactive stdout、通用诊断、错误对话框或 issue 正文。
7. module-update accepted 后关闭重进，从设备状态恢复；stage 成功只显示 reboot_required。相同请求幂等，失败保留 retry/恢复提示，不自动重启。
8. Tailscale 暂停/恢复/登出、network-access 共享包审阅/确认、热点 direct/proxy、tun/ebpf 失败回滚，各自结果与退出码/机器快照一致。
9. 小屏键盘避让、44px 触控、标题/标签/屏幕阅读器/reduced motion、焦点/颜色对比与长俄语文案实际检查。
10. 按根 PERFORMANCE 的相同模式测生产 bundle 和页面实际可见时间，并记录 native/non-native、缓存、样本和错误，不拿开发服务器或设备断连预览作为真机操作延迟。
11. 首次使用者可从中文可见名称进入路由工作区，为已安装应用与域名增加/修改规则，选择或创建具名策略组/出口；预览清楚列出变更范围，取消不写入，非法字段可就地纠正；英文原始 tag 仍可搜索和复制。
12. 热点 reconcile/拓扑变更期间发起热点、启停或其他生命周期操作；只读页保持可用，冲突操作显示阶段、等待时间与可重试 busy；WebUI 超时、切页或重开后不能丢失设备侧 owner，也不能把旧 ready 状态显示为新成功。
13. 以 constructor、__proto__、toString、hasOwnProperty 命名组/节点，刷新、分组测速并确认切换；各组结果隔离，不崩溃，翻译后的选项仍发送原始 tag，取消不改变选择。
14. 执行 SUBSCRIPTION_FLOW.md 的 UI-SUB-001–UI-SUB-012 和 UI-SUB-CASE-01–UI-SUB-CASE-10：使用 1、2、5 个来源贯通输入、私密载荷、设备配置、各源导入与同次成功回读；第六个来源整体拒绝，不能截断。检查来源只证明语法有效，不能提前显示导入成功。
15. 两个已配置来源只有一个提供用量时，来源数仍为 2，另一个显示用量未知；重排来源、同主机不同 query、部分无效 metadata 均不串用量、不漏来源。URL/query/hash、载荷内容和 inspector 原文不得出现在共享输出或 Issue 草稿。
16. 提交 B 后继续输入 C，再收到 B 的完成回读；保留 C 和未保存标记。投递接受、真实进程退出、同次设备结果分别验证；旧 success、失败回读、超时、切页与重开均不能导致假成功或第二个写任务。

本次仅有原实现生产预览/基线记录；这些重建 UI 验收均未执行。
