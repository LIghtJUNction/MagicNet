# MagicNet Issue 与 PR 处理记录（2026-11-06）

## 范围与结论状态

用户授权直接合并并处理 Issue/PR。本记录追踪三个项目仓库的当前事项；源码候选仍在最终整合与门禁阶段，以下本地结果不能替代尚未完成的 CI 或物理设备验收。

此前 DNS 修复已经合并：[源码 PR #2](https://github.com/LIghtJUNction/magicnet-android/pull/2)、[模板 PR #21](https://github.com/LIghtJUNction/MagicSingBox/pull/21)、[主仓库 PR #441](https://github.com/LIghtJUNction/MagicNet/pull/441)。本轮核对时三仓库均无待合并 PR；主仓库有五个开放 Issue。两个尚未解决的 DNS 审查线程已补充依据并标记解决：保留用户显式解析器属于兼容边界；当前固定核心按 transport tag 隔离 DNS 缓存，不能套用旧版独立缓存开关的结论。

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

候选已按修复单元增量推送：安装与历史 `cacbb3456686d0b819650b079bfcfeec478cdd72`，TLS `ccbaada2feb108805e2d45654cf1df345d95cd5e`，监督恢复 `ef56af9a964f73cf0b5cb618492b9831850ee861`。独立启动恢复入口追加 `1439c08c2e454354d52db6a3700af8bb84b2104b`，旧代码在真实配置锁夹具内启动维护进程，修复后锁内只保留核心/策略事务，维护进程全部锁外恢复；这证明锁序缺口，不证明实际设备必然死锁。最终源码为 `39ba7487f187d44febaf573c3ba1faf3992e0797`，tree `4e16922735c22fc696c6dd73b6a44182e8635acb`，对应 [源码 PR #3](https://github.com/LIghtJUNction/magicnet-android/pull/3)，主仓库 gitlink 指向该提交。整合后官方 ShellCheck、823 个跟踪文本的 source lint 与 Rust fmt 通过。首次 PR 候选的 Android run [42211936356](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42211936356) 为 attempt 1，随后由仅修正文档证据边界的新提交替代；生产与测试代码未变。最新提交的最终门禁与合并结果将在完成后补齐。软件版本保持 1.8.5 / 10613，本次不创建正式 Release。

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
