# 按功能合同重写与原版对照

本轮用户要求先确认已有功能，再替换实现；私有函数、文件组织和内部调用可以改变，用户可见功能继续兼容。验收对象是行为与资源归属，不能用修改文件数或代码行数替代。实现与实际结果见 VERIFICATION.md；本文件规定可重复的比较方法。

## 固定比较对象

Android 原版固定为 `LIghtJUNction/magicnet-android@aefcbfbab80fe14008e4467eb0292251f7ce8f89`，其框架为 `MemDeco-WG/kamfw@bb0dc7582ee2c27e31e49d2d3b714b97528defef`。该原版已包含开发期间同期到达的联网自愈与诊断导出。两版使用相同依赖、工具链和合成输入；候选必须保留这些同期功能。原版源码只用于本轮用户明确授权的行为提取和对照，不把本次工作称为“不读取旧源码的独立重建”。

## 跨层兼容面

| 层 | 必须保留的外部结果 | 对照方式 |
| --- | --- | --- |
| kamfw | 导入去重、阶段、root 管理器、多语言回退、输出、下载缓存、配置、通知、浏览器、日志轮转、watchdog、fswatch 与进程归属 | 同一命令和夹具的新旧输出、退出码、文件；四种 Shell；真实宿主子进程与并发启停 |
| Shell 运行时 | 启停次序、TERM/KILL 与失败回收、配置锁、DNS/热点/分流、订阅、Tailscale、规范状态发布 | 原版与候选执行同一套主机回归；补充同输入差分、失败注入和重复应用 |
| CLI 与 MCP | 命令和参数、schema-1 结果、错误、认证、私密边界、用户意图、事务及恢复 | 比较退出码、stdout/stderr、全部夹具文件字节和本地 API 写入；成功写入与拒绝路径都覆盖 |
| WebUI | 14 页功能、后台任务、读写队列、异步桥接、草稿、权限与私密输出、语言和焦点行为 | 同输入解析与状态计算差分、单元检查、类型检查、生产构建；浏览器和设备另记 |
| 安装与更新 | 三种管理器入口、离线完整包、已安装组件复用、校验缓存、配置保留、权限、恢复和清理 | 新旧安装器在相同目录运行，比较输出、文件摘要、目录、权限和符号链接；竞态与中断恢复回归 |
| 打包 | 核心包、完整包、组件、别名、校验清单及生产依赖 | 使用同一合成源包，逐个比较最终产物摘要；展开所有 ZIP 验证开发内容未混入 |

## 基线已有的联网维护功能

本节归纳差分必须保留的行为；具体接口由 [CONNECTIVITY_CONTRACT.md](../magicnet-network-runtime/CONNECTIVITY_CONTRACT.md) 和 [DIAGNOSTIC_CONTRACT.md](../magicnet-control-plane/DIAGNOSTIC_CONTRACT.md) 维护，不创建第二套状态或接口事实源。

服务启动后通过受控 mixed 入口请求 `https://www.google.com/generate_204`，TLS 校验和 HTTP 204 均成功才记在线。正常间隔 300 秒；连续失败退避为 60、120、240、480、960、1800 秒并封顶。截止时间使用包含休眠的单调时钟。同次开机重启监控不能清空预算；查询状态、刷新页面和导出报告不触发公网请求。

Google 失败后依次使用独立代理目标和直连出口区分故障。恢复按路由/DNS 修复、订阅刷新、核心重启递进；首次失败先诊断，动作至少相隔 300 秒，自动订阅更新至少相隔 3600 秒。停止意图、生命周期锁、节点选择与 tun/ebpf 模式必须保留。未知进程归属暂停维护，恢复动作成功不等于已联网；新的 HTTPS 检查通过后才能更新在线状态。

`cli --json connectivity status` 及 `service.status.data.connectivity` 读取同一缓存观测，缺失测量使用 null/unknown；`.state/machines/connectivity.state` 由 producer 原子发布，generic reconcile 不得覆盖退避预算。内部 boot token、凭据、来源 URL 和原始设备身份不进入公开结果。

诊断页的一键导出调用 `cli support export` 或 `cli --json support export`，Android 输出 `/sdcard/Download/MagicNet/MagicNet-diagnostics.txt`；宿主夹具输出模块 `.state/diagnostics/`。`support bundle` 提供同样的文本。报告覆盖版本、资源、启动与恢复、配置引用、网络和订阅状态，自动遮蔽凭据、名称、UID、设备与流量目标；保留类型、计数、顺序及报告内稳定别名。

`support.export` 是独立设计的机器文件写入例外，capabilities 同时列为 command 和 mutation command，并声明 `state_effect="export-only"`、`fresh_network_probe=false`；无参数，成功返回 `{path, bytes}`，失败返回 `support.export_failed`。它只原子替换一个报告，不改变网络、配置或服务。外部采集共享 25 秒预算，单流 32 KiB、单节 48 KiB、总计 512 KiB；失败保留旧报告，不得靠丢弃失败信息假装完整采集。

## 测量与报告规则

性能测试必须同时运行原版和候选，写明输入规模、预热、次数、计时区间和内存口径。CLI、Shell、Node、打包器和 Android 核心分别报告。子进程峰值 RSS 不能使用受 Python 父进程继承污染的高水位。小幅波动不宣布提速；内存和时间之间的实际取舍照实记录。

保留基线失败、候选失败、环境阻塞和未执行项。依赖函数名称的旧测试可以改为执行替代路径，但不得删除宏观断言或让失败变成跳过。报告明确哪些职责重写、哪些稳定算法、协议、声明或外部核心继续复用。只有通过实际测试的行为才写一致；宿主通过不推导真实 Android、网络吞吐、WebView 或长期稳定性已通过。

所有源码测试和差分工具留在开发树。安装包递归排除 tests、fixtures、快照、基准、覆盖率和 node_modules 目录，同时保留运行时普通文件 `bin/test` 等合法载荷。修改通过后分批提交源码与框架，主仓库以 mode `160000` 固定最终源码；本轮不自动创建新发行版或部署设备。
