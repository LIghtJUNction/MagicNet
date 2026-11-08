# 目录与运行时修复 · 2026-11-06

源码固定 [fafd08c3e1b2a7bce10222cdff0e13c7ebba5096](https://github.com/LIghtJUNction/magicnet-android/commit/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096)，核心固定 [d850ff0f](https://github.com/LIghtJUNction/sing-box/commit/d850ff0ff68e11a71aa8207627e0a826cb52808f)。模板 [dacc776](https://github.com/LIghtJUNction/MagicSingBox/commit/dacc776dad4bd2519d5dd0dfbf3839713f9e438c)保留同期 Voice 清理，配置 SHA-256 `08996a10e24adc6ffb6a75f96d436a543264734d95f50f9952a7a265bb58213e`。当次软件 v1.8.5/10613、配方0.3.9；完成源码与宿主验证，未发布新包或部署手机。

## 修复结果

| 范围 | 行为与实现来源 |
| --- | --- |
| 目录 | `.local/state→.state`、`.tmp→.cache`；下载进 `.cache/assets`。冲突保留目标，旧数据进入私密恢复目录；只删除成功迁移/去重的条目，失败可重试，拒绝符号链接。两根目录0700，载荷0600与descriptor/openat限制保留。[runtime_dirs.sh](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/src/MagicNet/lib/magicnet/runtime_dirs.sh)。 |
| 私密边界与图标 | MCP拒绝新旧缓存、状态恢复目录及别名；watcher排除缓存和恢复材料。升级/复用构建移除旧 network-card 图标；Voice 清理保留相邻自定义目录。[安装器](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/src/MagicNet/customize.sh)、[状态合同](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/docs/state-plane.md)。 |
| 配置锁 | shell内建read读取`/proc/self/stat`，记录实际临界区PID/启动时间；worker退出后可回收，活/暂停/未知owner仍受保护。子进程不能凭继承token解父锁；失败保留原token及旧格式兼容。[common.sh](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/src/MagicNet/lib/magicnet/common.sh)、[ownership回归](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/scripts/test-config-lock-ownership.sh)。 |
| fswatch | status重查/start/stop串行，健康重复start复用PID；worker关闭锁fd8，flock探测区分正常竞争。[生命周期回归](https://github.com/LIghtJUNction/magicnet-android/blob/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096/scripts/test-fswatch-lifecycle.sh)。后续真实框架双层锁修复见[联网报告](connectivity-diagnostics-2026-11-06.md)。 |
| 原生TUN | 按[官方迁移](https://sing-box.sagernet.org/migration/#migrate-tun-stack)删除弃用stack；模板、生成器、快照恢复、健康和WebUI一致。schema=1新增native_tun_stack；缺省/无TUN/非法值分别为default/unavailable/unknown，保留显式旧值。 |
| 可选接口监控 | 仅Android CLI、无平台适配器、关闭auto_detect_interface且无default bind/network策略时，接口监控为空仍允许系统路由；依赖接口的配置继续等待。失网取消旧异步更新，恢复后reset，不伪造网卡或屏蔽拨号失败。[核心报告](https://github.com/LIghtJUNction/sing-box/blob/d850ff0ff68e11a71aa8207627e0a826cb52808f/SPECS/TASKS/087-ANDROID_OPTIONAL_INTERFACE_MONITOR/IMPLEMENTATION_REPORT.md)。 |

停止始终先清理自有网络规则再结束核心；真实清理失败保留核心。升级前错误指向活父进程的旧锁须等原进程退出，重启设备可结束这些旧进程，不手动强删锁。设备原owner记录缺失，历史每次超时的具体原因未确认。

## 实际检查

| 范围 | 结果 |
| --- | --- |
| 锁与监督 | Bash/sh/mksh/BusyBox ownership、fswatch及锁预算/PID/停止保护/watchdog通过；signal safety12项；rollback三种shell各15项 |
| Rust | service_launch9项；目录/私密路径去重89项；原生栈状态/能力3项通过 |
| WebUI | 17项、类型检查、生产构建通过 |
| Android宿主夹具 | workflow26、fixes37、TUN proof26、device69，共158项通过 |
| 打包与目录 | 组件17、归档12、规则20及cleanup通过；冲突迁移/失败重试/链接拒绝/入口通过 |
| 安装模板 | BusyBox下21方法通过；完整模板1方法的6子项因缺SRS失败 |
| 核心 | route/race两组去重24顶层测试、策略矩阵8子案例及vet通过；全部23生产tags的Android route包与Linux完整CLI构建通过 |
| 真实配置 | 去stack的TUN check无警告；旧字段对照复现警告；orchestrator mode smoke通过 |
| 配方 | check/pack/archive/build通过，8包/56 Markdown；源码sanity、shell语法与diff空白检查通过 |

缺失 `geosite-category-ads-all.srs` 等发行载荷，完整安装模板验收未通过。未运行全量host suite、完整Android包构建或ShellCheck；未连接手机。无网开机、恢复、Wi-Fi/蜂窝切换、真实停止和热点流量仍需真机验收；IPv6 NAT/ipset能力提示保持。

[固定完整记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/docs/runtime-repairs-2026-11-06.md)保留全部检查明细、先行模板提交与来源链接。
