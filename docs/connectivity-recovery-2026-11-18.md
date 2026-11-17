# 当前代理联网检查与有界恢复验收

本轮修复针对“进程仍在运行，但当前所选代理无法完成请求”的故障。当前代理、mixed 入口和 Android 应用的实际流量是三个不同的证据范围；本报告分别记录，不用一个范围的成功替代另一个。目标发行版沿用 v1.9.0，公开稳定索引在正式发布完成前保持 v1.8.9 / 10617。

## 原因与修复合同

设备现场确认当前所选代理不可用，而其他已有代理可用。测试域名也可能被路由规则送往另一代理，因此只检查 mixed 入口或只看旧延迟 API，无法证明当前选择可用。既有指数退避还可能让用户切换到正常节点后继续看到旧失败。

核心新增可选 with_lx_probe。指定出站的严格接口以 HTTPS GET 验证 Google 和 Cloudflare 的真实 204，校验证书、禁止重定向，并返回 strict_probe、expected_status、ok 和真实 http_status。没有严格能力标记的旧响应不算成功。模块单独保存 mixed 数据面结果，所选代理与 mixed 结论不互相覆盖。旧 mixed online 缓存没有严格路径标记时按 unknown 处理并安排新检查，保留已有恢复冷却与次数，不能把旧成功冒充升级后的严格结果。

自动恢复最多尝试三个同组已有真实代理。候选双目标通过后，既有配置锁内重查成员与当前值，先 checked 保存，再运行时 PUT 和两侧读回，随后复验实际路径。保存失败不改运行态；后续失败补偿原运行值与原保存值，原缺省保持缺省。外部新选择不被覆盖，冲突和补偿失败如实报告；多个组是有补偿的顺序批次。

人工 cli connectivity check 只探测，10 秒节流；概览“检查网络”打开诊断页，既有 ping 工具不代表执行了该严格检查，普通 status、health、MCP 与导出继续读取缓存。人工检查和切换后复验不清空动作冷却、订阅刷新间隔或 TUN 恢复次数，未新增 --json 写操作。已有四项日常直达、概览折叠详情和核心退出后的自有资源清理继续保留。

## 固定源码与本地验证

最终源码 [4a001bd24f3e88772cfc829b29ecaae4c846c6fe](https://github.com/LIghtJUNction/magicnet-android/commit/4a001bd24f3e88772cfc829b29ecaae4c846c6fe) 已推送 main，tree 为 `299685efe7f0ea7da2836a6d13535b5b46f8bea9`，其中 sing-box gitlink 为 `3a155d21872b22e6b9b75326c98d11f7ff159a2e`。主仓源码 gitlink、两处 release workflow 引用、三语 README 与当前配方索引同步到该源码身份。

| 本地源码验证 | 实际结果 |
| --- | --- |
| CLI 验证 | 894 passed / 0 failed / 1 既有 ignored |
| connectivity runtime | 26 项通过 |
| selector 定向验证 | 10 项通过，属于相关子集，不累计总数 |
| 限定改动范围的 Clippy | all-targets、-D warnings 通过 |
| fmt、diff 检查 | 通过 |

这些结果证明注明范围的源码检查通过；完整工作区质量、正式构建和 Android/KernelSU 门禁仍由正式发布工作流验证，不将限定范围的 Clippy 写成整套质量门禁已通过。

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

## 正式发行的证据边界

正式发布仍由 [MagicNet release workflow](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml) 固定源码、执行完整质量与 Android/KernelSU 验收、核对全部 ZIP 和来源摘要，然后发布并同步稳定索引。主仓 gitlink、两处复用工作流 source ref、核心 pin 和配方闭包必须一致；完整 check-recipes 使用已提交 HEAD 的 gitlink。

旧版现场配置恢复、上述新核心隔离实验、候选界面回归及最终正式版本分别记录。已有旧源码的模拟器成功或本次物理设备局部验证，都不能代替新源码正式发布所需的质量和 Android 门禁。发布后的实际下载地址、产物摘要、workflow 和设备安装结果应以各自完成记录为准。
