# MagicNet Issue 与 PR 处理记录（2026-11-06）

## 范围与结论状态

用户授权直接合并并处理 Issue/PR。本记录追踪三个项目仓库的当前事项；源码候选仍在最终整合与门禁阶段，以下本地结果不能替代尚未完成的 CI 或物理设备验收。

此前 DNS 修复已经合并：[源码 PR #2](https://github.com/LIghtJUNction/magicnet-android/pull/2)、[模板 PR #21](https://github.com/LIghtJUNction/MagicSingBox/pull/21)、[主仓库 PR #441](https://github.com/LIghtJUNction/MagicNet/pull/441)。本轮初始核对时三仓库均无待合并 PR；主仓库有五个开放 Issue。两个尚未解决的 DNS 审查线程已补充依据并标记解决：保留用户显式解析器属于兼容边界；当前固定核心按 transport tag 隔离 DNS 缓存，不能套用旧版独立缓存开关的结论。

## Issue 处置与证据边界

| Issue | 已确认缺口与修改 | 处置目标 |
| --- | --- | --- |
| [#438](https://github.com/LIghtJUNction/MagicNet/issues/438) | 整目录恢复会丢失新版网页探测目标清单；恢复后仅为缺失文件从当前 ZIP 补默认值，保留自定义字节并拒绝不安全路径 | 合并并通过门禁后关闭 |
| [#437](https://github.com/LIghtJUNction/MagicNet/issues/437) | orphan 候选过宽使无关进程的未知身份误阻断；订阅重启区分真正 worker/DNS 失败与独立热点路由清理，后者保留警告和既有重试 | 合并并通过门禁后关闭；不宣称所有现场 rc=2 同源 |
| [#439](https://github.com/LIghtJUNction/MagicNet/issues/439) | 订阅更新后未恢复完整维护集合；统一恢复 connectivity、refresh、Wi-Fi policy、hotspot 与原活动 fswatch，覆盖 journal、回滚和中断 | 合并并通过门禁后关闭 |
| [#436](https://github.com/LIghtJUNction/MagicNet/issues/436) | health 与机器状态过去只看 TUN 接口，无法发现规则组丢失；增加配置派生的有界实时路由证据 | 保持开放，区分已修复的误报与未查明的真机规则丢失原因 |
| [#440](https://github.com/LIghtJUNction/MagicNet/issues/440) | 升级遗漏订阅更新历史；仅将历史加入同一迁移清单，当前 .state 的更新锁不随历史恢复 | 历史部分完成后记进展；可信 NAS/私网订阅入口仍保持开放 |

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

候选已按修复单元增量推送：安装与历史 `cacbb3456686d0b819650b079bfcfeec478cdd72`，TLS `ccbaada2feb108805e2d45654cf1df345d95cd5e`，监督恢复 `ef56af9a964f73cf0b5cb618492b9831850ee861`。独立启动恢复入口追加 `1439c08c2e454354d52db6a3700af8bb84b2104b`，旧代码在真实配置锁夹具内启动维护进程，修复后锁内只保留核心/策略事务，维护进程全部锁外恢复；这证明锁序缺口，不证明实际设备必然死锁。首次整合源码为 `39ba7487f187d44febaf573c3ba1faf3992e0797`，tree `4e16922735c22fc696c6dd73b6a44182e8635acb`，对应 [源码 PR #3](https://github.com/LIghtJUNction/magicnet-android/pull/3)，当时主仓库 gitlink 指向该提交。整合后官方 ShellCheck、823 个跟踪文本的 source lint 与 Rust fmt 通过。首次 PR 候选的 Android run [42211936356](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42211936356) 为 attempt 1，随后由仅修正文档证据边界的新提交替代；生产与测试代码未变。最新提交的最终门禁与合并结果将在完成后补齐。软件版本保持 1.8.5 / 10613，本次不创建正式 Release。

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

本轮尚未进入本地 TLS proof，因而没有 `module-curl-controls.json` 或 `local_tls_diagnostics`；不能把本次失败归因于证书或时钟，也不能宣称新增 TLS 诊断已经通过 Android 验收。[失败产物 13499539200](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42212473958/artifacts/13499539200) 为 169,342 字节，SHA-256 `fcb5f4e271493083809c7a23731cd0bb4baa35f1bd5bb220ce1adc157b9bf996`，下载校验与 GitHub digest 一致。修复后将使用新源码运行，不覆盖这次失败。

固定 [AOSP android-15.0.0_r1 的 ip/ip.c](https://android.googlesource.com/platform/external/iproute2/+/refs/tags/android-15.0.0_r1/ip/ip.c) 显示 `-numeric` 分支被编译条件禁用，未知选项在打开 netlink 前退出；39ba7487 候选的观察器无条件传入 `-N`，因此存在可由固定源码证明的 Android 参数不兼容。下载源码 SHA-256 为 `e9d7bacc4b0864b6f58a26fc547207157f250717d36cae9f0a73b758d18c0673`。这支持修正平台调用，不能从缺少详细命令证据的旧产物排除并存原因；新的实际 Android 结果另记。

预发布独立复核另发现数字外观表别名的误报：在固定 AOSP 解析器的合成映射 `4242 2022` 下，参数 `2022` 与输出名称都可指向真实表 4242，而不是配置的表 2022。原解析器的 15 组受控参数对照证明，单个 argv 的前导 ASCII 空格可排除 `%s` 读取的别名匹配，并保留数字解析；修复必须同时保护 RPDB 过滤与 FIB 目标，且不能因输出看似数字而跳过实际表身份核验。此反例属于宿主解析器与受控表映射验证，未修改系统或设备路由，也不等同于旧 Android run 的原始现场证据。

自动审查服务的结果单独记录：源码 PR 的 Sourcery 审查因七天差分配额不足未完成，Codex Security Review 也因账户用量上限失败；当前没有可行动的 inline 审查线程，不能把这些服务状态写成审查通过。已有 DNS PR 的两个审查线程依据原代码与固定核心处理；本轮代码继续通过独立复核及固定源码 CI 验证，没有更改账户额度或付费设置。

### 最终整合候选 8ff1242

当前源码为 `8ff1242817038dfe220a68b75934d6b127bea4b1`，tree `a23ade9034a47be945dc526f7fe5b00751267911`，主仓库 gitlink、README、依赖与来源记录均接入该固定点。三个增量提交分别为安装引导预算 `92b3fe62bc49902c540db2dfeb7ce9a6a16a493c`、就绪失败支持包 `7e497c3c978780f888572c2a4f5fbc16668da862`、Android 参数兼容与精确表 ID `8ff1242817038dfe220a68b75934d6b127bea4b1`。本地与远端 tree 已核对一致。

Android 固定调用 `/system/bin/ip` 并使用系统支持的参数。配置规则窗口和 redirect fallback 内的每条相关 lookup，包括数字外观输出，均须和无歧义目标数字表的过滤快照逐条对应；所有平台 FIB 使用同一无歧义表参数。无法证明的映射保持 unknown。每族最多三份快照，全部仍共享原三秒命令截止时间与每流 256 KiB 上限。原规则残片、连接子网和 FIB 覆盖判断保持。

就绪超时在失败收尾优先复用现有 `support export`，导出最多 20 秒、受限读取最多 4 秒，二者和原有诊断共享同一个 25 秒截止时间；固定路径、非链接、512 KiB 上限、精确 UTF-8 字节数与完整格式检查后才保存 `readiness-support.txt`。失败只记规范化回执，既有生产脱敏实现不变，原错误和就绪成功条件不变。安装引导拆分依赖步骤：npm 5 分钟、Chromium/系统依赖 20 分钟、BusyBox/字体 25 分钟；browser job 60 分钟，实际测试仍为 5 分钟。这些是明确预算，不把已成功的旧镜像延迟说成浏览器失败。

| 新增验证 | 结果与身份 |
| --- | --- |
| Android 命令兼容及数字表身份 | 宿主编译的固定 AOSP 原版 ip 的双栈 `-N` 均 exit255；原表解析器 15 组参数对照；生产观察器旧伪绿反例为 `[true,true]`，新结果为 `[unknown,false]`；Linux FIB 另有正反例 |
| 最终 Rust 实现 | 独立修复树 `9d7b68188ee7e15b1f5f6778a898703605084974`：CLI 841 passed / 1 ignored，含 TUN 19 项；根整合的 Cargo 文件、crates 和生产模块与此树逐字节相同 |
| 失败支持包 | `693b2e4c029f0d714ac225f67089124d570dea7e`：simulation 109 项通过，包括 7 个新增失败采集反例；与最终候选对应 Python 文件相同 |
| 整合静态检查 | 官方 source lint 823 个跟踪文本、Rust fmt、diff check 均通过；独立复核无剩余阻断；未重复声称本地有匹配 Clippy |

新候选七条工作流均已启动，attempt 1。完成后的结果及实际合并、Issue 状态将在此处补齐；旧失败和新验证保留各自身份。

| 最终候选工作流 | 当前结果 |
| --- | --- |
| [Code Quality 42218750003](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750003) | 运行中 |
| [Build Kam Module 42218750064](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750064) | 运行中 |
| [Network regression 42218749897](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218749897) | 成功；DNS NAT 与 offline 测试通过，按条件未运行公网 runner 观察 |
| [Rules Release Integration 42218750114](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750114) | 成功 |
| [Network Regression Evidence 42218749968](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218749968) | 运行中 |
| [Install Onboarding 42218750011](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750011) | 运行中 |
| [Android KernelSU Acceptance 42218750254](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42218750254) | 运行中 |

## 剩余验收

#436 需要在固定随包核心上取得网络切换前后实际 RPDB/FIB 和应用流量证据，区分 netd/OEM、核心和其他网络工具造成的变化。原报告使用官方 1.14.3 核心，不能直接等同于当前固定 fork。检测缺口的修复不会自动证明规则丢失原因已经修复。

#440 的可信 NAS/私网来源需要独立、显式启用的信任范围与逐跳校验设计。当前 HTTPS/公网订阅保护保持；没有通过全局放开 HTTP、私网或代理环境来宣称支持该能力。

## 结论与证据自检

| 自检维度 | 本记录要求 |
| --- | --- |
| 修改是否对应具体问题 | 每项关联原 Issue、实际代码路径及反例 |
| 说明是否清楚 | 分开描述配置意图、运行证据、历史记录和完整流量 |
| 实验是否支持结论 | 旧版失败与修复后通过逐项记录，主机替身不标为设备成功 |
| 覆盖是否完整 | CI 未完成、物理设备和 NAS 能力明确保留待验证/待实现 |
| 方法边界是否保持 | 未知归属继续保守，TLS 拒绝与隐私边界保持，无新增产品模式 |
