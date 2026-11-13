# MagicNet #436：TUN 自动恢复验收修复

> 2026-11-13 · a413候选工作记录 · 完整验收进行中

## 当前结论

生产版 v1.8.7 / 10615 已包含实时 TUN 路由检查和有界自动恢复。本轮补齐了 Android 逐应用路由规则的归属比较，并改用实际管理模拟器 eth0 的移动数据服务完成断开与重建。当前候选在源码和配方两条路径的路由恢复场景均通过。

后继 a413 候选在668的路由验收修复上新增宿主诊断。隔离分支的27项宿主测试、6项原重启合同、29项工作流合同、72项原独立门禁已通过，独立复核完成；a413完整Android及配方整合仍待结果。历史668配方完整验收通过13阶段、5次重启、发布质量和资产验证，源码却在后续升级重启失败，两个结果分别保留。当前尚未合并、发布或部署设备；诊断增量不代表未知启动失败根因已修复。

当前源码为 a4135d5edc39af4895968359bf16e8aefefdaeac，tree f477642021d129ae9b5a64d87436f678db06d62f，parent为668701523f52959f2daf5113ee11b716aa7ecddb。配方PR #451将gitlink和两条可复用工作流固定至同一a413；完整验收完成后补入实际受测配方提交。

## 为什么核心仍在，应用却会断网

应用进入 TUN 需要两步：策略规则决定查哪张路由表，路由表再决定把数据送到哪个接口。进程、TUN 接口和路由表存在，都不能单独证明第一步仍在工作。#436 的原始现场是策略规则组消失，应用流量绕过 TUN，而走本机 mixed 代理入口的检查仍然正常。

现有生产实现按配置观测实际 RPDB/FIB，health 与机器 readiness 共用这一观测。既有 watchdog 每 60 秒独立检查，保留 90 秒启动宽限；同一核心连续两次确认规则缺失后，才调用标准核心重启入口。恢复共享 300 秒冷却，每次开机最多三次；未知证据、停止或事务状态不会直接触发恢复。这些能力已经随 v1.8.7 发布。

## 本轮修改

一、补齐逐应用规则比较。网络重建可能改变 netId，相关规则中的编号也随之更新。采集器与独立门禁分别从已核验的 netd 元数据推导完整 selectors，核对权限、UID 区间、接口、FIB、规则字段及重复次数。只有网络身份与其余元数据保持一致时，才允许编号对应变化；缺规则、额外规则、外来 UID 或权限变化仍会失败。

每个逐应用 UID 区间对应优先级 15000+prio 与 22000+prio，mark 分别为 0x10000|netId 和 netId，mask 为 0x1ffff，并核对 iif lo 与 lookup eth0。重复或重叠区间保留原有次数。全局规则继续按不变的 NONE、NETWORK 或 SYSTEM 权限派生，未知权限不接受。

二、使用正确的上联管理服务。固定 Google API35/r9 镜像没有 Ethernet Binder 服务；独立诊断确认 eth0 属于 CELLULAR/WWAN。新测试通过 cmd phone data disable/enable 控制实际连接，而不是只改变接口标志。

关闭前绑定同一 phone、默认数据订阅、当前 WWAN/eth0 连接和 netd 网络。关闭命令与观测共用 15 秒预算，要求两种数据启用状态均关闭、连接状态为 0、当前连接为空、接口实际 DOWN、旧网络销毁。原逐应用 UID 元数据只允许精确迁入 UNREACHABLE52，恢复后必须完整返回；其他网络保持。

恢复继续保留独立 30 秒 enable guard 和原 600 秒预算，并要求真实默认路由、TUN present、readiness 与同应用 UID TCP 成功。单 eth0 夹具先保存并关闭 Wi-Fi，取得两次一致基线，finally 恢复并回读原 Wi-Fi 启用状态。RPDB/上联失败时先采集有界脱敏支持包，再清理配置。

## a413宿主诊断增量

观察器只启动一次原有参数的模拟器，直接把输出写入原日志，然后等待真实child退出。启动、退出、清理前快照和显式清理请求分别记录；参数仅留摘要，进程环境、完整命令行和原始宿主日志不上传。ADB观察直接查询已有服务器的设备列表，不启动服务器或操作客体。

SIGTERM清理先以pidfd固定目标，再要求完整启动记录、原observer仍存活且starttime一致、child的原始和当前父PID都匹配observer。身份缺失、进程复用、孤儿或父进程不符时拒绝信号。真实进程回归验证了正确清理与无关进程保持存活；缺失cgroup状态时仍保留进程和退出记录，缺失计数保持unknown。

冻结诊断提交96101fa7473ce641c60cb8e18ca5cb4775ad4dcf的短CI[43417860968](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43417860968)通过27/6/29/72项测试。a413仅接入其中五个已审查blob，不包含临时验证workflow；Device.reboot/wait_boot、300秒观察预算、route producer、独立gate和cellular fixture与668逐字节一致。新完整Android验收尚在进行。

## 668候选验收（历史结果）

以下结果来自同一固定候选，构建结果、路由组件结果与完整 Android 结果分别记录。

| 验证项 | 运行 | 结果 | 说明 |
|---|---|---|---|
| 源码 Android | [43407220745](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43407220745) | 失败 | 9通过/1失败/3未运行；升级重启超时，路由阶段通过 |
| 源码构建 | [43407220787](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43407220787) | 成功 | 来源与摘要通过；独立构建标识v1.8.5/10613 |
| 源码质量 | [43407220754](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43407220754) | 成功 | 7个job，包括最终质量门禁 |
| 源码网络 | [43407220299](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43407220299) | 成功 | 3个job |
| 配方检查 | [43407835916](https://github.com/LIghtJUNction/MagicNet/actions/runs/43407835916) | 成功 | 8包、62份Markdown及完整构建提示词 |
| 配方完整整合 | [43407837059](https://github.com/LIghtJUNction/MagicNet/actions/runs/43407837059) | 成功 | Android13/13、5次重启；发布质量和资产核验通过，未发布 |

## 668 原始路由证据

两份原件的应用 UID 都为 10209，UDP 接收计数均为 1→0→1。源码请求耗时为 6 / 5001 / 5 ms，配方为 5 / 5001 / 6 ms；故障后 readiness=false，恢复后 true，生产恢复尝试 0→1。源码故障时核心 PID/starttime、TUN 和 50 条 FIB 保持，生产恢复后核心身份更新。

两份 cellular 记录均为 phone0/subscription1，netId100→无→103，用户/有效数据 true→false→true，连接状态 2→0→2。源码 UID10136、配方 UID10134 的 prio40 元数据仅临时迁入52并返回；flags4098→4099，最终默认路由、readiness和应用TCP均通过，TCP耗时5ms。Wi-Fi初始true，准备时关闭，finally恢复true。

本轮 RPDB before/fault/after 的 netId 始终为100；100→103发生在后续 cellular 上联实验。因此本轮不能被写成 RPDB 比较器重编号分支的动态覆盖。该分支另有原始失败回放、逐项回归及历史9dba整合的实际重编号证据。

## 源码升级重启失败

源码实际检出 GitHub 合成测试提交 053a11d134f3177fa94e917828245a2dfce81a36，已核对其 tree 与668完全一致。路由阶段325.799秒且通过，之后 upgrade-preservation 在341.252秒后报 Android boot deadline exceeded。完整结果为9通过、1失败、3未运行；完整668门禁返回exit1，单独路由组件校验通过。

第一次重启完成，第二次命令返回124；未成功观察到 sys.boot_completed=1 且boot ID不同于旧值。这个结果不证明boot ID始终没变。重启命令只发送一次，命令预算30秒，随后仍有完整300秒启动观察预算。

串口日志显示第一次重启在48.063秒被init接收，54.560秒machine restart并进入下一次启动。第二次请求在467.618秒被接收，日志在468.215秒停止，没有第三个kernel banner、明确panic/Oops或guest OOM；后续ADB读取只有设备不存在。现有产物没有宿主模拟器的退出状态，不能区分进程退出、宿主终止、KVM停滞或guest关闭过程卡住。

a413已加入被动父进程记录实际child PID/starttime、真实退出码与信号，在Stop emulator之前采集有界的进程、cgroup资源和ADB状态。诊断不重启客体、不重发reboot、不延长等待、不放宽成功门禁；SIGKILL本身也不等于OOM。

## 保留的历史结果

原始5edd运行[43253655173](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43253655173)：实际UDP1→0→1、一次生产恢复，但因未识别netId100→101对应的逐应用规则而报recovery_rule_set_mismatch。原ZIP和两个报告成员已重新读取，摘要与GitHub工件一致。

58cc：源码[43385059168](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43385059168)因真实wlan0→eth0默认/UID归属迁移被严格拒绝；配方[43385469784](https://github.com/LIghtJUNction/MagicNet/actions/runs/43385469784)在注入前UDP基线超时，原因仍未确定。两份完整Android结果均为5通过、1失败、7未运行。后续单上联成功不能证明该双上联UDP异常已解决。

9dba：配方[43391099744](https://github.com/LIghtJUNction/MagicNet/actions/runs/43391099744)完整通过13/13和5次重启，实际覆盖netId100→102且逐应用元数据保持；同tree源码[43390671015](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43390671015)在RPDB/UDP恢复后，eth0的IPv4默认路由600秒内未恢复，仍为5/1/7。接口UP不能单独证明Android已重建IP配置。

5f96：源码[43399092150](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43399092150)与配方[43399411108](https://github.com/LIghtJUNction/MagicNet/actions/runs/43399411108)都在Ethernet基线报incomplete_ethernet_dump，尚未执行down，完整结果5/1/7。后续诊断[43403995584](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43403995584)确认固定镜像没有ethernet服务，推翻了此前将EthernetFactory当作eth0管理者的假设。

独立蜂窝诊断[43404505529](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43404505529)使用同一用户空间镜像及stock kernel、未安装MagicNet；它确认netId101→无→102、接口UP→DOWN→UP，以及逐应用元数据经52迁移并返回。它只验证控制与观测机制，不能替代完整KernelSU验收。

## 验证范围与执行中断

668提交前：采集器91项、独立门禁72项、模拟器合同114项、验收合同33项、工作流合同27项通过；源码lint检查838个受跟踪文本文件，配方check/pack/归档检查/build prompt通过8包62份Markdown。当前源码Sourcery因150,000字符差分限制跳过；配方Sourcery成功；独立交叉复核未发现当时阻断。

原始问题使用APatch/ARM64和本地重打包的官方sing-box1.14.3；当前CI使用固定随包核心及Android15/KernelSU/x86_64。受控删规则验证了检测和恢复路径，不能确定原物理设备上由哪个组件删除规则。Wi-Fi开关恢复不等于真实Wi-Fi切换恢复；本轮未执行M37独立软件重建，也没有新的真实订阅或公网代理结果。

工作环境在后续诊断实现期间断开。已推送提交与远端CI保持；宿主观察器的后续实现、真实进程测试及合同测试改在GitHub runner完成，结果和执行位置单独记录。环境中断后生成的构建ZIP未作本地独立字节复算；CI远端资产验证的结果不称作本地复验。公开稳定版保持v1.8.7/10615。

## 工件摘要与来源

668源码Android artifact14029607559：198132 bytes，SHA256 6cf959af6d17f61bfbc8c83ea18caa626f184f1c755047dd9365e9b62b5ea759。simulation.json：a597fb1abefbe1d14aace5c487ae828c21b28a45e1f08ee0f42422fab5b58215；route-recovery.json：c081ec7fbddc7fd2799540eeae9e24960f1d29ed5311fe965eb038782ffaff81。

668配方Android artifact14029563278：523771 bytes，SHA256 7eaf37fbe80284a909348399c4bc619cb7109909b6407243ac9ce0bf580f7749。simulation.json：8245b3d3cac1ff046e5ef779033cd55c7b6e077263793359b07af0da5fdd5dc6；route-recovery.json：1d1300a8df86859fafbfc8adf543f8a84262e54d2357fd3c8f4643937fb70288。

668配方构建 artifact14031630631：142419552 bytes，GitHub SHA256 2aa89ecb49c7b63bfadf99e4c11817da5f11549b51154ffb4b4b87bcd8478706。CI资产验证作业下载得到同一摘要，完整清单与嵌入元数据检查通过：source_sha为668701523f52959f2daf5113ee11b716aa7ecddb，recipe_sha为53087b92330bf6b6ac7885d0951217e90ca7d786（tree与023配方相同），预览标识v1.8.8/10616。该工件在环境中断后生成，仅记录CI远端核验，未声称本地独立重算。

原始5edd artifact13962475632：200286 bytes，SHA256 80d8702ce418d107108bc64cd3cb7baf66a2774ac2c13359280a85b8f9a12a69。已发布v1.8.7 Android artifact13838939681：525278 bytes，SHA256 a557eb9279a49125ef97450024cde3c108cbe0139e811e2d124054089e251be5。上述下载字节均已与GitHub digest核对。

[Issue #436](https://github.com/LIghtJUNction/MagicNet/issues/436) · [源码 PR #7](https://github.com/LIghtJUNction/magicnet-android/pull/7) · [配方 PR #451](https://github.com/LIghtJUNction/MagicNet/pull/451) · [已发布 v1.8.7 验收](https://github.com/LIghtJUNction/MagicNet/actions/runs/42982936016)

## 可复核索引

固定提交、tree、合成测试提交、工件 SHA-256、历史失败与验证方式见 [JSON 证据索引](evidence/issue-436-ci-2026-11-13.json)。索引不是原始ZIP镜像；原始工件遵循GitHub Actions各自的保留期。

Google云盘副本：[修复与验收报告](https://docs.google.com/document/d/1hIKrBtM8nyhB9knCV32SoLvLTFZbyEhgyeRl0D0VKto)。本文件是工作记录；当前a413完整验收未结束，后续结果将另行补齐并保留前述失败。
