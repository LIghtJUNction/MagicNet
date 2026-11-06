# MagicNet 目录与运行时修复报告

日期：2026-11-06。对应用户提出的目录合并、旧图标删除、TUN stack 弃用、默认接口错误及停止锁超时。

## 结果和固定来源

本轮修复已提交到 [magicnet-android fafd08c3e1b2a7bce10222cdff0e13c7ebba5096](https://github.com/LIghtJUNction/magicnet-android/commit/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096)，主仓库通过 generated/magicnet-android 固定该公开源码。保留了开发期间新增的 Voice 专用规则清理和安装包开发文件裁剪，修复基于源仓 e8aad9e4b97c2601d029dcfa1f2b56ac90abd106 继续。

内核固定为 [sing-box d850ff0ff68e11a71aa8207627e0a826cb52808f](https://github.com/LIghtJUNction/sing-box/commit/d850ff0ff68e11a71aa8207627e0a826cb52808f)。模板原生栈修改先在 [MagicSingBox b1fa62b](https://github.com/LIghtJUNction/MagicSingBox/commit/b1fa62b6912861292c895db58a88b8c5bdff3451) 提交，最终消费其后继 [dacc776](https://github.com/LIghtJUNction/MagicSingBox/commit/dacc776dad4bd2519d5dd0dfbf3839713f9e438c)，以保留同期规则清理。最终 config.json SHA-256：08996a10e24adc6ffb6a75f96d436a543264734d95f50f9952a7a265bb58213e。

Android 产品版本仍为 v1.8.5 / 10613；本轮完成源码修复与主机验证，没有创建新的正式安装包或执行手机部署。配方版本为 0.3.9，保留八包闭包。

## 1. 目录合并与图标删除

| 原路径 | 现行路径与处理 |
| --- | --- |
| .local/state/ | 合并到 .state/；构建元数据、规则摘要及运行证据共享状态根 |
| .tmp/ | 合并到 .cache/；Rust、Shell、WebUI、框架 TMPDIR 与测试入口同步 |
| 下载归档 | 放在 .cache/assets/；发行组件不包含私密缓存或历史下载包 |
| webroot/magicnet-network-card.svg | 源文件删除；安装和复用 WebUI 构建也删除旧副本 |

安装器先保留旧数据，再恢复到新模块并合并。运行入口使用既有配置锁重试未完成迁移。目标已有相同内容时去重；内容不同则保留当前目标，把旧内容保存到私密的 .state/directory-migration/。只有移动或去重成功的旧条目才删除，失败可重试，符号链接输入和目标会拒绝。

.state 与 .cache 根权限为 0700。WebUI 载荷的 0600、descriptor/openat 校验和链接限制保留。MCP 通用读取拒绝新旧私密缓存、旧状态路径和迁移恢复目录，包括别名；配置 watcher 不把缓存或恢复材料当作配置来源。Voice 历史状态清理同时覆盖旧 .local/state/chatgpt-voice 和迁移后的 .state/chatgpt-voice，保留相邻自定义目录。

实现依据：[目录迁移](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/src/MagicNet/lib/magicnet/runtime_dirs.sh)、[安装器](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/src/MagicNet/customize.sh)、[状态合同](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/docs/state-plane.md)。

## 2. 停止超时：修正锁的实际进程归属

确定复现的问题是：后台 shell 的 $$ 仍可能表示最初的父 shell。旧代码把它写入 config.lock/pid，实际 worker 退出后，父 shell 仍活着，下一次停止请求便把残留 marker 当成活锁，反复等待。

现在在进入等待及 metadata guard 子进程之前，通过 shell 内建 read 读取 /proc/self/stat，记录实际执行临界区的 PID，并继续核对启动时间。只有获取成功才缓存准确的 owner token；释放前核对当前实际 PID。因此，读取启动时间的短暂失败不会泄漏自己已获得的锁，子进程继承的 token 也不能解开父进程的锁。获取失败保留原 token，旧 PID-only 与 PID/starttime 格式继续兼容。

该故障模式已在 Bash、sh、mksh、BusyBox 中确定性复现并修复：只终止持锁 worker、保留父进程后，新实现能回收锁。现有日志未包含设备上的原 owner marker，因此不能断言每次历史超时都来自同一执行链。

停止仍先清理自有网络规则，再结束 sing-box。活 owner、暂停 owner、未知身份不会被强行清除；真实清理失败仍保留核心，以保护现有连接。升级前已错误指向活父进程的旧 marker，要等原进程退出后才能安全判为过期；安装修复版本后重启设备可结束这些旧进程，不需要手动强删锁。

实现与回归：[common.sh](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/src/MagicNet/lib/magicnet/common.sh)、[ownership 回归](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/scripts/test-config-lock-ownership.sh)。

## 3. fswatch 重复启动

两个入口可能同时观察到 stopped。旧框架虽然串行执行 start，但每个 start 都会替换 watcher，造成两次启动和 PID 更换。

MagicNet 现在使用既有 metadata guard 将 status 重查、start 与 stop 串行化；健康 watcher 的重复启动请求直接复用原 PID。启动 worker 关闭 fd 8，使长驻 watcher 不继承该生命周期锁；其他继承描述符保留。另修复了 flock 能力探测把正常锁竞争误报为实现不兼容的问题，使用独立 conflict status 区分两者。kamfw 子模块没有修改。

回归检查并发只启动一次、重复 start 不换 PID、stop 等待启动发布后终止，以及长驻 watcher 不占用生命周期锁：[fswatch lifecycle](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/scripts/test-fswatch-lifecycle.sh)。

## 4. sing-box 1.15 原生栈

官方迁移要求删除 TUN stack 字段以使用原生 sing-tun 栈；该字段在 1.15 弃用，计划于 1.17 删除：[官方迁移说明](https://sing-box.sagernet.org/migration/#migrate-tun-stack)。

模板、Rust 默认配置、透明模式生成器、旧 TUN 快照恢复、健康检查和 WebUI 状态合同同步更新。机器接口继续 schema=1，增加 native_tun_stack 能力；有效 TUN 未写 stack 时报告 default，无 TUN 时报告 unavailable，显式旧字段仍如实显示，非法值为 unknown。default 表示配置选择，不表示设备联网成功。

实际构建的 Linux sing-box 对无 stack 的最小 TUN 配置执行 check：exit=0，输出为空；同配置加回 stack=mixed 则复现用户的弃用警告。真实核心的 orchestrator mode smoke 也通过，包含多次应用及 IPv4/IPv6 策略组合。

## 5. 默认接口为空时的行为

原核心只要默认接口监控返回 nil，就无条件调用 NetworkPause，即使 Android CLI 已关闭自动接口绑定。这会暂停 URLTest、WireGuard 等网络任务，而 Android 的系统策略路由可能仍能处理普通 socket。

补丁仅在 Android CLI、没有平台适配器、关闭 auto_detect_interface，且没有 default bind、network strategy、network type 或 fallback type 的情况下保留系统路由尝试。需要真实接口的模式仍等待。接口丢失会取消旧异步更新并保留待恢复 reset；真实接口恢复后沿用 wake/reset 流程。

没有虚构接口、写死 wlan0 或吞掉真实拨号错误。DHCP、接口规则及确实需要绑定接口的消费者仍看到真实的缺失状态。设备日志本身不足以区分 OEM 路由表识别问题与当时确实无网。本轮修复的是可选监控失败导致错误暂停的明确代码路径。

代码和完整证据：[helper](https://github.com/LIghtJUNction/sing-box/blob/d850ff0ff68e11a71aa8207627e0a826cb52808f/route/network_missing_interface_lx.go)、[核心检查报告](https://github.com/LIghtJUNction/sing-box/blob/d850ff0ff68e11a71aa8207627e0a826cb52808f/SPECS/TASKS/087-ANDROID_OPTIONAL_INTERFACE_MONITOR/IMPLEMENTATION_REPORT.md)。

## 6. 实际验证

下表记录本轮实际执行。重复执行未累计为新的独立测试。远端变更整合后，重新运行模板 pin/迁移、配置编辑器、真实核心模式切换及重叠的打包检查。

| 范围 | 结果 |
| --- | --- |
| 配置锁 ownership、fswatch lifecycle | Bash、sh、mksh、BusyBox 均通过 |
| 锁预算、PID 验证、停止保护、watchdog | 对应定向 shell 回归通过 |
| subscription signal safety | 12 项通过 |
| start/stop rollback | 3 种 shell 各 15 项通过 |
| Rust service_launch | 9 项通过 |
| 目录与私密路径相关 Rust | 91 次筛选测试通过，去重 89 项：config_editor 24、webui_payload 12、subscriptions 32、MCP files 7、module_transaction 9、nodes 7；webui_payload 筛选包含 config_editor 的 2 项载荷测试 |
| 原生栈机器状态、健康与能力 | 3 个新增或变更的独立 Rust 回归通过；默认配置测试已计入上述 24 项 |
| WebUI | 17 项机器状态/私密载荷测试、类型检查、生产构建通过 |
| Android 夹具 | workflow 26、fixes 37、TUN proof 26、device simulation 69，共 158 项通过；均为主机夹具 |
| 组件、归档、规则 | 整合后分别 17、12、20 项通过，artifact cleanup 通过 |
| 目录迁移与模块入口 | 冲突、失败重试、符号链接拒绝、fswatch 不回写旧目录、真实配置锁互斥、boot dispatch 通过 |
| 安装模板夹具 | 启用 BusyBox 后 21 个方法通过；真实完整模板检查的 1 个方法受缺少 SRS 文件阻断，6 个子项报同一缺文件错误 |
| sing-box 核心 | route 14 项和 race 定向 15 项通过，两组去重为 24 个顶层测试；新增策略矩阵含 8 个子案例；vet 通过 |
| 核心构建 | Android arm64 的 route 包及 Linux amd64 完整 CLI，均以全部 23 个生产 tags 编译通过 |
| 原生 TUN check | 去 stack 无警告；旧 stack 对照复现警告；整合后的 orchestrator mode smoke 通过 |
| 配方材料 | check、pack、归档 check、完整中文提示词检查通过；8 包、56 个 Markdown 文件 |
| 文本与格式 | source sanity、shell 语法、git diff --check 通过 |

完整安装模板检查所缺的是 geosite-category-ads-all.srs 等发布规则载荷；当前源码模板目录只有 SOURCE.md。这项没有通过，不能把最小 TUN 配置或模式 smoke 当作完整发行验收。未运行全量 host suite 或完整 Android 安装包构建；本环境未安装 shellcheck。

未连接用户手机。因此无网开机、联网恢复、Wi-Fi/蜂窝切换、真实停止及热点流量仍需设备验收。IPv6 NAT 不支持、ipset 不存在的能力提示与本次锁归属问题分开保留，本轮没有尝试更改内核能力。

