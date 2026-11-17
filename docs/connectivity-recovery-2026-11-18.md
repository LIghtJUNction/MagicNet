# 当前代理联网检查与有界恢复验收

本轮修复针对“进程仍在运行，但当前所选代理无法完成请求”的故障。当前代理、mixed 入口和 Android 应用的实际流量是三个不同的证据范围；本报告分别记录，不用一个范围的成功替代另一个。目标发行版沿用 v1.9.0，公开稳定索引在正式发布完成前保持 v1.8.9 / 10617。

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

本地回环记录在 UTC 2026-11-17 20:47:33 生成，source HEAD 为 `4a001bd24f3e88772cfc829b29ecaae4c846c6fe`，另包含尚未提交的测试 harness 标签核对修补；它不是原始干净 4a 提交的 CI 结果。实际核心为 `3a155d21872b22e6b9b75326c98d11f7ff159a2e`，二进制 SHA256 为 `d5e63e590a8ea8a3f1c49fe80abcaaa228fbdb5c8e573a04b807ce6485dad896`，配置检查和生产标签精确核对通过。

该实验完成 77 次本机回环请求、20.0305 秒空闲观察，外网请求为 0，local_acceptance=passed。它验证此主机上的 HTTP/mixed 回环转发，未运行 Android TUN/eBPF 或无线链路；其中吞吐、CPU 和 RSS/PSS 采样仅作原始记录，不据此宣称 Android 公网速度或内存改善。

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

Network Evidence 的本地修补保留严格标签集合检查，纳入生产 with_lx_probe 并增加四个正反对照夹具；上传步骤也补为失败时保留证据。本页上述本地 77 请求结果使用当时尚未提交的 harness 修补，不能改写旧 CI 的 failed 状态。Android 的已确认失败点是产品 connectivity 目标/路径合同校验；下节记录验收器与夹具修补的本地结果，新的真实 Android CI 尚待完成，此前 TLS 控制成功不替代整个阶段通过。

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

这些是本地 fixture、单元和实际核心配置校验；带 --check-core 的复跑不与前述数量重复累计。实际 Android/KernelSU 启动、应用 UID 流量、TUN 故障恢复和生命周期仍须由新源码对应的 CI 完整通过。旧 4a 运行的 failed/not_run 和原始摘要保持，不能由本地通过改写。

上述修补现已固定到 `a25eb7cb8eb2697ec140e3a5877c9cfe4ccf392b`，tree 为 `c51a058235ec81f077468cc61f060bbdee7a83b9`，并推送 main；当前配方 pins 已同步，核心保持 3a155d21，公开稳定版保持 v1.8.9 / 10617。新源码对应的真实 Android 与正式发布复验结果仍待完成，旧 4a 的失败记录和 host 原始 source_commit 保持原值。

记录时，以下新运行均已确认 head=a25eb7cb，状态为 in_progress；运行启动不表示验证通过。

| a25 源码运行 | 记录时状态 |
| --- | --- |
| [Code Quality 44175291769](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291769) | in_progress |
| [Network Evidence 44175291715](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291715) | in_progress |
| [Build 44175291680](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291680) | in_progress |
| [Android 44175291684](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44175291684) | in_progress |

## 正式发行的证据边界

正式发布仍由 [MagicNet release workflow](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) 固定源码、执行完整质量与 Android/KernelSU 验收、核对全部 ZIP 和来源摘要，然后发布并同步稳定索引。主仓 gitlink、两处复用工作流 source ref、核心 pin 和配方闭包必须一致；完整 check-recipes 使用已提交 HEAD 的 gitlink。

旧版现场配置恢复、上述新核心隔离实验、候选界面回归及最终正式版本分别记录。已有旧源码的模拟器成功或本次物理设备局部验证，都不能代替新源码正式发布所需的质量和 Android 门禁。发布后的实际下载地址、产物摘要、workflow 和设备安装结果应以各自完成记录为准。
