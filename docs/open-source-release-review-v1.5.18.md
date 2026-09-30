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
- 中文列表、Android 中文用户名称、Clash YAML、订阅字段的 JSON 转义和长 JSON 对旧 Bionic 正则实现触发退出码 139。配置改用打包 jq，列表、用户前缀、YAML 识别/边界/备用字段及转义改为字节操作。保留 UID 查询失败的严格处理。
- 发布流程没有要求同一最终主线提交的 Android 验收成功；新增精确提交、分支、事件、仓库身份和必要任务检查。
- 验收的 BusyBox 多调用文件名与真实环境不一致；通过 busybox 名称调用原始、哈希固定的二进制。进程测试中的独立配置改为真正有效的样本。

## 已有证据及其边界

本轮通过原始 KernelSU v3.2.0 x86_64 BusyBox（SHA-256 `060844b0769f7a50262854af027c4d6076a212d160a51309b53057cfb7122900`）复现 UTF-8 正则退出码 139，并验证修复后的实际生产解析函数。旧失败证据见 [Android 运行 36726242388](https://github.com/LIghtJUNction/MagicNet/actions/runs/36726242388)。没有替换 BusyBox，也没有修复系统 Bionic 库；不能据此宣称所有 shell 操作支持 UTF-8。

重启验收曾在 adbd 正常退出与重启期间收到 device offline，导致重新启用失败、卸载未执行。修复使用有期限的只读重连与 UID 校验，不重放安装、启停等生命周期操作，也不吞掉失败或超时。

[PR #360](https://github.com/LIghtJUNction/MagicNet/pull/360) 合并后的发布提交为 [fe69660fbf2e2151fb46359b5d7d78f949153cb4](https://github.com/LIghtJUNction/MagicNet/commit/fe69660fbf2e2151fb46359b5d7d78f949153cb4)。以下均对应该提交：

| 检查 | 结果与证据 |
| --- | --- |
| Rust、WebUI/浏览器、Shell、组件及基础设施 | [代码质量 36786647429](https://github.com/LIghtJUNction/MagicNet/actions/runs/36786647429) 通过。 |
| DNS/NAT 与离线网络回归 | [网络回归 36786647394](https://github.com/LIghtJUNction/MagicNet/actions/runs/36786647394) 通过。 |
| 精确核心、页面和 AVD 存储证据 | [证据 36786647410](https://github.com/LIghtJUNction/MagicNet/actions/runs/36786647410) 通过；内存结果仅属于 Linux 空闲实验。 |
| Android 生命周期 | [验收 36786647388](https://github.com/LIghtJUNction/MagicNet/actions/runs/36786647388) 三个必需任务与全部 12 阶段通过：安装、冷启动、应用 UID TUN 控制、回滚、停服清理、重启幂等、升级保留、禁用、启用和卸载。 |
| 正式构建、安装器、完整质量门槛与签名 | [发布 36786647389](https://github.com/LIghtJUNction/MagicNet/actions/runs/36786647389) 通过，已公开 [v1.5.18](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.5.18)。 |

这些自动化结果不覆盖 ARM64/OEM、Play/GMS 登录下载、eBPF 或 IPv6 数据面、公网代理质量、eCapture 执行以及 proxylink 的设备侧订阅解析。未执行的公网代理基准不计入已通过的离线验收。

## 继续保留的真机任务

[OEM 停服规则清理 #336](https://github.com/LIghtJUNction/MagicNet/issues/336)、[#337](https://github.com/LIghtJUNction/MagicNet/issues/337)、[热点 IPv6 #335](https://github.com/LIghtJUNction/MagicNet/issues/335)、[GMS UID 与厂商策略 #329](https://github.com/LIghtJUNction/MagicNet/issues/329) 仍需要对应设备和网络证据。ARM64/OEM、Google Play/GMS、eBPF 与 IPv6 数据面不属于这份 x86_64 AVD 的验证能力；这些任务不能因宿主机或模拟器通过而关闭。
