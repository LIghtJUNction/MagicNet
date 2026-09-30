# v1.5.18 开源对照和验收范围

本轮对照了 11 个相关项目的第一方源码或构建说明。下面链接固定到本次读取的提交；这些是设计参照，不是 MagicNet 已通过验收的证据。没有将其他项目源码复制进 MagicNet。

| 项目 / 源码 | 对照内容 | MagicNet 的处理 |
| --- | --- | --- |
| [taamarin/box_for_magisk: box/scripts/box.service](https://github.com/taamarin/box_for_magisk/blob/a87244943abdd1cf0f278c708001b2aef56adb9c/box/scripts/box.service) | 核心 SIGTERM、TUN 配置和网络清理 | 保留宽限期与模块规则归属；不照搬按名字 killall。 |
| [GitMetaio/Surfing: box_bll/scripts/box.service](https://github.com/GitMetaio/Surfing/blob/94114748a1e64049f93ba754927d3fcdbe5db031/box_bll/scripts/box.service) | 系统 iptables、监听就绪和停服顺序 | 以真实就绪检查为准；不杀死占用端口的无关进程。 |
| [CHIZI-0618/box4magisk: box/scripts/box.service](https://github.com/CHIZI-0618/box4magisk/blob/6ff4307060d43dc7be0f1ffc599d9f78c951c18a/box/scripts/box.service) | TUN 路由、OEM 防火墙处理 | 对照兼容性问题；不清空 fw_INPUT、fw_OUTPUT 或厂商链。 |
| [SagerNet/sing-box: cmd/sing-box/cmd_check.go](https://github.com/SagerNet/sing-box/blob/927770c29f3e3698c711fc150e1066a4a78793a2/cmd/sing-box/cmd_check.go) | 真实核心的配置构造检查 | JSON 结构校验之后仍必须执行打包核心 check；检查不能替代启动和数据面。 |
| [SagerNet/sing-box: experimental/clashapi/server.go](https://github.com/SagerNet/sing-box/blob/927770c29f3e3698c711fc150e1066a4a78793a2/experimental/clashapi/server.go) | Clash API 的方法和版本接口 | 本地 HTTP 传输对齐 API；仅放行回环地址，检查状态和完整响应。 |
| [SagerNet/sing-box-for-android: app/src/main/java/io/nekohasekai/sfa/bg/ProxyService.kt](https://github.com/SagerNet/sing-box-for-android/blob/8e42c63c4771de10b20dd2562704850c604518d8/app/src/main/java/io/nekohasekai/sfa/bg/ProxyService.kt) | Android 服务生命周期 | 将启动、停服和服务状态作为独立验证步骤；AVD 与 OEM 结论分开。 |
| [SagerNet/sing-tun: tun_linux.go](https://github.com/SagerNet/sing-tun/blob/837976228ca2d772647a215c46384094311b5aaf/tun_linux.go) | 接口、路由表和系统路由条件 | 继续按接口及数字路由表清理自己的规则，不覆盖 netd/OEM 状态。 |
| [MatsuriDayo/NekoBoxForAndroid: app/src/main/java/io/nekohasekai/sagernet/bg/GuardedProcessPool.kt](https://github.com/MatsuriDayo/NekoBoxForAndroid/blob/5768494d8ae3c74a057bb6d46c0f8dc071b0d821/app/src/main/java/io/nekohasekai/sagernet/bg/GuardedProcessPool.kt) | SIGTERM、等待与强制结束 | 确认有界宽限期与精确进程身份比立即强制杀进程可靠。 |
| [KernelSU-Next/KernelSU-Next: userspace/ksud/src/module.rs](https://github.com/KernelSU-Next/KernelSU-Next/blob/2b31f7185460e99bc3896a639e9073b1c354ee0d/userspace/ksud/src/module.rs) | 模块更新目录及 standalone shell | 升级验收覆盖 modules_update 路径与配置保留；不能用直接复制到活动目录冒充安装。 |
| [tiann/KernelSU: userspace/ksud/src/module.rs](https://github.com/tiann/KernelSU/blob/08a3b087e49227c8a6731c5f1114998b5e25255b/userspace/ksud/src/module.rs) | 模块安装和禁用状态 | 安装、升级、禁用、启用、卸载都由真正管理器执行。 |
| [topjohnwu/Magisk: scripts/util_functions.sh](https://github.com/topjohnwu/Magisk/blob/5b06d817d4ae5a916df88fd9efebf12537f40cdb/scripts/util_functions.sh) | BusyBox standalone 与模块安装环境 | 必须使用真实提供者及其实际 applet 分发方式；不能用宿主机工具冒充设备工具。 |
| [osm0sis/android-busybox-ndk: README.md](https://github.com/osm0sis/android-busybox-ndk/blob/3c96be250994e00fb3feb9b5a5b902e5e0222ca3/README.md) | NDK/Bionic applet 的构建与行为差异 | 编译成功不等于操作正确；针对生产调用验证原始 BusyBox 二进制。 |

## 本轮确认并修复的问题

- 独立配置的热点策略引用不存在的出口，导致最终核心配置无效。
- 默认 DNS 策略覆写独立 DNS 图；空服务器列表在转换时失败；核心 1.14 缺失默认域名解析器。
- 没有 curl 的 Android 环境无法查询和操作本地核心 API；新增内置、有界、仅回环的 HTTP 传输。
- 中文列表、Android 中文用户名称、订阅字段的 JSON 转义和长 JSON 对旧 Bionic 正则实现触发退出码 139。配置改用打包 jq，列表、用户前缀及转义改为字节操作。保留 UID 查询失败的严格处理。
- 发布流程没有要求同一最终主线提交的 Android 验收成功；新增精确提交、分支、事件、仓库身份和必要任务检查。
- 验收的 BusyBox 多调用文件名与真实环境不一致；通过 busybox 名称调用原始、哈希固定的二进制。进程测试中的独立配置改为真正有效的样本。

## 已有证据及其边界

旧 Android 验收 [36726242388](https://github.com/LIghtJUNction/MagicNet/actions/runs/36726242388) 记录了 awk 和系统 sed 的 UTF-8 崩溃。使用 KernelSU v3.2.0 的原始 x86_64 BusyBox（SHA-256 `060844b0769f7a50262854af027c4d6076a212d160a51309b53057cfb7122900`）在宿主机复现；修复后的生产解析路径已通过该二进制的回归。本轮没有修复系统 Bionic 库，也不能据此宣称所有 shell 操作支持 UTF-8。

候选 [6273e3f](https://github.com/LIghtJUNction/MagicNet/commit/6273e3f4abf61743f327fd2b2bc3ce015a55ad5f) 的 Rust、WebUI 单元/类型/构建及移动端浏览器、组件打包、CI 基础设施和网络回归检查通过。该提交的 Android 验收及 Shell 检查失败，不能作为发布依据；修复后的候选必须重新验收。

发布要求最终主线提交通过完整 CI 和 Android 15 / KernelSU v3.2.0 / x86_64 的安装、启动、TUN 正向/拒绝/恢复、无效配置回滚、启停、升级、禁用、启用、卸载检查，并验证签名安装包。

## 继续保留的真机任务

[OEM 停服规则清理 #336](https://github.com/LIghtJUNction/MagicNet/issues/336)、[#337](https://github.com/LIghtJUNction/MagicNet/issues/337)、[热点 IPv6 #335](https://github.com/LIghtJUNction/MagicNet/issues/335)、[GMS UID 与厂商策略 #329](https://github.com/LIghtJUNction/MagicNet/issues/329) 仍需要对应设备和网络证据。ARM64/OEM、Google Play/GMS、eBPF 与 IPv6 数据面不属于这份 x86_64 AVD 的验证能力；这些任务不能因宿主机或模拟器通过而关闭。
