# MagicNet v1.9.0 发布与联网恢复验收

**MagicNet v1.9.0 / 10618 已正式发布。** 发布于 UTC 2026-11-17 21:42:01，为公开稳定版；[正式运行 44175989691](https://github.com/LIghtJUNction/MagicNet/actions/runs/44175989691) 的构建、完整质量、Android、资产核验、发布与稳定索引同步均已通过。

- [下载完整离线包 MagicNet-full.zip](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.9.0/MagicNet-full.zip)：61,422,854 字节。
- [稳定发行页面](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.9.0)与[在线安装入口](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.9.0/magicnet_installer.zip)。
- [公开 SHA256SUMS](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.9.0/SHA256SUMS)与[本次公开资产复核原件](evidence/publication-verification-v1.9.0.json)。

完整包 SHA256 为 `239ce18c0f805735c29c896694c5827677c5b1de54b89a5e75920f0d32d878b4`。本次完成 SHA256 摘要、来源及归档内容核对，没有另行验证安装包数字签名。

**设备尚未安装新版完整模块。** UTC 21:44:31 的最终 ADB 复查正常退出但设备数为 0，本次没有将 v1.9.0 完整模块安装或暂存到手机；最后观测安装版本仍为 v1.8.9。此前已恢复旧模块配置并完成新核心隔离实验，正式完整包已下载到开发机且 SHA256 校验通过。

本轮修复针对“进程仍在运行，但当前所选代理无法完成请求”的故障。当前代理、mixed 入口和 Android 应用的实际流量是不同的证据范围；下文分别记录实现、失败尝试、成功复验、正式产物和设备边界。

## 原因与修复合同

设备现场确认当前所选代理不可用，而其他已有代理可用。测试域名也可能被路由规则送往另一代理，因此只检查 mixed 入口或只看旧延迟 API，无法证明当前选择可用。既有指数退避还可能让用户切换到正常节点后继续看到旧失败。

核心新增可选 with_lx_probe。指定出站的严格接口以 HTTPS GET 验证 Google 和 Cloudflare 的真实 204，校验证书、禁止重定向，并返回 strict_probe、expected_status、ok 和真实 http_status。没有严格能力标记的旧响应不算成功。模块单独保存 mixed 数据面结果，所选代理与 mixed 结论不互相覆盖。旧 mixed online 缓存没有严格路径标记时按 unknown 处理并安排新检查，保留已有恢复冷却与次数，不能把旧成功冒充升级后的严格结果。

自动恢复最多尝试三个同组已有真实代理。候选双目标通过后，既有配置锁内重查成员与当前值，先 checked 保存，再运行时 PUT 和两侧读回，随后复验实际路径。保存失败不改运行态；后续失败补偿原运行值与原保存值，原缺省保持缺省。外部新选择不被覆盖，冲突和补偿失败如实报告；多个组是有补偿的顺序批次。

人工 cli connectivity check 只探测，10 秒节流；概览“检查网络”打开诊断页，既有 ping 工具不代表执行了该严格检查，普通 status、health、MCP 与导出继续读取缓存。人工检查和切换后复验不清空动作冷却、订阅刷新间隔或 TUN 恢复次数，未新增 --json 写操作。已有四项日常直达、概览折叠详情和核心退出后的自有资源清理继续保留。

## 固定源码与本地验证

当前源码 [a25eb7cb8eb2697ec140e3a5877c9cfe4ccf392b](https://github.com/LIghtJUNction/magicnet-android/commit/a25eb7cb8eb2697ec140e3a5877c9cfe4ccf392b) 已签名提交并推送 main，tree 为 `c51a058235ec81f077468cc61f060bbdee7a83b9`，其中 sing-box gitlink 仍为 `3a155d21872b22e6b9b75326c98d11f7ff159a2e`。主仓源码 gitlink、两处 release workflow 引用、三语 README 与当前配方索引同步到该源码身份。

下表记录基线 [4a001bd24f3e88772cfc829b29ecaae4c846c6fe](https://github.com/LIghtJUNction/magicnet-android/commit/4a001bd24f3e88772cfc829b29ecaae4c846c6fe) 的 CLI 验证；a25eb7cb 追加的是六个 CI/验收文件的合同修正，其本地 120/37 项与实际核心配置验证单独记录在后文。

| 本地源码验证 | 实际结果 |
| --- | --- |
| CLI 验证 | 894 passed / 0 failed / 1 既有 ignored |
| connectivity runtime | 26 项通过 |
| selector 定向验证 | 10 项通过，属于相关子集，不累计总数 |
| 限定改动范围的 Clippy | all-targets、-D warnings 通过 |
| fmt、diff 检查 | 通过 |

这些结果证明注明范围的本地源码检查通过；后续源码 Code Quality 的实际 success 另见下方 CI 记录。正式构建内的强制质量检查和 Android/KernelSU 门禁仍须由最终发布工作流完成，不将限定范围的本地 Clippy 写成整套正式发布门禁已通过。

## 固定核心与实际设备证据

新核心固定为 [3a155d21872b22e6b9b75326c98d11f7ff159a2e](https://github.com/LIghtJUNction/sing-box/commit/3a155d21872b22e6b9b75326c98d11f7ff159a2e)，实际设备二进制版本为 `1.15.0-alpha.13+LIghtJUNction.3a155d21872b`。以下测试运行在设备上的隔离新核心进程，配置检查返回 0；已安装 v1.8.9 核心没有被替换。

| 实际检查 | 观察结果 | 能证明的范围 |
| --- | --- | --- |
| 所选出站严格 Google 204 | strict_probe=true、ok=true、http_status=204，delay=572 ms | 新核心按指定出站完成真实 HTTPS GET/204 |
| 所选出站严格 Cloudflare 204 | strict_probe=true、ok=true、http_status=204，delay=289 ms | 第二个独立目标通过相同严格接口 |
| Google 普通页面返回 HTTP 200 | ok=false、reason=http_status | 收到非 204 成功页面不会被误判为探测成功 |
| HTTP URL 请求严格模式 | API HTTP 400、reason=invalid_request | 严格接口拒绝不满足 HTTPS 合同的输入 |
| 现场此前失败的已有具体代理 | timeout | 成功目标或其他代理不会掩盖被指定代理的失败 |
| 非 root shell 经新核心 mixed 入口请求 Google | HTTP 204，0.328615 s | 新核心 mixed 路径实际传输成功 |

上述测试正常退出，临时测试进程、配置、端口和私密凭据均已清理。证据仅覆盖隔离核心与显式 mixed 请求；不表示新 CLI 的整条恢复流程、已安装新模块、所有应用 UID 或 TUN/eBPF 路径已经完成验收。真实节点名称、地址、认证信息和设备身份不进入本报告。

## 原始证据与本地主机回环验证

两份 JSON 已检查字段和内容，未发现节点地址、认证信息、订阅 URL、设备序列号或开发机绝对路径，按原始字节保存，复制后摘要一致。

| 原始记录 | 字节数 | SHA256 |
| --- | --- | --- |
| [设备隔离核心探测](evidence/connectivity-recovery-phone-core-2026-11-18.json) | 1,366 | `23ae51fa3d0f9db69e8145ae21941020f2f33dcae4638a0f50bc0ba1522d3f41` |
| [本地 Linux 回环转发](evidence/connectivity-recovery-host-2026-11-18.json) | 6,263 | `8af4113c716ca1368696cab8a003479872674dee53a70d07e2c3ca85c6fe0ae4` |

本地回环记录在 UTC 2026-11-17 20:47:33 生成，source HEAD 为 `4a001bd24f3e88772cfc829b29ecaae4c846c6fe`，另包含实验当时尚未提交的测试 harness 标签核对修补；它不是原始干净 4a 提交的 CI 结果。实际核心为 `3a155d21872b22e6b9b75326c98d11f7ff159a2e`，二进制 SHA256 为 `d5e63e590a8ea8a3f1c49fe80abcaaa228fbdb5c8e573a04b807ce6485dad896`，配置检查和生产标签精确核对通过。

该实验完成 77 次本机回环请求、20.0305 秒空闲观察，外网请求为 0，local_acceptance=passed。它验证此主机上的 HTTP/mixed 回环转发，未运行 Android TUN/eBPF 或无线链路；其中吞吐、CPU 和 RSS/PSS 采样仅作原始记录，不据此宣称 Android 公网速度或内存改善。

## a25 成功 Network CI 的原始回环证据

[Network Regression Evidence 44175291715](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291715) 已 completed/success，API 确认 head 为 a25eb7cb。其 `core-memory-evidence` artifact 为 `14369033231`，ZIP 共含 core-memory.json 与 host-forwarding.json；本节读取并公开后者，不把文件名当成 Android 内存测试结果。

| CI 原件 | 实际身份 |
| --- | --- |
| artifact ZIP | 6,462 字节；SHA256 `f0b614eaa7042d124a103b48823f5096042c3522efa2f2beae903b3782c445fc` |
| [host-forwarding.json 原始字节](evidence/connectivity-recovery-host-ci-44175291715.json) | 6,267 字节；SHA256 `c131d86f41be6467858e790ed376068626c861a4f8634b1269fba79470fb5748` |
| source / core | `a25eb7cb8eb2697ec140e3a5877c9cfe4ccf392b` / `3a155d21872b22e6b9b75326c98d11f7ff159a2e` |
| 实际 host 核心二进制 | Go 1.26.7、linux/amd64；SHA256 `27aef7fef346dc99d2cd34e40c5a6b6aa687402cb924ed0373670bfb2a8e64da` |

记录生成于 UTC 2026-11-17 21:05:44，配置检查、完整生产标签集合核验与 local_acceptance 均 passed，标签明确包含 with_lx_probe。实际完成 77 次本机回环请求、20.0324 秒空闲观察，外网请求为 0，Google once 为 not_requested。文件字段与内容经隐私检查，无节点地址、认证信息、订阅 URL、设备身份或开发机绝对路径，原字节复制后摘要一致。

此结果来自 a25 的真实 GitHub Linux runner，与前述 4a HEAD 加未提交 harness 修补的开发机实验分开保存。两者都未测 Android TUN/eBPF 或无线链路，不据回环吞吐、CPU 或 RSS/PSS 数值推断 Android 公网速度和内存改善，也不替代正式 Android 验收。

## 界面与配方验证

界面提交 [fa77ab10e3c7e6ca6ecf4af14dda45aa46f57d1b](https://github.com/LIghtJUNction/magicnet-android/commit/fa77ab10e3c7e6ca6ecf4af14dda45aa46f57d1b) 位于最终源码的父提交历史中。该界面完成 391 项 npm 测试，类型检查与构建通过；360 像素手机和桌面布局的 8 项 Playwright 检查通过，截图经视觉核查。此处按实际提交记录，不与上一轮界面测试数量相加。

| 本轮独立验证 | 结果 |
| --- | --- |
| `python3 scripts/test-release.py` | 18 项通过 |
| `python3 scripts/test-release-plan.py` | 42 项通过 |
| `python3 scripts/test-check-recipes.py` | 19 项通过 |
| `bash scripts/check-workflows.sh` | 固定 actionlint 1.7.12 通过 |
| source 的 `bash -n scripts/build-sing-box.sh` | 通过；MagicNet 显式加入 with_lx_probe |

配方版本更新为 magicnet 0.3.28、network-runtime 0.1.16、control-plane 0.2.12、packet-engine 0.2.4 和 module-delivery 0.2.13，保留 web-console 0.2.10。新增 M75–M77、CON-A11–A14 和 C-CON-001–003 覆盖严格能力、路径独立、候选上限、保存失败、补偿冲突、人工检查与预算保留。上述测试验证发布基础设施和已注明的候选部分，不代表新的正式产物已经构建或发布。

## 首次 CI 与发布尝试

以下结果属于 source `4a001bd24f3e88772cfc829b29ecaae4c846c6fe` 和本次首次发布尝试；后续修补与新的完整验证须另行绑定提交和运行编号。

| 运行 | 实际结果与范围 |
| --- | --- |
| [Code Quality 44170188714](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44170188714) | success；源码质量工作流通过 |
| [Network Regression Evidence 44170188784](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44170188784) | failed；benchmark 的预检预期标签集合遗漏生产构建新增的 with_lx_probe，尚未进入实际转发实验；该运行未上传 runner JSON |
| [Android KernelSU Acceptance 44170189095](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44170189095) | failed；3 项 passed，cold-boot 以 `RuntimeError: invalid connectivity target or path` 失败，后续 9 项 not_run；不能记为 Android 网络或 TUN 验收通过 |
| [正式发布 44171252511](https://github.com/LIghtJUNction/MagicNet/actions/runs/44171252511) | 在 publish 前取消；未发布新版本，公开稳定索引仍为 v1.8.9 / 10617 |

首次正式运行的计划版本为 v1.9.0 / 10618，配方发布快照为 [82054c099e4fcf81fc069c27327ca62e93ea25ee](https://github.com/LIghtJUNction/MagicNet/commit/82054c099e4fcf81fc069c27327ca62e93ea25ee)。取消的计划和快照不构成已发行版本。

Network Evidence 的本地修补保留严格标签集合检查，纳入生产 with_lx_probe 并增加四个正反对照夹具；上传步骤也补为失败时保留证据。本页上述本地 77 请求结果使用当时尚未提交的 harness 修补，不能改写旧 CI 的 failed 状态。Android 的已确认失败点是产品 connectivity 目标/路径合同校验；下节记录验收器与夹具修补的本地结果及 a25 源码 CI 的后续成功；此前 TLS 控制成功不改写旧 4a 整体失败，正式发行运行仍单独验证。

Android 失败原件来自 artifact `14368621858`：归档 SHA256 为 `1a2491d3888175dc5a716a372b9b91ecb1f66634c069eb1575add360a8317d17`，simulation.json SHA256 为 `870c04f99757b41503590520257c769b1f152b5e4f1eca9b5a1cd08c93f2ccc2`。实际报告绑定的 production ZIP 摘要为 `4ac3ff3613388bd3575b0df6b8cada6034f5a989fabe0a2b95eac14d2764f6c8`，fixture ZIP 为 `454501d05b6ea482d974ffa2a26b575bd49d54f74ffe9fcb5be12ddc75b0d85f`；这些产物身份不是正式发行成功证明。

## CI 合同修正与本地复验

本轮 Android 修补将验收器与当前产品的 selected/mixed 状态合同同步。`scripts/android-device-simulation.py` 校验 `path=selected_proxy` 和独立 `mixed_path=mixed_proxy`，保留 mixed_status、mixed_reason、unknown 和 failover 结果。online 必须同时具备真实 204、有效检查时间和延迟、已执行探测、primary reason=ok、secondary online、mixed online/ok、warning=false 与连续失败数为 0；缺字段、旧 mixed 主路径或不完整的成功证据均拒绝。

一次性 Android 隔离夹具新增单成员 `proxy → direct` selector，使当前选择器接口有可校验的目标；本地 DNS 与 route.final=direct 保持。该配置属于测试夹具，不代表真实代理服务器已通过，也不改变生产候选恢复对同组真实代理的限制。产品观察仍至多调用一次显式 tick，Google 请求上界为 2（selected 与 mixed 各一路），辅助请求上界为 2；验收器不改 canonical 状态来制造到期或成功。

配套修补位于 `scripts/test-android-device-simulation.py` 和 `scripts/test-android-simulation-fixes.py`。正反例覆盖 selected 成功但 mixed 失败、严格能力不可用、0 ms 合法延迟、旧路径/缺字段/坏枚举，以及 online 证据不完整时拒绝。升级夹具中热点 selector 的已有允许列表也同步包含新增的 proxy 成员。

| 本地复验命令 | 实际结果与范围 |
| --- | --- |
| `python3 scripts/test-android-device-simulation.py` | 120/120 passed；harness 与状态合同回归 |
| `python3 scripts/test-android-simulation-fixes.py` | 37/37 passed；隔离夹具、升级与恢复合同回归 |
| 两条命令分别追加 `--check-core <pinned-host-core>` | 均 exit 0；使用实际生产标签核心 3a155d21 验证初始、升级与实际 renderer 生成候选的配置 |

这些是本地 fixture、单元和实际核心配置校验；带 --check-core 的复跑不与前述数量重复累计。a25 对应的真实 Android/KernelSU 源码 CI 现已 completed/success，其结果在下表单独记录。旧 4a 运行的 failed/not_run 和原始摘要保持，不能由本地或后续提交的成功改写。

上述修补现已固定到 `a25eb7cb8eb2697ec140e3a5877c9cfe4ccf392b`，tree 为 `c51a058235ec81f077468cc61f060bbdee7a83b9`，并推送 main；当前配方 pins 已同步，核心保持 3a155d21。新源码的四项 source CI 与正式发布复验均已 completed/success，公开稳定版已更新为 v1.9.0 / 10618；旧 4a 的失败记录和 host 原始 source_commit 保持原值。

以下四项源码运行已逐一确认 head=a25eb7cb，均为 completed/success。Network 的原件已在上文核验；源码 CI 成功与后续正式发行的独立质量、Android、资产及发布门禁分别记录。

| a25 源码运行 | 记录时状态 |
| --- | --- |
| [Code Quality 44175291769](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291769) | completed / success |
| [Network Evidence 44175291715](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291715) | completed / success |
| [Build 44175291680](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291680) | completed / success |
| [Android 44175291684](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291684) | completed / success |

## 正式发布运行与不可变身份

[正式发布 44175989691](https://github.com/LIghtJUNction/MagicNet/actions/runs/44175989691) 已 completed/success。Plan publication、计划选择、构建内完整质量、Android、资产核验、publish 与稳定索引同步全部成功；以下保留本次实际使用的不可变身份。

| 字段 | 已确认值 |
| --- | --- |
| workflow head | `97d455630f1221b98e79ed4021950a61473fb1f8` |
| 目标版本 / code | v1.9.0 / 10618 |
| source | `a25eb7cb8eb2697ec140e3a5877c9cfe4ccf392b` |
| 不可变配方快照 | [fa411b5cd94fd899eb6a21eed3e2f1329a0bc3c8](https://github.com/LIghtJUNction/MagicNet/commit/fa411b5cd94fd899eb6a21eed3e2f1329a0bc3c8)，ref `release/run-44175989691` |
| plan artifact | `14369367796`，`magicnet-plan-44175989691-1`；ZIP SHA256 `6d8391d31ca29162d4180a4af307280ea0461b7980a250ee7a7af45ee8bce168` |

本次正式运行的 Simulation harness contracts、真实 Android 15 / KernelSU / x86_64、build 与 Release quality gate 均 success；质量 gate 在 UTC 21:40:24 完成。资产核验和发布随后成功，Release ID 为 449231749，target 为上述 fa411b5c 快照，非 draft、非 prerelease，共 20 项公开资产。发布于 UTC 21:42:01，整个运行于 21:42:12 完成；sync-index 已将 main 推进 `75217e7319410276a8bbf588c6e1b1ac0c4aa008`，稳定版本和源码 gitlink 均已核对。

## 正式 Android 原件与联网边界

正式运行的 Android job `134368411160` 和 gate `134384381651` 均 success。artifact `14373200008` 的 [simulation 原始 JSON](evidence/connectivity-recovery-android-formal-44175989691.json) 为 90,160 字节，SHA256 为 `8bfcb50483b160cb736c3cad5fa1fb53bdd0ca8b799bf9bed490318600eea8ff`；原 ZIP SHA256 为 `e6eb2b2b0b5cfa8a191931eee7002a3fa87ac5d621844238aec6dc7f0cca7bfe`。原件经内容检查，仅含受控 AVD、测试网络和公共目标证据，无真实节点凭据或物理设备身份，复制后原字节摘要一致。

simulation 绑定 source=a25，13 cases 全部 passed，failed 与 not_run 均为 0。通过范围包括安装/冷启动、应用 UID 的 TUN 正反控制、RPDB 缺失与上联重连后的恢复、无效配置回滚、停止清理、重复重启、升级保留、停用/启用重启及卸载。版本证据来自同一 artifact 的 diagnostic-export `[platform and versions]` 节：`version=v1.9.0`、`versionCode=10618`；该诊断原件 SHA256 为 `94f15f13081f9f77617e261e2ab49399507257a012f2d2a45b7c9c3ce5f1ec61`。simulation 本身没有产品 version 字段，不能将版本来源混写。

| 正式 AVD 的实际联网观察 | 原件中的值 |
| --- | --- |
| Google HTTPS 204 | `google_https_204_observed=false` |
| 当前所选路径 | `status=offline`，`reason=upstream_unavailable`，`primary_reason=transport_failure` |
| mixed 数据面 | `mixed_status=failed`，`mixed_reason=tls_failure` |
| 显式产品探测 | 1 次 tick；Google 上界 2、辅助上界 2 |
| harness 状态写入 | `canonical_state_modified_by_harness=false` |

该门禁证明受控 Android 生命周期、TUN 故障注入/恢复和回滚合同通过，没有证明 AVD 中公网代理可用。真实 Google/Cloudflare 204 的证据来自此前物理手机上的新核心隔离实验，两种环境不能互换结论。原件明确未测试 ARM64 执行、OEM 内核、stock-kernel KernelSU LKM 注入、Play/GMS 登录下载、公网代理质量、eBPF 数据面、IPv6 转发、eCapture 执行和 proxylink 订阅解析。

Android gate 使用的 production ZIP SHA256 为 `f6e846af2adc1ae2b0810ff13caf346c0785fd89be32cd34cd7465c5b7348897`，fixture ZIP 为 `681a2f4212adf135c396f2e96bd60c6e17bd0adb7600ad97c3f7905a5153d20d`。这两个摘要属于 Android job 的输入与测试夹具；最终公开 MagicNet-full.zip 的摘要是下节的 `239ce18c…878b4`。

## 公开资产复核与设备交付范围

[公开资产复核原件](evidence/publication-verification-v1.9.0.json) 为 1,362 字节，SHA256 `579c46e300341a46b4504e7207d4808772c14b1f021b6e9288e625ac33f817c3`，status=passed。已公开 20 项资产，公开资产摘要与 SHA256SUMS 的一致性检查通过；独立下载了 7 项，其中完整 ZIP 的字节摘要、CRC、manifest 和 module.prop 版本/code 均核验通过。source=a25、core=3a、recipe/tag=fa411、main gitlink 和稳定索引相符；Release body 的验收报告绝对链接已回读确认，不再使用相对地址。

| 最终公开包 | 字节数 | SHA256 |
| --- | --- | --- |
| [MagicNet-full.zip](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.9.0/MagicNet-full.zip) | 61,422,854 | `239ce18c0f805735c29c896694c5827677c5b1de54b89a5e75920f0d32d878b4` |
| [magicnet_installer.zip](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.9.0/magicnet_installer.zip) | 3,466,036 | `2c868235d70c000cbd393fa384bb5970f050bf90530e0d98eee725a513572538` |

最终物理手机复查发生在 UTC 2026-11-17 21:44:31：`adb devices` exit 0，但 device_count=0。此前旧模块配置恢复和新核心隔离实验完成；最后安装版本观测为 v1.8.9。本次未安装或暂存 v1.9.0 完整模块到手机。已下载到开发机的正式完整包通过 SHA256 摘要校验；本报告没有声称验证安装包数字签名。

## 正式发行的证据边界

本次 [MagicNet release workflow](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) 已完成固定源码构建、完整质量与 Android/KernelSU 验收、资产与来源核验、公开发布及稳定索引同步。主仓 gitlink、两处复用工作流 source ref、核心 pin 和配方闭包对应同一受测版本；后续配方检查继续使用已提交 HEAD 的 gitlink。

旧版现场配置恢复、真机新核心隔离实验、主机回环、正式 AVD 生命周期与最终公开产物分别有对应证据。完整正式包已经发布和校验；设备在最终检查时未连接，因此没有新版完整模块的安装结果。旧失败记录保持原貌，成功范围不扩大到未测试的设备、协议路径或长期公网质量。
