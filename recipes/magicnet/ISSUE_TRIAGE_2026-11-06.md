# MagicNet Issue 与 PR 处理记录（2026-11-06）

#436 的最新修订见文末 2026-11-13 节及 [VERIFICATION.md](VERIFICATION.md)。以下各日期保留当时的源码、发行与验收身份。

## 范围与结论状态

用户授权直接合并并处理 Issue/PR。源码 PR #3 与主仓库 PR #442 已合并到各自 main；最终源码的七条工作流均在 attempt 1 成功。#437、#438、#439 已关闭，#436 与 #440 已记录完成部分并保持开放。以下分别记录本地、实际 Android 模拟器和物理设备的证据边界。

此前 DNS 修复已经合并：[源码 PR #2](https://github.com/LIghtJUNction/magicnet-android/pull/2)、[模板 PR #21](https://github.com/LIghtJUNction/MagicSingBox/pull/21)、[主仓库 PR #441](https://github.com/LIghtJUNction/MagicNet/pull/441)。本轮初始核对时三仓库均无待合并 PR；主仓库有五个开放 Issue。两个此前未解决的 DNS 审查线程已补充依据并标记解决：保留用户显式解析器属于兼容边界；当前固定核心按 transport tag 隔离 DNS 缓存，不能套用旧版独立缓存开关的结论。

## Issue 处置与证据边界

| Issue | 已确认缺口与修改 | 实际处置 |
| --- | --- | --- |
| [#438](https://github.com/LIghtJUNction/MagicNet/issues/438) | 整目录恢复会丢失新版网页探测目标清单；恢复后仅为缺失文件从当前 ZIP 补默认值，保留自定义字节并拒绝不安全路径 | 已关闭，completed |
| [#437](https://github.com/LIghtJUNction/MagicNet/issues/437) | orphan 候选过宽使无关进程的未知身份误阻断；订阅重启区分真正 worker/DNS 失败与独立热点路由清理，后者保留警告和既有重试 | 已关闭，completed；不宣称所有现场 rc=2 同源 |
| [#439](https://github.com/LIghtJUNction/MagicNet/issues/439) | 订阅更新后未恢复完整维护集合；统一恢复 connectivity、refresh、Wi-Fi policy、hotspot 与原活动 fswatch，覆盖 journal、回滚和中断 | 已关闭，completed |
| [#436](https://github.com/LIghtJUNction/MagicNet/issues/436) | health 与机器状态过去只看 TUN 接口，无法发现规则组丢失；增加配置派生的有界实时路由证据 | 保持开放，区分已修复的误报与未查明的真机规则丢失原因 |
| [#440](https://github.com/LIghtJUNction/MagicNet/issues/440) | 升级遗漏订阅更新历史；仅将历史加入同一迁移清单，当前 .state 的更新锁不随历史恢复 | 已记录历史迁移修复；可信 NAS/私网订阅入口未实现，保持开放 |

## 修复机制

升级先恢复用户意图，再从同一受信安装包补入缺失的 `website-targets.tsv`。这覆盖实际 SKIPUNZIP 入口：文件可能从未预解压到目标目录，因此仅在旧目录复制前暂存默认文件仍不足以修复。历史记录保留原阶段、结果和时间，当前运行状态继续从真实证据重建。

订阅重启复用既有维护进程启动链，fswatch 的原开关单独保留。配置锁内完成配置和核心事务，释放配置锁后才恢复维护进程，订阅更新 wrapper 的 update owner 持续到收尾；独立 common 恢复不获取该 owner，继承外层锁/defer 时返回 2 并保留原状态。真实进程归属未知、停止失败与 DNS 清理失败继续阻断；独立热点清理失败保留 owned journal 和警告，并由原有重协调路径重试。

TUN 检查按配置和固定核心的有效规则推导表号、优先级、地址族与 marks。任一必要项已知缺失时为 false；无已知缺失而有未知时为 null，人类 health 显示相应警告，health 与 machine 使用同一实现。仅热点或 fallback 不能替代必需应用规则；需要更大静态范围的策略不能由连接子网残留满足。检查不改规则、不写 canonical、不启新守护、不发公网探针；内核必要资源也不等于真实 App UID 的流量成功。

Android TLS 验收补入实际退出码、固定错误分类、GET 计数、主客体时间和证书有效期，失败也写入现有产物。临时证书 notBefore 固定回溯 300 秒，notAfter 仍为签发后一天；证书信任、主机名拒绝及原有预算保持。产品信任库和系统时钟均不修改。

## 已取得的本地验证

| 变更 | 已观察结果 | 限制 |
| --- | --- | --- |
| 安装与历史迁移 | 旧代码上缺文件/历史及链接负例失败；修复后的实际打包安装器套件 14 项通过，config-refresh 与 3 项 network-access upgrade 通过 | 本地检测到 sh；不是物理管理器安装 |
| 订阅生命周期 | 更新锁、激活顺序、事务、信号、停止、orphan 和真实宿主监督器生命周期通过；信号测试 12 项，sh/bash | 六次重复更新是生产 wrapper 锁序夹具，不是六次 Android 端到端订阅 |
| TLS 验收夹具 | 旧证书在签发前 120 秒验证失败；新证书该负例通过，落后 600 秒和两天后仍拒绝；proof 30 项（1 个既有可选 CA skip）、simulation 102、acceptance 32、workflow 26、simulation-fixes 37 项通过 | 旧失败未保存详细原因，不能由此断言历史失败只有时钟原因 |
| TUN 路由与机器状态 | 独立路由修复树 b620e5e2：CLI 837 通过、1 忽略；diagnostic_export 3、ebpf_observation 4、observation_state 6 通过；仅连接子网和缺段反例不再就绪 | 不覆盖物理网络切换根因或全部应用流量 |
| 主仓库配方/发布边界 | check、pack、归档检查和完整提示词通过：8 包、61 Markdown；发布边界 21 项通过 | 不等同于 Android 安装或正式发行 |

## CI 与来源

原 main `faa7d956324a20889cb921ff35c9f13b66dc0c1a` 的 [Android run 42192735920](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42192735920) 保持失败记录：cold-boot 的 `curl_tls_positive_failed`，当时未保存 curl 详细原因。失败产物 SHA-256 为 `154930452efb433dba982bc77eb193690359b0a0f60aa5c1836227d0720f6028`。本轮修订后使用新提交运行完整门禁，不把旧失败改写成成功。

候选已按修复单元增量推送：安装与历史 `cacbb3456686d0b819650b079bfcfeec478cdd72`，TLS `ccbaada2feb108805e2d45654cf1df345d95cd5e`，监督恢复 `ef56af9a964f73cf0b5cb618492b9831850ee861`。独立启动恢复入口追加 `1439c08c2e454354d52db6a3700af8bb84b2104b`，旧代码在真实配置锁夹具内启动维护进程，修复后锁内只保留核心/策略事务，维护进程全部锁外恢复；这证明锁序缺口，不证明实际设备必然死锁。首次整合源码为 `39ba7487f187d44febaf573c3ba1faf3992e0797`，tree `4e16922735c22fc696c6dd73b6a44182e8635acb`，对应 [源码 PR #3](https://github.com/LIghtJUNction/magicnet-android/pull/3)，当时主仓库 gitlink 指向该提交。整合后官方 ShellCheck、823 个跟踪文本的 source lint 与 Rust fmt 通过。首次 PR 候选的 Android run [42211936356](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42211936356) 为 attempt 1，随后由仅修正文档证据边界的新提交替代；生产与测试代码未变。后续最终门禁、合并和 Issue 回读结果记录如下。软件版本保持 1.8.5 / 10613，本次不创建正式 Release。

### 中间候选 39ba7487 的实际整合结果

以下均为该候选的 attempt 1，不用其他源码的结果替代。受测 PR merge 提交为 `aa38c7ab9ff949a4a2d504733e93c35054a5fd2a`，其 tree 与 PR head 相同。

| 工作流 | 结果 |
| --- | --- |
| [Code Quality 42212473927](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212473927) | 7 个 job 全部成功，包含匹配 stable 的 Rust Clippy 与完整质量门槛 |
| [Build Kam Module 42212473994](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212473994) | 构建、包内容与分包门槛成功，未创建正式发行 |
| [Network regression 42212473950](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212473950) | 成功 |
| [Rules Release Integration 42212474058](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212474058) | 成功 |
| [Network Regression Evidence 42212474059](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212474059) | 成功 |
| [Install Onboarding 42212474153](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212474153) | contracts 与真实浏览器测试成功；依赖安装用时 22 分 56 秒，完成后的日志定位为 Ubuntu 镜像的字体下载慢及回退；实际浏览器测试用时 38 秒 |
| [Android KernelSU Acceptance 42212473958](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212473958) | harness 成功；environment、kernelsu-bootstrap、install-before-first-boot 通过；cold-boot 失败，其余 8 阶段未运行 |

Android 在 2026-11-06 12:01:23–12:04:43 UTC 执行生命周期步骤；cold-boot 等待约 130.465 秒后报 `core process/API/TUN did not become ready`。失败时核心进程为 running，API ready=true，但 `transparent.dataplane_ready` 和整体 readiness 均为 null，生命周期为 running_unknown；TUN 日志仍有接收连接。该产物没有路由快照或 health 详细理由，尚不能仅凭 null 判断具体命令、解析或预算故障。

该 39ba 运行尚未进入本地 TLS proof，因而没有 `module-curl-controls.json` 或 `local_tls_diagnostics`；不能把本次失败归因于证书或时钟，也不能宣称新增 TLS 诊断已经通过 Android 验收。[失败产物 13499539200](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212473958/artifacts/13499539200) 为 169,342 字节，SHA-256 `fcb5f4e271493083809c7a23731cd0bb4baa35f1bd5bb220ce1adc157b9bf996`，下载校验与 GitHub digest 一致。后续 8ff 使用新源码验证，结果见下；这次失败记录保持。

固定 [AOSP android-15.0.0_r1 的 ip/ip.c](https://android.googlesource.com/platform/external/iproute2/+/refs/tags/android-15.0.0_r1/ip/ip.c) 显示 `-numeric` 分支被编译条件禁用，未知选项在打开 netlink 前退出；39ba7487 候选的观察器无条件传入 `-N`，因此存在可由固定源码证明的 Android 参数不兼容。下载源码 SHA-256 为 `e9d7bacc4b0864b6f58a26fc547207157f250717d36cae9f0a73b758d18c0673`。这支持修正平台调用，不能从缺少详细命令证据的旧产物排除并存原因；新的实际 Android 结果见下文。

预发布独立复核另发现数字外观表别名的误报：在固定 AOSP 解析器的合成映射 `4242 2022` 下，参数 `2022` 与输出名称都可指向真实表 4242，而不是配置的表 2022。原解析器的 15 组受控参数对照证明，单个 argv 的前导 ASCII 空格可排除 `%s` 读取的别名匹配，并保留数字解析；修复必须同时保护 RPDB 过滤与 FIB 目标，且不能因输出看似数字而跳过实际表身份核验。此反例属于宿主解析器与受控表映射验证，未修改系统或设备路由，也不等同于旧 Android run 的原始现场证据。

自动审查服务按提交分别记录：源码 PR 初期的 Sourcery 评论报告七天差分配额不足，最终 8ff 的 Sourcery check 因单 PR 超过 150,000 个差分字符而 skipped；Codex Security Review 的用量上限失败属于旧候选 189adb2，不能当作 8ff 的审查通过。主仓库 679bd7e3 的 Sourcery check 为 success、0 annotations，不能外推为源码 PR 的安全审查完成。合并前最后一次核对时，两 PR 均无可行动的 inline 线程或正式 review。已有 DNS PR 的两个审查线程依据原代码与固定核心处理；本轮源码另行独立复核并按固定提交验证，没有更改额度、付费设置或绕过审查限制。

### 最终受测并已合并的实现 8ff1242

当前源码为 `8ff1242817038dfe220a68b75934d6b127bea4b1`，tree `a23ade9034a47be945dc526f7fe5b00751267911`，主仓库 gitlink、README、依赖与来源记录均接入该固定点。三个增量提交分别为安装引导预算 `92b3fe62bc49902c540db2dfeb7ce9a6a16a493c`、就绪失败支持包 `7e497c3c978780f888572c2a4f5fbc16668da862`、Android 参数兼容与精确表 ID `8ff1242817038dfe220a68b75934d6b127bea4b1`。本地与远端 tree 已核对一致。

Android 固定调用 `/system/bin/ip` 并使用系统支持的参数。配置规则窗口和 redirect fallback 内的每条相关 lookup，包括数字外观输出，均须和无歧义目标数字表的过滤快照逐条对应；所有平台 FIB 使用同一无歧义表参数。无法证明的映射保持 unknown。每族最多三份快照，全部仍共享原三秒命令截止时间与每流 256 KiB 上限。原规则残片、连接子网和 FIB 覆盖判断保持。

就绪超时在失败收尾优先复用现有 `support export`，导出最多 20 秒、受限读取最多 4 秒，二者和原有诊断共享同一个 25 秒截止时间；固定路径、非链接、512 KiB 上限、精确 UTF-8 字节数与完整格式检查后才保存 `readiness-support.txt`。失败只记规范化回执，既有生产脱敏实现不变，原错误和就绪成功条件不变。安装引导拆分依赖步骤：npm 5 分钟、Chromium/系统依赖 20 分钟、BusyBox/字体 25 分钟；browser job 60 分钟，实际测试仍为 5 分钟。这些是明确预算，不把已成功的旧镜像延迟说成浏览器失败。

| 新增验证 | 结果与身份 |
| --- | --- |
| Android 命令兼容及数字表身份 | 宿主编译的固定 AOSP 原版 ip 的双栈 `-N` 均 exit255；原表解析器 15 组参数对照；生产观察器旧伪绿反例为 `[true,true]`，新结果为 `[unknown,false]`；Linux FIB 另有正反例 |
| 最终 Rust 实现 | 独立修复树 `9d7b68188ee7e15b1f5f6778a898703605084974`：CLI 841 passed / 1 ignored，含 TUN 19 项；根整合的 Cargo 文件、crates 和生产模块与此树逐字节相同 |
| 失败支持包 | `693b2e4c029f0d714ac225f67089124d570dea7e`：simulation 109 项通过，包括 7 个新增失败采集反例；与最终候选对应 Python 文件相同 |
| 整合静态检查 | 官方 source lint 823 个跟踪文本、Rust fmt、diff check 均通过；独立复核无剩余阻断；未重复声称本地有匹配 Clippy |

最终候选的 [core-evidence job 127895219885](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218749968/job/127895219885) 在 12:37:42–12:37:48 UTC 实际完成 DNS 出口必需步骤。六条 PASS 日志覆盖生产物化/幂等、真实核心校验、未分类 A/AAAA × UDP/TCP 经代理、节点域名保持直连引导、显式 direct 的 A/UDP 控制，以及代理 HTTP 502 拒绝后的 A/AAAA UDP 查询零直连回退。拒绝负例未覆盖 TCP。端点是 Linux/amd64 上的回环 TLS DoH 与 HTTP CONNECT，公共请求为零，不是 Android 拦截或公网出口证据。受测 merge `d22db107e3b3f572b6353615492c60b6859bde64` 的 tree 与最终 head 完全相同；核心固定 d850ff0，模板固定 ba5793b4。精确步骤、日志和范围见 [DNS CI 证据](https://github.com/LIghtJUNction/MagicNet/blob/679bd7e39f0184c3f3daa2e0ac9065e6d48e520a/docs/evidence/issue-pr-dns-ci-2026-11-06.json)。

最终受测源码的七条工作流全部 success，均为 attempt 1；旧失败和新验证保留各自身份。源码正式 merge 与受测 head 的 tree 一致，正式 merge SHA 单列如下，不与临时 PR merge 混用。

| 最终受测源码工作流 | 最终结果 |
| --- | --- |
| [Code Quality 42218750003](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750003) | 成功，6 个前置 job 与最终质量 gate 全部通过 |
| [Build Kam Module 42218750064](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750064) | 成功，模块构建、包内容、离线分包与增量安装器均通过；正式发行任务按 PR 条件跳过 |
| [Network regression 42218749897](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218749897) | 成功；DNS NAT 与 offline 测试通过，按条件未运行公网 runner 观察 |
| [Rules Release Integration 42218750114](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750114) | 成功 |
| [Network Regression Evidence 42218749968](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218749968) | 成功，visual/core/avd-storage 三个 job 全部通过 |
| [Install Onboarding 42218750011](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750011) | 成功；47 个场景与 8 种布局设计通过，实际浏览器测试 38 秒；慢系统依赖下载在原定预算内完成 |
| [Android KernelSU Acceptance 42218750254](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750254) | 成功；harness、实际 Android 与最终 Gate 全部通过，12/12 阶段、5/5 重启 |

六条非 Android 工作流共 16 个实际执行 job 成功；另有 version-bump、release-android 和公网 runner 观察三个 job 按触发条件跳过，不计为发行或公网验收。DNS 内核回归在本地命名空间完成 248 次交换，覆盖 31 个测试主机、A/AAAA、UDP/TCP、IPv4/IPv6 和 UID 0；先复现竞争 DNAT 黑洞，再验证修复。该结果与上面的真实核心 DoH 出口测试属于不同夹具，不互相替代。

### Android 实际验收与产物

[Android run 42218750254 / attempt 1](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750254) 的三个必需 job 均 success，最终 Gate 在 2026-11-06 12:58:49 UTC 完成。实际受测 merge 为 `d22db107e3b3f572b6353615492c60b6859bde64`，与 8ff 的 tree 同为 `a23ade9034a47be945dc526f7fe5b00751267911`。生命周期步骤在 12:49:31–12:58:10 UTC 执行；simulation.json 与 JUnit 均为 12 passed、0 failed、0 not_run。

十二阶段全部执行通过：environment、kernelsu-bootstrap、install-before-first-boot、cold-boot、app-uid-tun-controls、invalid-config-rollback、stop-cleanup、restart-idempotence、upgrade-preservation、disable-reboot、enable-reboot、uninstall-reboot。五次重启均 exit 0，观察到新 boot、root 和 SELinux Enforcing；KernelSU 的 post-fs-data、services、boot-completed 原生阶段均通过。四份应用 UID TUN 对照为 verified，positive/reject/positive_after/restored 全部 true，范围限定为 `emulator_test_uid_tcp`。

| 本地 TLS 对照 | curl 退出码 | 固定错误分类 | 服务端 GET 增量 |
| --- | --- | --- | --- |
| 可信临时 CA | 0 | none | 1 |
| 错误主机名 | 60 | hostname_mismatch | 0 |
| 默认信任拒绝临时 CA | 60 | untrusted_certificate | 0 |

TLS 安装后二进制摘要核验通过，local_tls_diagnostics 为 verified，cleanup=true。主机观测时间 2026-11-06 12:51:29–12:51:30 UTC，guest 为 12:51:29；证书有效期为 2026-11-06 12:46:30 至次日 12:51:30 UTC。该结果证明本次控制通过，不能反推历史 TLS 失败的唯一原因。

**实际 Google 仍未取得 HTTPS 204。** 正常产品执行了一次 tick，观察为 `offline / upstream_unavailable / tls_failure`，HTTP 状态为 null，secondary/direct 均 failed，未把结果写成公网成功。DNS fixture 的零公网请求仅属于该 fixture，不代表整个 Android 流程没有产品联网观察。

[最终 Android 产物 13504425735](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750254/artifacts/13504425735) 为 497,761 字节，下载校验 SHA-256 为 `44ffd01ea75ce0be8af43da7f14888a82ffe29e0252de04fc521d048e8b04ad9`，与 GitHub digest 一致。正常支持包导出成功，为 64,486 字节。新增就绪失败支持包分支在本次成功运行中没有触发，其覆盖仍归属前述 109 项宿主回归；不因最终成功而虚构设备故障注入。

本轮实际设备环境是固定内核的 Android 15 / KernelSU v3.2.0 / x86_64 TUN 夹具。ARM64 真机、OEM 网络切换、IPv6 包转发、eBPF 数据面、公网代理质量和 Play/GMS 行为没有由此完成验收。可选公开基准步骤按条件跳过，与十二个实际执行阶段没有混计。

## 实际合并与 Issue 回读

| 仓库与 PR | 实际合并提交 | 时间（UTC） | 核对 |
| --- | --- | --- | --- |
| [magicnet-android #3](https://github.com/LIghtJUNction/magicnet-android/pull/3) | `9664c2ba4a8503df0423b6de2271af8dca1a86dd` | 2026-11-06 13:01:31 | merged=true；tree 与受测 8ff 完全相同 |
| [MagicNet #442](https://github.com/LIghtJUNction/MagicNet/pull/442) | `e8394e7cf9044c7f4c2e1f542c3d5a228b8716b4` | 2026-11-06 13:02:06 | merged=true；gitlink 固定 8ff，合并 tree 与受审 679bd7e3 相同 |

主仓库合并前最后的 [Recipe checks 42220676435](https://github.com/LIghtJUNction/MagicNet/actions/runs/42220676435) 成功，配方仍为 0.3.16 / 8 包 / 61 Markdown。源码先合并并核对 tree，再合并主仓库；两次均使用精确预期 head，未解除规则或修改权限。软件版本保持 1.8.5 / 10613，正式公开更新索引和 Release 未在本轮变更，未部署物理设备。

合并后逐项更新并回读：#437、#438、#439 为 closed/completed，#436、#440 为 open；五个 Issue 均保留原正文，并追加带日期的维护说明、固定源码、最终 CI 和剩余范围。本记录包含最终验收、合并回读及 Issue 实际状态。此前 DNS 源码/模板/主仓库 PR 的合并与两个审查线程处理结果仍保留在本记录开头。

## 剩余验收

#436 需要在固定随包核心上取得网络切换前后实际 RPDB/FIB 和应用流量证据，区分 netd/OEM、核心和其他网络工具造成的变化。原报告使用官方 1.14.3 核心，不能直接等同于当前固定 fork。检测缺口的修复不会自动证明规则丢失原因已经修复。

#440 的可信 NAS/私网来源需要独立、显式启用的信任范围与逐跳校验设计。当前 HTTPS/公网订阅保护保持；没有通过全局放开 HTTP、私网或代理环境来宣称支持该能力。

## 2026-11-07 固定点回读

主仓库 gitlink 在发布入口合并后前进到 [`b989227b140a7627edff8b60ad87655cb09ac2d0`](https://github.com/LIghtJUNction/magicnet-android/commit/b989227b140a7627edff8b60ad87655cb09ac2d0)（tree `7857e06e0f556aee1cb716cbcd717324e1da3f05`）：只安装完整质量套件所需 mksh。`8ff1242817038dfe220a68b75934d6b127bea4b1` 仍是 Issue 修复验收身份，不是当前 gitlink。已发布 Android 包仍为 v1.8.4 / 10612。

#436 与 #440 仍开放。前者缺固定随包核心在真机换网前后的 RPDB/FIB 与恢复路径，本配方仓库不能把健康检测修复写成规则丢失根因已修复，也不能在未改源码的情况下新增自动重启守护。后者的可信 NAS/私网入口仍需独立、显式启用的信任范围与逐跳校验；未通过全局放开 HTTP/私网或代理环境来宣称支持。源码仓库当前无开放 Issue 或 PR。本轮配方仓库未改运行时，也未向源码仓库推送新提交。

## 结论与证据自检

| 自检维度 | 本记录要求 |
| --- | --- |
| 修改是否对应具体问题 | 每项关联原 Issue、实际代码路径及反例 |
| 说明是否清楚 | 分开描述配置意图、运行证据、历史记录和完整流量 |
| 实验是否支持结论 | 旧版失败与修复后通过逐项记录，主机替身不标为设备成功 |
| 覆盖是否完整 | 最终 CI 已逐项记录；物理设备、真实公网和 NAS 能力保留各自待验证/待实现边界 |
| 方法边界是否保持 | 未知归属继续保守，TLS 拒绝与隐私边界保持，无新增产品模式 |


## 2026-11-07 工作流审计后追加固定点

CI 审计将当前源码指针前进至 [`af3930bd9860344688efa62684afdd7ba4ba25f5`](https://github.com/LIghtJUNction/magicnet-android/commit/af3930bd9860344688efa62684afdd7ba4ba25f5)，tree `60a573d8a4d7e349f70801edbf3b3882e8a9dd8a`，由主仓库 [PR #445](https://github.com/LIghtJUNction/MagicNet/pull/445) 接入。新增源码提交仅涉及工作流门禁、gitlink 触发路径与 ADB 成功测试预算；本记录原 Issue 验收提交 `8ff1242817038dfe220a68b75934d6b127bea4b1` 及此前 b989 验证记录保留原身份。

这些 CI 修订不改变 #436 的真机网络证据缺口或 #440 的可信来源设计范围，也不新增 Android 软件发行。逐工作流结果及本轮真实 CI 见主仓库 docs/workflow-audit-2026-11-07.md。


## 2026-11-10 日常 Issue / 安全 / 冗余扫描

公开 GitHub 仍只有两个开放 Issue：[#436](https://github.com/LIghtJUNction/MagicNet/issues/436)、[#440](https://github.com/LIghtJUNction/MagicNet/issues/440)。主仓库与源码仓库均无开放 PR；源码仓库无开放 Issue。本轮只改配方仓跟踪记录，不向 `magicnet-android` 推送，也不关闭上述 Issue。

当前 live pin：gitlink `9163064b51ba59cc89ac9a807fceb24573fed725`（tree `ce5f393cb480f724cb356e44e3146daf4788f588`），配方 0.3.20，公开稳定包 v1.8.5 / 10613。11-07 节中的 b989 / af3930bd / v1.8.4 仍是当时身份，不是当前指针。

### Issue 现状

| Issue | 已合入源码（相对 11-07） | 仍开放的原因 |
| --- | --- | --- |
| #436 | [48efc93](https://github.com/LIghtJUNction/magicnet-android/commit/48efc93601ed1bb66871c1274034a372da2ffc06) 已在既有 watchdog 中独立观察 TUN，连续两次缺规则、90 秒宽限、共享 300 秒冷却后走标准重启，每开机最多 3 次。9163064 的 Android 运行 [42676133752](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42676133752) 已证明 RPDB 恢复（同 UID UDP 1→0→1） | 完整 13 阶段未通过：上联阶段 `uplink_reconnect_deadline`，guest 日志为 Wi-Fi 断开关联/supplicant 退出，接口 UP 不能当作关联恢复。独立 guard 的 Android 框架恢复动作尚未实施。OEM 删除规则的触发者、物理 ARM64 与公网行为仍未验证。11-07 所写“本配方仓库不能新增自动重启守护”已被后续源码合入取代，不再作为当前缺口 |
| #440 | 订阅历史 `last_phase`/`last_result` 迁移仍以 8ff12428 / PR #3 为准 | 可信 NAS/私网入口仍未实现。公网订阅继续强制 HTTPS、拒绝私网/CGNAT/元数据、每跳校验、禁止环境代理。不得靠全局放宽 SUB-003 宣称支持 |

### 代码漏洞扫描（只读，固定源码 9163064）

未发现可在本配方仓修复的新生产漏洞。抽查结论：

- 订阅抓取仍 fail-closed：仅 HTTPS、`--max-redirs` 受控、公网地址策略含 CGNAT/`::ffff:` 映射、禁止 `MAGICNET_SUB_PROXY` 与用户 curlrc。#440 所需的显式信任范围不存在，这是功能缺口而不是保护被绕过。
- MCP 默认关闭，空 secret 拒绝授权，Bearer / 自定义头使用恒定时间比较，连接数有上限，请求头/体有界。
- 安装迁移、ZIP 成员路径、订阅事务 generation、规则 `local` 路径均有拒绝 `../` 与非普通文件的回归。
- WebUI JSON 高亮走 highlight.js 转义后再 `v-html`，编辑器内容是用户本机配置，不是远程 HTML。
- 主仓库工作流：可复用源码工作流与 gitlink 同为 9163064；第三方 action 使用 40 字符 SHA；`recipe-check` 权限 `contents: read`；发布写权限仍限 `workflow_dispatch` + `mode=publish`。`check-workflows.sh` 用固定 SHA-256 校验 actionlint 1.7.12。

未把静态抽查写成渗透测试或真机攻击面证明。若发现可利用的 root/MCP/订阅绕过，应按源码 `SECURITY.md` 私下报告，不在公开 Issue 贴复现步骤。

### 冗余代码扫描

对 `src/MagicNet/**/*.sh` 提取 411 个函数名后，仅定义处出现的名称与 11-02 扫描一致，继续保留：

- `kamfw_phase_action` / `kamfw_phase_service`：kamfw 阶段钩子，由框架按名调用。
- `magicnet_kernel_route_rule_start` / `end` / `fallback_rule` 与 `magicnet_ip6tables_nat_ensure`：生命周期与 IPv6 NAT 入口，动态或按合同保留。
- `_launch_run`：farewell/onboarding 里覆盖 launcher 的局部函数（SC2317），不是死代码。

此前删除的 `magicnet_prepare_singbox_nodes` 包装在当前树中已不存在。主仓库 `scripts/` 的发布/配方检查函数均被对应测试或工作流引用，没有可删的平行入口。本轮不删除产品测试或降低验收。


## 2026-11-12 日常 Issue / 安全 / 冗余扫描

公开 GitHub 现有四个开放 Issue：[#436](https://github.com/LIghtJUNction/MagicNet/issues/436)、[#440](https://github.com/LIghtJUNction/MagicNet/issues/440)、[#447](https://github.com/LIghtJUNction/MagicNet/issues/447)、[#449](https://github.com/LIghtJUNction/MagicNet/issues/449)。主仓库开放 PR [#448](https://github.com/LIghtJUNction/MagicNet/pull/448) 已与 main 冲突且会把 gitlink 从 `dc4433d1` 回退，不得合并。源码仓库无开放 Issue；开放 PR [#5](https://github.com/LIghtJUNction/magicnet-android/pull/5) 仍只改 Android CI 上联证据。本轮只改配方仓：修正 BUILD_PROMPT 配方版本标题、把未合入的 live-pin 门禁接到当前 gitlink，并记录 #449。不向 `magicnet-android` 推送，也不关闭上述 Issue。

当前 live pin：gitlink `dc4433d1cfbeade114d51f3f3c429378d3d7b68d`（tree `75337165f18b87a02d34de7ee0039b902257e48c`），配方 0.3.21，公开稳定包 v1.8.7 / 10615。11-10 节使用当时的 `9163064` / v1.8.5；未合并的 #448 审计使用当时的 `406938e3` / v1.8.6。

### Issue 现状

| Issue | 已合入源码（相对 11-10） | 仍开放的原因 |
| --- | --- | --- |
| #436 | 有界 TUN watchdog 仍以 48efc93 为准。v1.8.7 / dc4433d1 已在模拟器完成 RPDB 删除与 wlan0 关联恢复：Android 13/13 阶段通过，报告含 `android_wifi_toggle`、guard 退出、真实默认路由、就绪和同 UID TCP | 真机 OEM/netd 删除规则的触发者、物理 ARM64 与公网行为仍未验证。源码 PR #5 未合入，也不能单独关闭本 Issue |
| #440 | 订阅历史迁移仍以 8ff12428 / PR #3 为准 | 可信 NAS/私网入口仍未实现。公网订阅继续强制 HTTPS、拒绝私网/CGNAT/元数据、每跳校验、禁止环境代理 |
| #447 | 无新实现。WebUI「申请适配」提交 zashboard / local-download | 已是审核锁定的默认面板：`Zephyruso/zashboard` v3.16.0 `dist-no-fonts.zip`。保持 open 直至维护者关闭 |
| #449 | 与 #447 相同正文，提交者 `pwj123-bot` | 重复申请，不另做内置。保持 open 直至维护者关闭 |

### 本轮配方仓修复

v1.8.7 已把 gitlink、README、DEPENDENCIES、`release.yml` 可复用工作流对齐到 `dc4433d1`，但留下两处配方仓缺口：

- 根 `BUILD_PROMPT.md` 标题仍写配方 0.3.20，而 `RECIPE.md` / README / DEPENDENCIES 已是 0.3.21
- 昨日 [#448](https://github.com/LIghtJUNction/MagicNet/pull/448) 拟增加的 `check-recipes.py` live-pin 门禁从未合入；该 PR 现与 main 冲突，且会把 gitlink 从已发布的 `dc4433d1` 回退，不能合并

本轮把标题改为 0.3.21，并让 `scripts/check-recipes.py` 拒绝 BUILD_PROMPT gitlink、配方版本或 `release.yml` 可复用工作流与当前 gitlink 漂移。

### 代码漏洞扫描（只读，固定源码 dc4433d1）

未发现可在本配方仓修复的新生产漏洞。抽查结论：

- 订阅抓取仍 fail-closed：仅 HTTPS、`-q` 忽略 curlrc、`--max-redirs 0`、公网地址策略含 CGNAT/`::ffff:` 映射、禁止 `MAGICNET_SUB_PROXY` 与环境代理。重定向逐跳再校验。#440 仍是功能缺口而不是保护被绕过。
- MCP 默认关闭，空 secret 拒绝授权，Bearer / 自定义头使用恒定时间比较。
- 安装迁移、ZIP 成员路径、订阅事务 generation、规则 `local` 路径均有拒绝 `../` 与非普通文件的回归。
- WebUI JSON 高亮走 highlight.js 转义后再 `v-html`，编辑器内容是用户本机配置，不是远程 HTML。
- 主仓库工作流：可复用源码工作流与 gitlink 同为 dc4433d1；第三方 action 使用 40 字符 SHA；`recipe-check` 权限 `contents: read`；发布写权限仍限 `workflow_dispatch` + `mode=publish`。`check-workflows.sh` 用固定 SHA-256 校验 actionlint 1.7.12。

未把静态抽查写成渗透测试或真机攻击面证明。若发现可利用的 root/MCP/订阅绕过，应按源码 `SECURITY.md` 私下报告，不在公开 Issue 贴复现步骤。

### 冗余代码扫描

对 `src/MagicNet/**/*.sh` 提取 411 个定义 / 407 个唯一函数名。仅在定义处出现的名称继续保留，不删除：

- `kamfw_phase_action` / `kamfw_phase_service`：kamfw 阶段钩子。
- `magicnet_*_apply` 加锁包装由 Rust `run_magicnet_function` 按名调用。
- `magicnet_kernel_route_rule_start` / `end` / `fallback_rule` 与 `magicnet_ip6tables_nat_ensure`：生命周期与 IPv6 NAT 入口。
- `_launch_run`：farewell/onboarding 覆盖 launcher 的局部函数（缩进定义，SC2317）。
- `magicnet_hotspot_watchdog_start_unlocked`：由 `magicnet_hotspot_watchdog_${action}_unlocked` 动态调用。

此前删除的 `magicnet_prepare_singbox_nodes` 包装仍不存在。主仓库 `scripts/` 的发布/配方检查函数均被对应测试或工作流引用。本轮不删除产品测试或降低验收。

## 2026-11-13：#436 路由恢复验收的逐应用规则归属

生产有界 TUN 恢复已随 v1.8.7 发行。最新源码 `5edd36ba` 的 [Android 运行 43253655173](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43253655173) 记录了 UDP 1→0→1、readiness false→true 和一次成功恢复，随后因 `recovery_rule_set_mismatch` 失败。现场差异为 eth0 netId 100→101 时同步更新的全局和逐应用规则；其余 netd 网络信息、接口/FIB 和 UID 范围保持。

[`58ccae52`](https://github.com/LIghtJUNction/magicnet-android/commit/58ccae52677fa95843eb2c0566c095385afbae49) 在采集器与独立门禁中补齐由 netd 元数据派生的逐应用 selectors，核对完整字段及重复次数，保留外部规则保护、既有恢复预算和证据 schema。源码 PR [#7](https://github.com/LIghtJUNction/magicnet-android/pull/7) 承载本轮候选；已完成的宿主回归与新 Android CI 状态分别见 VERIFICATION。#436 原报告的物理设备/OEM 触发原因仍需独立证据，本轮保持 Issue 开放。


后继 [`9dba9425`](https://github.com/LIghtJUNction/magicnet-android/commit/9dba94254780fb0a1a84a003608d5919a97de4f2) 根据新失败证据补入可恢复的单 eth0 AVD 夹具，避免 hosts-only 离线 DNS 实验期间 Android 在 Wi-Fi/eth0 之间另行选择默认网络（后续诊断确认eth0为模拟蜂窝接口）；严格外部规则比较保持。源码运行 43385059168 的默认网络迁移与整合运行 43385469784 的故障前 UDP 超时分别保留，均为 5/1/7 阶段结果。UDP 超时原因尚未确定，后继只增加清理前的有界脱敏支持采集，仍要求全新的 UDP 正反控制。9dba 的[整合43391099744](https://github.com/LIghtJUNction/MagicNet/actions/runs/43391099744)完整13/13、5次重启及发布质量门禁通过，实际覆盖netId100→102；但同树[源码43390671015](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43390671015)在RPDB恢复成功后，因eth0 IPv4默认路由600秒未恢复而失败，仍为5/1/7。清理前支持包捕获了UP链路、保留地址/TUN与缺失的Android IPv4路由。成功整合不覆盖此失败。


候选 [`5f96a190`](https://github.com/LIghtJUNction/magicnet-android/commit/5f96a190a08e50ea6654ef52117d5a730d044e05) 尝试观察Ethernet服务停止，但[源码43399092150](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43399092150)与[整合43399411108](https://github.com/LIghtJUNction/MagicNet/actions/runs/43399411108)的Android均在baseline报 `incomplete_ethernet_dump`，尚未down；RPDB恢复与UDP正负正通过，总计仍为5/1/7、1次重启。旧门禁复验均exit1。实际[服务诊断43403995584](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43403995584)证明镜像没有ethernet服务，不能继续把EthernetFactory竞态当作该接口的解释。

[模拟蜂窝诊断43404505529](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43404505529)确认eth0属于CELLULAR/WWAN/sub1，经Android移动数据服务关闭/开启完成netId101→无→102、接口UP→DOWN→UP、数据状态启用→禁用→启用。后继 `668701523f52959f2daf5113ee11b716aa7ecddb` 改用实际蜂窝生命周期，独立核对当前registry/默认订阅、netd旧网络销毁与逐应用UID元数据仅迁移至UNREACHABLE并返回；恢复仍要求原路由/就绪/应用TCP。独立enable guard与600秒预算保留。stock kernel 诊断不替代完整 KernelSU 故障闭环，实际 668 结果分别记录如下。

`66870152` 的[源码 Android 43407220745](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43407220745)保留 9 passed /1 failed /3 not_run：路由恢复阶段已通过（325.799 秒），但 `upgrade-preservation` 的第二次重启报 `Android boot deadline exceeded`，命令退出码 124，`new_boot_observed=false`。实际报告源码为同树合成测试提交 `053a11d134f3177fa94e917828245a2dfce81a36`；完整原始报告经 668 门禁复验仍 exit 1，单独路由证据通过不改变该失败。

固定 668 的[配方整合 43407837059](https://github.com/LIghtJUNction/MagicNet/actions/runs/43407837059)及 [Recipe checks 43407835916](https://github.com/LIghtJUNction/MagicNet/actions/runs/43407835916)成功：原始 Android 报告 13/13、5 次真实重启，精确 668 独立门禁 exit 0，完整构建、实际发布质量门禁和远端资产检查通过。RPDB UDP 为 1→0→1，cellular 记录 netId100→无→103、UID 元数据精确迁移至 UNREACHABLE52 并返回，最终默认路由/readiness/TCP 与 Wi-Fi 启用状态恢复通过。构建 artifact `14031630631` 的 digest 为 `2aa89ecb49c7b63bfadf99e4c11817da5f11549b51154ffb4b4b87bcd8478706`，由远端 CI 下载与清单校验核对；工作环境中断后没有本地独立复算。配方成功不覆盖源码升级重启失败，publish 被跳过。

当前后继固定点为 `a4135d5edc39af4895968359bf16e8aefefdaeac`（tree `f477642021d129ae9b5a64d87436f678db06d62f`），增量仅为宿主诊断观察器，用于保留启动失败现场的观察，未修复未知的 boot 失败根因。runtime 恢复预算与独立门禁不变，配方仍为 0.3.22 / runtime 0.1.12。[隔离短测试 43417860968](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43417860968)完成 host 观察器27、重启6、工作流合同29、gate72项检查并通过；其五个已审查源码 blob 进入当前候选，临时 workflow 未合入。新候选完整 CI 待验证。全部历史失败继续保留，#436 原设备/OEM 触发原因仍开放；当前验证边界见 [VERIFICATION.md](VERIFICATION.md)。
