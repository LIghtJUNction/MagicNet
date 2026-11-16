# 实现与发行验证

本页保留可定位的结果与限制。历史结果只适用于各自提交、产物和环境；完整过程保存在[精简前的固定记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/recipes/magicnet/VERIFICATION.md)。

## 当前索引

| 对象 | 事实源 |
| --- | --- |
| 维护源码 | `ee1a83fc0545d88966b3265c4c10481d926b01bc`；依赖身份见 [DEPENDENCIES.md](DEPENDENCIES.md) |
| 稳定发行索引 | 根 `update.json` 与 [README](../../README.md)：v1.8.7 / 10615 |
| 配方 | 0.3.25，八包；验收 M01–M71 见 [ACCEPTANCE.md](ACCEPTANCE.md) |
| 最近完整发布 | 2026-11-11，[42982936016](https://github.com/LIghtJUNction/MagicNet/actions/runs/42982936016)，v1.8.7 / 10615；构建、完整质量、Android 全部 13 阶段、资产核验与公开发布通过 |
| 当前完成与开放项 | 本轮 API/路由修复和复现证据已进入源码 main；Rust 34、Python 41 项定向测试与 ARM64 构建通过，手机 GC 四阶段短测与最终就绪检查通过。公网提速未证明；长期续航、全应用覆盖、真实 NAS、换网及升级安装仍需各自证据。历史全面检查与正式发行结果按原身份保留。 |

## 2026-11-16：内存、路由与网络实机调优

实施源码 `be00fa78f2e26a4d6998eb64e181de4028056aff` 修复原生 HTTP 调用方预算和等价路由归一化；证据及复现工具提交 `ee1a83fc0545d88966b3265c4c10481d926b01bc`，tree `abf0914411ac6d3e8d22b1e7464f001f868ed0fe`。本轮新增 M71 与对应 control/policy 验收，逐次数据、失败和限制见[实机调优报告](https://github.com/LIghtJUNction/magicnet-android/blob/ee1a83fc0545d88966b3265c4c10481d926b01bc/docs/performance/2026-11-16-memory-routing-network.md)。

本地 Rust local_http 10、WebUI API 24 项通过；Python modern routing 26、optimizer 11、template 4 项通过，另有维护路由结构/mDNS/8 组 DNS/Tailnet 合同脚本通过。ARM64 release CLI 构建成功，安装到 PHK110 / Android 16 的模块后能力接口一致、状态与流量采样有效。新 CLI SHA-256 为 `0bf0bde5b691809e55461cf83f41eaad8426da40ae64e4d23afb7b66960a2d54`，旧文件已备份并核验。没有生成或公开后继正式安装包，稳定发行仍为 v1.8.7 / 10615。

HTTP 预算基准初测和独立复跑各 28 个预期拒绝样本；请求峰值堆复现为有长度 8,388,842→8,467 B、无长度 8,388,842→1,048,851 B。设备 GC 默认/50/默认/50 四段均完成两次国内下载；PSS+SwapPss 为 104,068 / 86,193 / 108,537 / 83,647 KiB。回滚到默认在 A2 实测，B2 再验证后仅保留本设备 gc_percent=50；configured/active revision 同为 3，无 pending，非 GC 配置完全相同。

最终核心/TUN/API 就绪，联网检查 HTTP 204，fswatch 运行；测试 APK 和本轮设备暂存文件已清理。实机原 route/DNS 为 63/27，新归一化与其相同；旧优化器会额外插入一条规则。公网观察两轮成功 14/15、13/15，海外超时保留，没有公网整体提速结论。首个重启返回失败但未保存 stderr，原因未知，不能用后续重启成功掩盖。长期续航、全应用覆盖、UDP/QUIC 吞吐和升级安装仍不在这次短测结论内。

主仓库本地 check、pack、归档 check、完整 build 提示词生成及固定引用回归检查通过。归档门禁原始摘要：`Recipe archive and complete prompt verified: 8 packages, 62 Markdown files; live pin ee1a83fc0545d88966b3265c4c10481d926b01bc / v1.8.7 10615`。

## 2026-11-15：全面故障检查与运行时修复

固定源码为 [`b6f3a37f`](https://github.com/LIghtJUNction/magicnet-android/commit/b6f3a37fb5d035105917f844a6a23bb499bc1a61)，tree `d76352da5d50870b038da8dd401f45d1fcebeb53`。七个增量提交修复 Wi-Fi 退出状态、connectivity 停止竞态、重复 Wi-Fi watcher、协议表单隐藏凭据、测速参数重置、TUN 冲突假绿、配置元数据部分提交和卸载中断后跳过清理。

各缺陷都有旧行为失败、新行为通过的定向复现。独立交叉审阅补上配置验证目录与事务目标目录的设备号/inode 核验；现有文件事务负责预检、替换失败回滚，提交后的暂存清理仍可能报错，此时不能把错误解释为配置已回滚。补充交叉审阅收紧候选与旧配置的 8 MiB 读取边界；恰限备份与超限零目标写入回归通过。

| 本轮已完成检查 | 结果 |
| --- | --- |
| Rust workspace 全套 | 938 passed，0 failed，1 ignored；870 单元 + 68 集成。原有 ignored 项需要独立 AOSP Android-profile mksh 夹具。 |
| 配置编辑 / TUN / 共用事务 | 28 / 22 / 9 项通过，已包含在 Rust 总数内。 |
| WebUI | 392 项 Node 测试、类型检查与生产构建通过。源码 `76b0b069` 的完整六 viewport Playwright 流程已在 CI 实跑通过（453.61 秒）；本地 Chromium 启动受 socket 权限限制。 |
| 安装与下载组件 | Go 格式、vet、race 测试及 components 质量闸全部通过。 |
| 卸载 | BusyBox 真实进程、锁、timeout/httpd 18 项通过；整个卸载尝试被终止后可重试，并发保持单一清理者。 |
| 主机综合回归 | 114 个唯一顶层任务取得通过：首跑 104 项，固定子模块与解释器环境修正后补测 10 项；中断日志保留，未放宽检查。 |
| 主仓配方与发行脚本 | 最终源码固定值的 8 包 / 62 Markdown check、pack、归档检查和完整提示词生成通过；78 项发布与配方回归通过。 |
| 静态检查 | 严格 Clippy、Rust 格式、全 ShellCheck、工作流 actionlint 与 diff 检查通过。 |

本轮修改继续使用既有锁、事务和 schema=1 接口，没有增加运行依赖。设备尚未连接；物理设备换网、Root 管理器实际升级/卸载与真实联网效果仍需对应设备证据。稳定发布索引与历史产物保持各自身份。

最终源码的规则集成和 Network Regression Evidence 已通过，Code Quality、完整构建和 Android 模拟器验收在 2026-11-15 15:34:57 UTC 的回读中仍运行；[完整运行链接及提交归属](../../docs/comprehensive-audit-2026-11-15.md)按实际状态记录。前一提交 `76b0b069` 的 Code Quality、源码构建、网络和卸载检查均已通过，不替代最终提交的未完成工作流。

## 2026-11-15：配置、分流与发行候选

源码 `4b02897dffd6acd455c0e25849b46398ca1465b6`，tree `ced91db63d6e301dbcda75d7220a6fb829b8e132`，包含五次增量提交：窄屏标签、配置/规则固定值、分流顺序、正常化回归与授权范围说明、浏览器任务固定 Ubuntu 24.04。模板固定 `da3d375d024e0982265bc67c48a87de7bb4f9424`；其 [PR #22](https://github.com/LIghtJUNction/MagicSingBox/pull/22) 已合入，合并提交 `f9c8495f3ad73d8297fc24eff95970ec8de0e20d`。

源码 [PR #10](https://github.com/LIghtJUNction/magicnet-android/pull/10) 已 squash 合并为 `af72e0435c56bdebc724f2c93c2f775624f010f3`，tree 与上述受测源码相同。主仓受测 head 为 `05946c51baf7e4d9301e2b76cde25cc6221f13ed`，[PR #456](https://github.com/LIghtJUNction/MagicNet/pull/456) 已 squash 合并为 `f6c808ed7f66276c398d4b3e5d9f7108d80ed7ae`，两者 tree 均为 `3a3b52b1d07fbf29b100139e07cfa044e6344751`。活动源码固定值使用已合并的 `af72e043`，历史测试与产物继续保留原始 `4b02897` 身份。

手动 Build [43706037821](https://github.com/LIghtJUNction/MagicNet/actions/runs/43706037821) 在启动阶段报告 `exec.yml@4b02897` 的 `workflow was not found`，未创建构建 job。源码 PR squash 合并并删除分支后，旧 head 未进入 main 历史；主仓已将 gitlink、两个可复用工作流、BUILD_PROMPT、DEPENDENCIES 与三语 README 的活动固定值统一更新到 `af72e043`。两个源码提交的 tree 均为 `ced91db63d6e301dbcda75d7220a6fb829b8e132`。

修复提交 [fdf064f9](https://github.com/LIghtJUNction/MagicNet/commit/fdf064f9ae40065e0e1f2c8ac11ed024fa44cf30) 的 [Recipe checks 43726001521](https://github.com/LIghtJUNction/MagicNet/actions/runs/43726001521) 已成功；本地 78 项发布与固定值回归、工作流语法及八包归档检查通过。新固定源码 `af72e043` 的既有 [Build 43704717207](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43704717207)、[Code Quality 43704717198](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43704717198) 与 [Android 43704717178](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43704717178) 均成功。主仓修复后的完整 Build 尚未新建，当前连接缺少手动触发入口与浏览器登录；结果和新建运行方式见 [Build CI 修复记录](../../docs/ci-build-fix-2026-11-15.md)。

| 范围 | 当前证据 |
| --- | --- |
| 默认模板 | 生成一致性、DNS 引用与全部 37 项模板测试通过；[CI 43686539387](https://github.com/LIghtJUNction/MagicSingBox/actions/runs/43686539387) 成功。config SHA-256 为 `fe741b83040191dfeca2543c6bd630d92b06a3e6e373506a2ee32cc87fc8c9b8`。 |
| 正常化 | routing-template 4、routing-optimizer 11、routing-modern 18 项通过；完整输入不变、正常化幂等和受保护 DNS 前缀原序保持。首轮 [Rules Release Integration 43686759048](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43686759048) 在 `c86b6540` 因旧测试固定 lmm 为 DNS 第一条失败；当前修订要求 mDNS 第一且 lmm 仍先于两个模式规则，不删除原业务断言；`45154757` 的 [Rules Release Integration 43687107244](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687107244) 已成功，真实规则下载与配置匹配检查通过。 |
| 分流顺序 | 11 项真实物化回归通过，包括应用/域名/广告全部六种顺序、原数组保真及幂等；resolve/route-options 单独及连续的 18 个组合通过。旧基线能复现业务路由提升和域名规则早于 sniff 的失败；补保护前，新准备动作用例的六种顺序均失败。 |
| 相邻运行逻辑 | app policy failure 12 项，以及 app-routing、route-apply、ad-routing、block-apply、action-routing、hotspot-routing 的定向脚本通过；原子发布失败与缺少必要 sniff 保留旧配置。 |
| 模板升级 | template-pin、repository-migration、install-refresh 通过；install-template 为 20 passed / 2 skipped（宿主缺 BusyBox，真实核心为 CI opt-in）。精确旧官方 pin 迁移，自定义 digest 保留、结果权限 0600、重复迁移幂等。 |
| DNS 物化与规则资产 | 4 个 profile × 启停 Tailscale 的 8 个组合保留原生 mDNS；bundled-rules 20 项通过。固定发行 `rules-20261115-585094101194f32e` 的归档摘要、安全展开及 116 个规则集清单逐项核验通过；manifest 摘要见 DEPENDENCIES。 |
| WebUI | 窄屏状态允许断行，新增实际节点边界断言；17 项定向单元检查、类型与语法检查通过。当前源码的完整 [webui job 132731989716](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811840/job/132731989716) 与 [visual-evidence job 132731874303](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811750/job/132731874303) 均成功。 |
| 源码完整 CI | `4b02897` 的 [Code Quality 43687811840](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811840)、[构建 43687811755](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811755)、[Android 43687811768](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811768) 均成功。 |
| 核心、网络与安装 | [Network regression 43687811763](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811763)、[Rules Release Integration 43687811856](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811856)、[Install Onboarding 43687811766](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811766) 与 [Network Regression Evidence 43687811750](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811750) 均成功；后者的 core-evidence、avd-storage 与 visual-evidence 三项均通过。 |
| 配方与发行验证器 | 配方 check、pack、归档 check 与完整 build 提示词通过（8 包、62 Markdown）；候选固定值回归 17 项通过；主分支 `00913ab1` 增补后为 19 项，README 校验排除 HTML 注释与围栏代码示例，同时保留有效字段旁的历史示例，三语均有正反例。发行验证器新增设备授权文件检查，18 项资产验证与 41 项发布计划回归通过；24 个重算摘要的污染包被拒绝，21 个相似路径正例保留。受测 head 的 [Recipe checks 43687915177](https://github.com/LIghtJUNction/MagicNet/actions/runs/43687915177) 及合并后的 [43704522152](https://github.com/LIghtJUNction/MagicNet/actions/runs/43704522152) 均成功。 |
| 主仓整包验收 | `05946c5` 的 [发布预览 43687915429](https://github.com/LIghtJUNction/MagicNet/actions/runs/43687915429) 成功：[构建 132732328718](https://github.com/LIghtJUNction/MagicNet/actions/runs/43687915429/job/132732328718)、[Android 132732532426](https://github.com/LIghtJUNction/MagicNet/actions/runs/43687915429/job/132732532426) 与 [最终资产 132742190425](https://github.com/LIghtJUNction/MagicNet/actions/runs/43687915429/job/132742190425) 均通过；publish 在 PR 运行中按设计 skipped。 |
| 正式发行 | 尚未触发 `main` 上 `mode=publish` 的正式 `workflow_dispatch`。目标 v1.8.8 / 10616 尚未公开，稳定索引保持 v1.8.7 / 10615。 |

构建 [artifact 14151988397](https://github.com/LIghtJUNction/MagicNet/actions/runs/43687915429/artifacts/14151988397) 下载后为 143,249,411 字节，SHA-256 为 `7d07a8a5ac0755c8559f2c3096ce60a0f13a7edfe5a7dcb9f56cc9a7e247be6d`，与 GitHub digest 一致。计划 artifact `14150773327` 的摘要为 `fbc8a479cbc57aef7699861d1a81e35efb6d6753924599469dc7f5dbab74db6c`，同样匹配。

在真实配方合成提交 `48dd2a3830fa857c774415fc8eba838ccd83ff4c` 的独立检出中，使用本轮 `scripts/release.py` 对原始计划与解压产物复验，exit 0：source=`4b02897`，预览版本 v1.8.8 / 10616，20 个文件（19 项摘要资产与 `SHA256SUMS`）、10 个组件均通过。三个核心别名均为 3,465,406 字节，SHA-256 同为 `3971510a8a0501b9967afff124d0604a14a43bf997d98113863f70904ba42ae3`。此结果是 CI 候选验证，不是公开 Release；正式发布仍需运行既有发布门禁。

两份 Android 原始 ZIP 下载后独立计算的摘要均与 GitHub digest 一致。使用从 `4b02897` Git 对象提取的原 `require-android-acceptance.py`，分别按报告实际 source SHA 复验，均为 exit 0；各 13/13 阶段、5/5 次重启通过。

| 原始 Android 证据 | 报告身份与归档摘要 |
| --- | --- |
| [源码 artifact 14151946799](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687811768/artifacts/14151946799) | 实际 source 为 PR 合成提交 `39245f16a2044ca2eb5ce614225043f6dced4522`，tree 与 `4b02897` 相同。ZIP 为 534,239 字节，SHA-256 `77bd8fd91acbf5271a5fbe4662647ae0278034f86b12132a6db1bef5f3113d49`。 |
| [主仓 artifact 14152285982](https://github.com/LIghtJUNction/MagicNet/actions/runs/43687915429/artifacts/14152285982) | 实际 source 为 `4b02897dffd6acd455c0e25849b46398ca1465b6`，artifact 对应配方 head `05946c51baf7e4d9301e2b76cde25cc6221f13ed`。ZIP 为 526,420 字节，SHA-256 `d2b5ca95673b0b63187d3696d4c142cfef0b8d540b07d1263b75b8974febacd3`。 |

两份报告均证明：删除 2 条模块自有 RPDB 规则后，同 UID UDP 成功→超时→恢复；经过 5 次 `connectivity.tick`，恢复尝试从 0 增至 1。eth0 模拟蜂窝上联经 mobile-data 关闭/开启后，在 1 次 tick 内恢复 TCP，恢复尝试保持 1。验收环境为 Android 15/SDK 35、固定 KernelSU 3.2 内核的 x86_64 AVD 与 standalone TUN；未据此证明物理 ARM64/OEM、eBPF 数据面、IPv6 转发、真实代理或 Play/GMS 行为。

本轮逐项核对三个待处理 PR：[#452](https://github.com/LIghtJUNction/MagicNet/pull/452) 的可信订阅合同和升级保护、[#455](https://github.com/LIghtJUNction/MagicNet/pull/455) 的简约界面均已由 #456 整合；[#453](https://github.com/LIghtJUNction/MagicNet/pull/453) 的多语言校验由 [#454](https://github.com/LIghtJUNction/MagicNet/pull/454) 的活动字段校验取代。保留当前实现和源码指针，旧分支按已被取代处理。#452 的历史报告仍可通过[原固定提交](https://github.com/LIghtJUNction/MagicNet/blob/d2608565713e487aa2e4661bb6e9c161633137bf/recipes/magicnet/ISSUE_440_VALIDATION_2026-11-13.md)查询。

预览实际构建 source=`4b02897dffd6acd455c0e25849b46398ca1465b6`、recipe=`48dd2a3830fa857c774415fc8eba838ccd83ff4c`；[资产核验](https://github.com/LIghtJUNction/MagicNet/actions/runs/43687915429/job/132742190425)核对同一身份。配方受测 head `05946c51` 与合并提交 `f6c808ed` 的 tree 均为 `3a3b52b1d07fbf29b100139e07cfa044e6344751`；固定源码与源码合并提交 `af72e043` 的 tree 均为 `ced91db63d6e301dbcda75d7220a6fb829b8e132`。构建日志明确通过可信来源、下载策略、真实 HTTP/TLS/SOCKS5、安装升级与组件归档安全检查；设备 trust/history 保留与发布包授权隔离均覆盖。

`.local` 和链路本地反向查询的规则范围来自 [RFC 6762 第 3、4 节](https://www.rfc-editor.org/rfc/rfc6762.html)；锁定核心具有原生 mDNS 传输。本次未验证 Android 物理设备组播、实际 NAS 或家庭 DNS，home.arpa/.lan 行为没有据此改写。源码 PR #8 已合入可信本地订阅授权；本轮把对应 SUB-016/C-SUB-009/UI-SUB-013 和 M69 合同接入当前配方，不把既有订阅历史修复当成新增实现。

前次候选的环境/构建失败保留：`45154757` 的 [webui job 132729899795](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687107250/job/132729899795) 在 Ubuntu 26.04 安装 Playwright 字体依赖失败，浏览器测试尚未开始；对应修订将相关浏览器 job 固定到 Ubuntu 24.04，保留全部依赖和测试。Android [43687107232](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43687107232) 在构建 curl 依赖时拒绝 zlib 归档摘要不符，未运行模拟器；失败发生于新下载，工作流没有还原该源归档缓存；820b 至当前锁文件与下载器未变，旧 run 同锁构建成功。新候选保留版本和摘要自然重跑，未跳过哈希或验收。浏览器 job 的 CI 合同 20 项和发布 workflow 合同 42 项本地通过，当前 `4b02897` 的 CI 已确认 actionlint 与真实依赖安装；本轮成功没有证明原 zlib 摘要异常的原因。

前次失败保留：源码 [Code Quality 43682884914](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43682884914) 为 810 passed / 5 skipped / 1 failed，失败是 320px 俄语状态标签溢出；配方 [43683319759](https://github.com/LIghtJUNction/MagicNet/actions/runs/43683319759) 的 Android 在注入路由故障前 UDP 基线超时，`recovery_tick_count=0`。同期源码 [Android 43682884867](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43682884867) 成功只适用于旧 tree，不能替代当前候选或正式发布门禁。

## 2026-11-15：WebUI 视觉精简

源码固定点为 `820b690d413e4f393db24962366e1d809fc48489`（tree `9541ac8d8e014bd8ae3829ff9daea93c92e65e4f`）。[源码 PR #9](https://github.com/LIghtJUNction/magicnet-android/pull/9) 已合并，合并提交 `9bf5958916c0e336d7e8d2d2e700c928d24d954d` 的 tree 与该固定点一致。页面改用中性色、留白和连续分区，收起重复顶栏入口；Logo 返回概览，概览流量路径静态展示真实状态。模型署名彩蛋、发光星形、无限装饰动效、重复标题层级与装饰图标已移除。配方为 magicnet 0.3.23 / web-console 0.2.7，接口、设备状态语义与运行依赖保持。

| 验证范围 | 结果 |
| --- | --- |
| 最终本地 WebUI 检查 | 完整 `npm run check` 通过：388 项测试、Vue 类型检查与生产构建。反馈推荐文案、表单和隐私约束继续检查；旧装饰图标断言已随设计删除。 |
| 最终浏览器视觉回归 | 固定源码 `820b690d` 的 [visual-evidence 43682885222](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43682885222/job/132717181280) 成功，312 项 Playwright 用例通过，生成 192 张 PNG。覆盖 320、360、390、430px 手机、844×390 横屏、1280×900 桌面及浅深主题。 |
| 全量源码 CI | [Code Quality 43682884914](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43682884914) 后续失败：810 passed / 5 skipped / 1 failed，320px 俄语状态标签越界；修复与重新验收见本页上节。视觉子集成功不代表完整流水线成功。 |
| 配方归档 | 最终源码指针集成后的 check、pack、归档检查与完整 build 提示词检查通过，闭包为 8 包、62 个 Markdown 文件；活动指针的 17 项现有测试通过。[Recipe checks 43682952340](https://github.com/LIghtJUNction/MagicNet/actions/runs/43682952340) 同样通过。 |

最终截图 artifact `14149636251` 下载后独立计算的 SHA-256 为 `ba117498b3721dc42fd08c0ae0ccfb9ef1258908b60beba473ab70073e95dadb`，与 GitHub digest 一致。桌面与手机代表页面已人工复查。浏览器使用显示与原生桥夹具；该轮未执行物理设备 WebView、真实网络验证或独立重建。此前 Android 生命周期结果继续保留原提交、产物和环境身份。该轮未发布 Android 安装包，当时稳定发行仍为 v1.8.7 / 10615。

## 2026-11-13：#436 逐应用路由规则与可控网络验收

已验证固定点为 `a4135d5edc39af4895968359bf16e8aefefdaeac`（tree `f477642021d129ae9b5a64d87436f678db06d62f`），配方受测head为 `284248b6d4c4913e064de69d6ee7cdebe5045e03`（tree `55793abdef24d23e97629d5b2894e75db49b3fcd`）。[源码PR #7](https://github.com/LIghtJUNction/magicnet-android/pull/7)与[配方PR #451](https://github.com/LIghtJUNction/MagicNet/pull/451)已合并，实际merge分别为 `83582a9490312e6a84bbc3f63695aedfc9250576`、`dbd05dd419654dfd2a47b3e263953416d7109efe`；两棵合并tree均与对应受测候选相同。a413相对668仅增加宿主诊断，不改变生产恢复、预算或独立门禁；未知boot失败根因未被本次成功证明已修复。完整报告与摘要见[最终修复记录](../../docs/issue-436-recovery-verification-2026-11-13.md)和[证据索引](../../docs/evidence/issue-436-ci-2026-11-13.json)。下面的668及更早结果仍绑定各自原始提交。

已测试候选 [`66870152`](https://github.com/LIghtJUNction/magicnet-android/commit/668701523f52959f2daf5113ee11b716aa7ecddb)（tree `e6b0d68c74703a68ad0b662f6618ac6165271818`，[源码 PR #7](https://github.com/LIghtJUNction/magicnet-android/pull/7)）修正逐应用规则归属比较，并为恢复实验建立单 eth0 夹具，通过实际管理 eth0 的模拟蜂窝服务完成断开与重建。整合保留源码主线 Action 升级和原固定 eca9ac8 的停止诊断、编辑器输入预算。

原始基线为源码 `5edd36ba` 的[失败运行 43253655173](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43253655173)：同 UID UDP 1→0→1、readiness false→true、一次成功的生产恢复，最终却报 `recovery_rule_set_mismatch`。eth0 仅从 netId100 变为101，接口/FIB、权限和逐应用 UID 范围不变；旧比较器遗漏优先级15040/22040的逐应用规则。当前采集器与独立门禁按已核验的 netd 元数据推导完整全局/逐应用 selectors，支持不变的 NONE/NETWORK/SYSTEM 权限，精确比较字段与重复次数。真实权限、UID、接口/FIB或其他规则变化仍失败。

初轮 `58ccae52` 的[源码运行 43385059168](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43385059168)发生 wlan0→eth0 的真实默认网络与系统 UID 归属迁移，严格门禁保留失败。其[整合运行 43385469784](https://github.com/LIghtJUNction/MagicNet/actions/runs/43385469784)在故障注入前 UDP 基线超时，原因未定；两个 Android 报告均为5 passed / 1 failed / 7 not_run。后继隔离上联成功不能证明这个 UDP 失败已解决。

`9dba9425` 的[整合 43391099744](https://github.com/LIghtJUNction/MagicNet/actions/runs/43391099744)完整成功：精确9dba源码的 Android13/13、5次重启、实际发布质量门禁与产物核验均通过，实际覆盖 eth0 netId100→102、权限NONE及prio40/UID10136保持的规则迁移。原始报告以其对应9dba门禁复验通过。构建来源记录 source=`9dba94254780fb0a1a84a003608d5919a97de4f2`、recipe测试合并=`beba98cac301bd887822d44b6bd1a88edd54c764`、CI预览v1.8.8/10616；未正式发布。

同树的[源码运行 43390671015](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43390671015)仍为5/1/7：RPDB恢复与UDP1→0→1通过，但随后eth0 down/up后IPv4默认路由在600秒、10次tick后仍未恢复。末次 `selected_default=false`，readiness/TCP未调用。清理前支持包已捕获：eth0 UP/LOWER_UP、IPv4地址、TUN规则与IPv6 RA仍在，Android IPv4静态/default路由缺失。整合成功不覆盖源码失败。报告源码为测试合并 `eee288a83fb18eb30223b0e0b7ad0431a2486f6f`，与9dba同tree；包沿用源码v1.8.5/10613 metadata，与整合预览标识分别记录。

`5f96a190` 的[源码 Android 43399092150](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43399092150)与[整合 Android 43399411108](https://github.com/LIghtJUNction/MagicNet/actions/runs/43399411108)均在 `incomplete_ethernet_dump` 失败，分别保留5/1/7阶段、1次重启和原始失败门禁。两者RPDB恢复均通过，UDP分别为8→5001→4 ms和4→5001→5 ms；上联还在baseline，未执行down。源码实际受测为 `b60d1b90aaec75a9fa60f1c534c71e4375aed8f0`（与5f96同tree），整合实际源码为5f96。不能把宿主86/67通过写成设备清理屏障通过。

独立[服务诊断43403995584](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43403995584)确认固定Google API35/r9镜像没有 `ethernet` Binder服务，命令返回rc0、空stdout和 `Can't find service: ethernet`。因此此前依据EthernetFactory停止机制解释eth0的假设不适用于本镜像。固定[r23模拟无线电实现](https://android.googlesource.com/device/google/cuttlefish/+/refs/tags/android-15.0.0_r23/guest/hals/ril/reference-ril/reference-ril.c)把模拟器蜂窝接口定义为eth0；实际[三阶段诊断43404505529](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43404505529)观察到CELLULAR/WWAN/eth0/sub1，移动数据关闭/开启后netId101→无→102，flags0x1003→0x1002→0x1003，用户/有效数据状态true→false→true，连接状态2→0→2。该诊断使用同一用户空间镜像与stock kernel，不含MagicNet；它证明控制与观测机制，不能替代完整KernelSU验收。

后继修订改用 `cmd phone data disable/enable`：从PhoneGlobals默认数据订阅及telephony.registry明确当前段，绑定唯一phone/subId、两种数据启用状态和当前WWAN/eth0/netId；关闭后有界取得连接清空、实际DOWN与netd旧网络销毁证据，再启用。实际down期间原逐应用UID元数据迁移至UNREACHABLE52，校验只允许这一精确推导的迁移，恢复后原元数据返回，仅eth0 netId可变。`cellular_lifecycle`由独立门禁重验。30秒enable guard和原600秒恢复预算保持，仍需默认路由、TUN就绪与同UID TCP；未手工补写外部路由。原9dba缺省路由失败与绕过Telephony的raw down/up机制相符，但没有完整原事件窗口，仍不把机制推断写成原设备根因。旧报告不补造新字段。

单上联夹具仍先验证一次性x86_64 AVD身份与安全控制通道，保存并临时关闭Wi-Fi，取得两次一致的eth0 netd/RPDB/出口基线；finally恢复并回读原Wi-Fi启用布尔值。RPDB/上联失败时在配置清理前采集既有脱敏支持包，保持25秒预算及原失败原因。CON-A09/M66已同步；生产恢复流程、预算和机器schema=1保持。

`66870152` 的[源码 Android 43407220745](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43407220745)保留失败：9 passed、1 failed、3 not_run。`tun-route-recovery` 已通过，耗时 325.799 秒；随后 `upgrade-preservation` 报 `Android boot deadline exceeded`，第二次重启命令退出码为 124，未观察到新 boot。原始报告实际源码为 PR 合成测试提交 `053a11d134f3177fa94e917828245a2dfce81a36`，tree 与 668 相同。使用精确 668 门禁复验完整原始报告仍为 exit 1；单独路由证据通过不能覆盖完整生命周期失败。boot 失败原因尚未确定。

同一固定源码的[配方整合 43407837059](https://github.com/LIghtJUNction/MagicNet/actions/runs/43407837059)完整成功，[Recipe checks 43407835916](https://github.com/LIghtJUNction/MagicNet/actions/runs/43407835916)也通过。Android 原始报告实际 source 为 `668701523f52959f2daf5113ee11b716aa7ecddb`，13/13 阶段、5 次真实重启全部通过，精确 668 独立门禁复验 exit 0。RPDB 同 UID 10209 的 UDP 接收为 1→0→1，耗时 5/5001/6 ms；readiness false→true，恢复尝试 0→1。蜂窝三阶段证明 netId100→无→103、数据状态2→0→2，prio40/UID10134 仅在关闭期间迁入 UNREACHABLE52 后返回；最终默认路由、readiness、同 UID TCP（5 ms）和 Wi-Fi 启用状态恢复均通过。该配方成功不覆盖上述源码升级重启失败。

配方 Android artifact `14029563278` 为 523,771 字节，下载后独立计算的 SHA-256 为 `7eaf37fbe80284a909348399c4bc619cb7109909b6407243ac9ce0bf580f7749`，与 GitHub digest 相同。完整构建实际执行发布质量门禁并成功，资产作业 `131849105682` 验证 build-source 为 source=`668701523f52959f2daf5113ee11b716aa7ecddb`、recipe 合成测试提交=`53087b92330bf6b6ac7885d0951217e90ca7d786`、CI 预览 v1.8.8 /10616；对应 recipe head=`02369b3c8f7152a1464cedf27783183d2e4a326f`，两者 tree 均为 `5c9cfad147138e62b74c04df3b8209399f1e4cbd`。构建 artifact `14031630631` 为 142,419,552 字节，GitHub digest 为 `2aa89ecb49c7b63bfadf99e4c11817da5f11549b51154ffb4b4b87bcd8478706`；远端资产作业下载后核对同一摘要，并通过完整清单、19 个文件校验和及产物来源检查。工作环境在该构建结束前中断，未再进行本地独立 ZIP/manifest 复算；这里记录的是远端 CI 核验。publish 被跳过，未正式发布。

| 验证层 | 实际结果与提交范围 |
| --- | --- |
| a413 宿主诊断定向检查 | [隔离短测试 43417860968](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43417860968)在诊断提交 `96101fa7473ce641c60cb8e18ca5cb4775ad4dcf` 完成 host 观察器27、重启6、工作流合同29、独立门禁72项检查并通过；当前候选使用相同的五个已审查源码 blob，临时短测试 workflow 未合入。该结果不替代完整 Android CI |
| 668 宿主检查点 | 恢复采集器91、独立门禁72、模拟器合同114、验收合同33、工作流合同27项通过；source lint838跟踪文本、diff-check通过；实际三阶段诊断与原始失败分别记录 |
| 未改动的生产代码 | 此前定向Rust connectivity22项单元、9项集成与supervisor20项通过；当前修订未修改生产Rust |
| 配方材料 | 固定值15、发布计划41、发布资产16项此前通过；02369b3同树提交的八包/62 Markdown 检查、打包、归档检查和 build prompt 通过。当前284的 [Recipe checks43418587798](https://github.com/LIghtJUNction/MagicNet/actions/runs/43418587798)也已成功；M37独立重建另列 |
| 历史完整结果 | 9dba/e36整合43391099744成功；其源码运行43390671015失败，二者各保留原始身份和结果。更早dc4433d1发布13/13只适用于其对应版本门禁 |
| 668 完整 Android | 源码 43407220745 为 9/1/3，升级重启失败；配方 43407837059 为 13/13、5 次重启及完整构建/质量/资产检查成功，两份原始报告及门禁结果分别保留 |
| 当前候选完整 Android | a413[源码43418093071](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43418093071)及284[配方43418588448](https://github.com/LIghtJUNction/MagicNet/actions/runs/43418588448)均成功，各13/13阶段、5次真实新启动。原ZIP经[源码43422960113](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43422960113)与[配方43425532180](https://github.com/LIghtJUNction/MagicNet/actions/runs/43425532180)独立runner下载实算摘要，原simulation字节保持，固定完整gate均exit0 |
| 审查边界 | a413源码Sourcery因差分超过150,000字符skipped；284配方Sourcery成功。旧58cc的APPROVED不算a413新批准，配方成功check也不等同新的APPROVED review。producer/gate、宿主观察器及两份原件复验完成独立交叉复核；两PR无未解决审查线程 |
| 独立重建 | 本轮未执行M37；配方材料检查与独立软件重建分别记录 |

当前a413源码与284配方均取得完整成功；668源码升级boot失败仍是未查明原因的历史失败。当前源码RPDB netId100保持，后续cellular100→无→103；当前配方RPDB实际100→101且权限/UID10135-prio40/eth0/FIB保持，动态覆盖合法重编号，随后cellular另为101→无→102。两份UDP均1→0→1、生产恢复尝试0→1；清理前child/observer与ADB均可见，但均缺少EXIT回执，SIGTERM_sent不能证明最终退出或清理完成。Wi-Fi启用状态恢复不等于关联或切换恢复。公开稳定版保持v1.8.7/10615；配方实际发布质量与资产核验通过的v1.8.8/10616仅为预览，publish跳过，没有正式发布或设备部署。物理ARM64/OEM规则删除触发者、真实订阅与公网代理仍无新的成功证据。

## 2026-11-09：#436 与模拟器故障回归

[48efc93](https://github.com/LIghtJUNction/magicnet-android/commit/48efc93601ed1bb66871c1274034a372da2ffc06) 在既有 watchdog 中独立观察 TUN：同一核心连续两次确认缺规则，经过 90 秒启动宽限和共享 300 秒冷却后走标准重启，每次开机最多恢复 3 次。未知、停止、事务、换代和损坏预算均拒绝恢复；Google/mixed_proxy 独立。相关 Rust 曾实际完成 870 项通过、1 项环境忽略，Clippy/格式通过。

必选 `tun-route-recovery` 精确删除自有 RPDB lookup，以同应用 UID 的非 DNS UDP 验证正常→断流→生产恢复，保留 TCP 控制。辅助表归属由正常停启校准；Android 网络编号变化须有完整 netd、接口/FIB 和两条精确 selector 证据。独立门禁核对源码、全部 13 阶段及清理，失败或跳过均不得通过。

当前 `9163064` 的[质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42676133634)、[网络](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42676133240)和[构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42676133719)均成功；root `4d09d7d` 的[配方 CI](https://github.com/LIghtJUNction/MagicNet/actions/runs/42676938799)成功。Android 宿主合同 427 项通过、1 项跳过，采集器 52 项与门禁 45 项包含在内；网络浏览器子集 312 项通过。Rust 质量项为精确缓存命中，不计新执行。宿主汇总预算由 15 调至 20 分钟，保留 25 分钟作业预算及全部测试；本次实际耗时 805 秒，不能把通过仅归因于预算增加。

[916 Android 实测](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42676133752) 再次证明 RPDB 恢复：同 UID UDP 接收 1→0→1，首次 missing 不重启，随后正常生产路径恢复一次，外部规则归属核验通过。但上联阶段仍以 `uplink_reconnect_deadline` 失败：共 5 阶段通过、1 失败、7 未运行；重启仅 1/5，独立门禁 exit 1。原配置已恢复，不等于无线已重新关联。

新诊断确认上联切换前原 `wlan0` 默认路由、ready 和 TCP 均成功；末次原默认路由缺失，ready 与 TCP 因短路未执行，不能称 TCP 失败。完整 guest 日志记录 Wi-Fi 断开关联和 supplicant 退出；接口 UP 位恢复没有证明关联恢复。计划修正独立 guard 的 Android 框架恢复动作，继续要求原接口默认路由、就绪和同 UID TCP。工作环境随后离线，该修正尚未实施或复验。

[证据索引](../../docs/evidence/tun-recovery-ci-2026-11-09.json) 保留精确提交、产物摘要、历史失败和 GitHub 平台故障；较早 c595 无末次观测，不能套用本轮诊断反推它的原因。当前完整 13 阶段未通过，#436 保持 open；OEM 删除规则的触发者、物理 ARM64 与公网行为仍未验证。

## 2026-11-09：前后端可用性与状态恢复

初始改动分三次提交：[08c2dea](https://github.com/LIghtJUNction/magicnet-android/commit/08c2deaab8106d46cb015942a61f1a0832be54b7) 修复异步前台操作恢复与订阅读取跟踪；[cd6055f](https://github.com/LIghtJUNction/magicnet-android/commit/cd6055f3605a53746a657fe8157fc0ac5de523f8) 修正未知运行状态和不完整命令；[ebb0b9d](https://github.com/LIghtJUNction/magicnet-android/commit/ebb0b9d98183effdb552be74ede7d81c1de4e3f0) 增加首页下一步建议、内置节点入口及订阅来源/设置的读取和并发门控。

最终 [0a175bc](https://github.com/LIghtJUNction/magicnet-android/commit/0a175bcb68bdd514f6db88f975193e4c73120126) 保留并行合入的 TUN 恢复实现，修复 Tailscale 私密读取结束后自动重读的真实循环。读取只由首次可用、显式刷新或配置 revision 变化驱动；在途变化合并一次补读。真实 Vue watcher 新增 5 项反例修复前失败、修复后通过，Tailscale 定向 54 项通过。根据 CI 窄屏截图，将首页下一步移至概览顶部，并加入完整首屏可见断言。

首页建议区分未读取、空来源、需要更新、可尝试启动；本地文件导入成功且远程缓存为零时仍提供启动检查。建议不把缓存数量当成有效节点数，不限制自定义完整配置的显式启动。服务状态未知时只读取状态。自动引导等到有效观测后出现，不因读取失败误判为新用户。订阅读取失败保留草稿，重试成功才恢复写入；任务占用、队列和未完成后台操作也阻止并发提交。

CLI 缺少 selector 参数返回可读用法错误，不再 panic。未知进程状态不做 toggle，缺失/损坏配置或事务日志保持 unknown；configured 与 effective 分开。机器接口继续使用 schema=1，未增加写 API。

宿主验证：回归修正后的 `npm run check` 通过，含 **390 项 WebUI 测试**、TypeScript 检查和生产构建；后端修复阶段（cd6055f）Rust 相关 **84 项通过、1 项既有环境用例忽略**，格式检查通过。忽略项依赖 AOSP mksh，不计为通过。完整前端构建仍提示主 chunk 超过 500 kB；本轮未测量启动速度、内存或续航，不据此宣称性能提升。

本地 Chromium 创建 socket 被宿主阻止，额外权限请求被自动拒绝；共享浏览器未能访问隔离服务，因此本地浏览器交互未记为通过。

初次 [浏览器 CI](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42630589799) 为 715 passed、84 failed、5 skipped；失败集中于 Tailscale 自循环和仍按旧语义查找启动按钮的用例，已修正代码与断言。0a175bc、ae8632d 与 17f1f59 的质量运行被后续 push 自动取消，不计为通过。17f1f59 的[网络证据 CI](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42635923842) 另有 312 项浏览器测试通过；该子集与后续完整套件重叠，不累计计数。

[7c8faf8 的完整六视口 WebUI 门禁](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42637788178/job/129230822352) 已实际运行 500.47s、exit=0 并成功；[网络回归](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42637788275) 成功，其中订阅/Tailscale/页面浏览器子集为 312 passed，不能与完整套件相加。7c8faf8 整体质量运行随后因并行提交取消，未结束的 shell 不计为通过。[该提交模块构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42637788405) 成功，已上传 artifact `13685705675`（142,307,045 字节）。

后继 a5c63c4 的[完整质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42639937728)和[网络回归](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42639937778)均为 attempt 1 success，含实际执行的 WebUI 全套及 312 项页面子集。e8b4bb7 的[完整质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42644387026)、[网络回归](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42644387033)和[模块构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42644386827)也已成功；后继 47d55d2 只调整验收与文档，生产 Rust/WebUI 未变；其[完整质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42649305978)、[网络回归](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42649305830)和[模块构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42649305916)均首次运行成功，完整浏览器实际执行 606.05s。Android 结果见上节，不能由这三条 CI 代替。[较早 CI 快照](../../docs/evidence/usability-ci-2026-11-09.json)保留历史身份与当时状态。现有真机/公网验证边界继续保留。

## 2026-11-08：代码与文档精简

源码提交 [fb944a1](https://github.com/LIghtJUNction/magicnet-android/commit/fb944a10b15fd1f7e97182da1ac5078b6b226a69) 移除无引用组件、样式和重复展示逻辑；[351b7d7](https://github.com/LIghtJUNction/magicnet-android/commit/351b7d7189c057ba88c4da89092e5bc4124989d0) 合并 DNS、网络策略和连接列表处理。合计新增 54 行、删除 302 行，净减 248 行。主仓库 [e5da4a8](https://github.com/LIghtJUNction/MagicNet/commit/e5da4a83d40a28ed6f8461732af14c5ceb7d1ede) 删除已由 release-plan.py 接替的旧规划入口，保留现行资产验证和发布保护。

宿主验证：347 项 WebUI 测试、类型检查与生产构建；69 项 Rust 定向测试、构建与测试编译；132 个 CLI 新旧差分及 38 个颜色映射对照，全部通过。发布/资产/固定点 57 项检查、配方 check/pack/归档/build（8 包、61 Markdown）与主仓库工作流语义检查通过；第一批主仓库 [CI](https://github.com/LIghtJUNction/MagicNet/actions/runs/42494426303) 成功。未删除产品测试或降低验收要求；旧规划路径的三项重复测试由现行发布流程的等价检查覆盖。

Chromium 启动时创建 socket 被宿主拒绝，手机/桌面布局实测未进入页面；不能记为通过。本轮未做 Android 真机或新增性能测量，删行不构成运行时提速证据。当前源码与旧发行、旧完整预览分别保留提交身份。

## 已有验证与实际边界

- 配方检查覆盖目录、pack、归档再次 check、完整中文 build 提示词与 UTF-8 Markdown 闭包。它验证材料交付；实现是否满足合同须另跑验收。
- Android 15 / KernelSU / x86_64 已有 12 阶段、5 次重启、本地 TUN/应用控制、TLS 正负控制、升级/停止/禁用/卸载及单文件诊断证据。
- Google 正常产品 tick 的已记录结果为 TLS 失败，HTTP 204 未取得；告警与退避生效，未满足恢复门槛时没有订阅更新/核心重启。确切握手原因未知。
- 物理 ARM64 手机、用户真实订阅/代理出口、OEM/WebView、热点/IPv6/eBPF 数据面、移动网络切换、持续负载与续航尚缺完整验收；最低 Android/WebView 版本未知。
- 性能样本保留环境、输入与测量口径。宿主 GC 堆、CLI 峰值、短时回环和 Android 核心快照分别记录于 [PERFORMANCE.md](PERFORMANCE.md)，不合并为整模块或真机性能结论。
- 独立 Go/ES modules 候选与维护的 Rust/Vue 实现具有不同源码和冻结输入，验收结果不可互换；M40 之后新增合同未被旧候选完整覆盖。

## 2026-11-07：全部工作流与发布预览

[PR #445](https://github.com/LIghtJUNction/MagicNet/pull/445) 修正静态权限、严格依赖、README/updater 同步和所有工作流的 actionlint 门禁。源码 af3930bd 修复 ADB 成功测试的 1 秒预算误报；生产默认 300 秒和生产脚本保持，原失败反例仍执行。

| 对象 | 成功运行 |
| --- | --- |
| 主仓库完整预览 | [42330606044](https://github.com/LIghtJUNction/MagicNet/actions/runs/42330606044) |
| 源码质量 | [42330416104](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416104) |
| 源码构建 | [42330416074](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416074) |
| 网络证据 | [42330415990](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330415990) |
| Android 模拟器 | [42330416075](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42330416075) |

合并提交 `3e2e604683ab9e0b5309a1b5ed2c4fc4fba7e2ce` 与受测 PR merge `d2956b7e4e0b285a18e5907dd4cbda0c33d6eaa9` 的 tree 同为 `a9153c3032503e82cfd8db701bc4753a6efb3b36`。模块 artifact `13557459752` 为 142,285,073 字节，Android artifact 为 `13557792885`。

当时本地 37 项 release-plan、19 项资产、4 项 live-pin 及八包/61 Markdown 检查通过。五仓库 26 份 workflow 均通过语义检查；sing-box fork 的 Actions 当时暂停，缺本轮线上结果。[逐文件审计](../../docs/workflow-audit-2026-11-07.md)保留范围、运行与恢复入口。11-07 报告中的 v1.8.4 是当时稳定版，当前索引见上表。

## 2026-11-06：DNS 默认出口

源码 `38c6eea6a42eb5f2cc3697c81225f35fd3c82d5c`、模板 `ba5793b41fd06704102116fe2536eef5988f2905`，配置摘要 `e269e2303cf1e23d3b4ce69dcb7cca39f0f53dc647c5d03aace4c4bd7f986be0`。未知域名经代理 DoH，节点域名直连引导，显式 resolver/独立配置保留；代理拒绝时没有直连业务回退。

最终[质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346672)、[网络证据](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346632)、[构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346674)通过。真实固定核心的 A/AAAA × UDP/TCP、本地 TLS DoH/CONNECT 和无直连回退验证通过，公共 DNS 请求为零。完整 ARM64 包 68,480,032 字节，SHA-256 `1fdc0caa0c2d412562bc44058b8527210ebad6df75dbc0fcc17d1eba44bab234`；完成归档核验，ARM64 执行未测。

[Android 42187346630](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346630) 首次 cold-boot 本地 TLS 正控制失败，确切原因未保存；同源码第二次 12/12 阶段、5/5 重启通过。curl 重建摘要有变化，保留两次身份；Google 仍 TLS 失败。详见 [DNS 修复](DNS_REPAIR_2026-11-06.md)及[原始 CI 记录](../../docs/evidence/dns-repair-ci-2026-11-06.json)。

## 2026-11-06：低频联网、HTTPS 组件与诊断

最终源码 `ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9`；[质量](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653819)、[构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653787)、[Android](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653691)和[网络证据](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653682)通过。真实归档核验 14 ZIP、1,104 成员、10 组件/168 文件、17 摘要、12 pins 和 9 ARM64 ELF 路径，测试开发目录为零。

无系统 curl 的模拟器实际使用包内执行器；本地 TLS 正负控制、gzip、12 阶段和5次重启通过。一次正常 tick 得到 `tls_failure`、`warning=true`、60 秒退避；辅助目标与直连对照也失败，恢复动作保持 none。诊断 64,649 字节、48 节，采集 764ms，0 incomplete/0 truncated；导出前后探测次数为 1。

完整包 68,476,029 字节，SHA-256 `8dc73eb02ed508b772ed55618fa835ef869906ec8f3ae326e594fc94a0fd4d63`；[模块下载](https://drive.google.com/file/d/1b0qGXu15kLS01dFjhhF74_tqphRmYaAt/view?usp=drivesdk)、[实际诊断样本](https://drive.google.com/file/d/1e_Cj7QrqJmOCjXNzWdDhxRrKH5bsdaoJ/view?usp=drivesdk)。[专题报告](../../docs/connectivity-diagnostics-2026-11-06.md)保留合同参数、测量、复现命令与失败边界；[host](../../docs/evidence/connectivity-diagnostics-host-2026-11-06.json)/[CI 原始记录](../../docs/evidence/connectivity-diagnostics-ci-2026-11-06.json)保留全部候选身份。旧 d22/b5/218 失败候选未作为最终包交付。

## 历史证据索引

| 日期 / 范围 | 结果与来源 |
| --- | --- |
| 11-06 Issue 集成 | `8ff12428` 七条 CI 均 attempt 1 成功，Android 12/12、5/5 与本地 TLS 通过；Google 204 未取得。[ISSUE_TRIAGE](ISSUE_TRIAGE_2026-11-06.md)保存 #437–439 关闭与 #436/#440 未完范围。 |
| 11-06 跨仓库发布 | 主仓库 [#443](https://github.com/LIghtJUNction/MagicNet/pull/443)、源码 [#4](https://github.com/LIghtJUNction/magicnet-android/pull/4)合入；v1.8.6/10614 预览全门禁通过，未公开该版本。[迁移报告](../../docs/ci-release-migration-2026-11-06.md)。 |
| 11-06 跨层重写 | 全量对照绑定 `d58dbdc5ed8a43bc1fee5050187b529a0f7136b7`，最终整合另做定向复验；[源码报告](https://github.com/LIghtJUNction/magicnet-android/blob/f7188cc1f1184e5b5ac8da2d24b2dabeb42503ea/docs/rewrite-verification-2026-11-06.md)区分保留算法、修正缺陷与资源样本。 |
| 11-06 目录、锁、原生 TUN | `fafd08c3` 宿主回归和核心配置通过；完整模板因缺 SRS 有未过项，未部署设备。[运行时报告](../../docs/runtime-repairs-2026-11-06.md)。 |
| 11-06 教育与 Voice 规则 | 教育模板 `6b5f68a` 及消费源码 `cb7f63b` 有配置/集成 CI；Voice 清理 `76a0e69` 保留普通 ChatGPT 分流。来源与完整次序见 [POLICY_INVENTORY](../magicnet-routing-policy/POLICY_INVENTORY.md)。 |
| 11-06 kamfw 启动器 | `44f3c69f` 使用固定 kamfw/launcher.sh；删除重复 lib/kamfw-web，保留浏览器回退和错误传播。 |
| 11-05 指定拒绝目标 | `c75583b`、模板 `6da3994` 的七条源码 CI 通过；本地 PID namespace 失败与可选跳过保留在固定历史记录。 |
| 11-03 v1.8.4 | [41570680957](https://github.com/LIghtJUNction/MagicNet/actions/runs/41570680957)成功并公开[发行](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.4)，source `d22086d2`，19 附件；默认 UA 403 单次回退与 MCP 隐私修复，#434 真机复测另需证据。 |
| 11-03 UDP/安装清理 | `d0b1422d`，32,768 客户端 GC 后宿主保留堆由 3,149,632–3,186,872 B 降至 736–27,416 B（各3次）；零分配缓存命中，未宣称吞吐提升。安装成功/恢复/未知目录保护回归通过，无手机 RSS。 |
| 11-01 v1.8.2 | 旧 changelog 元数据导致首次发布阻断；`689bd614` 修复后 [41299804577](https://github.com/LIghtJUNction/MagicNet/actions/runs/41299804577)全部门禁成功，19 公开附件本地核验通过。[v1.8.2](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.2)；#426 由维护者关闭，现场根因未证实。 |
| 10-30 核心同步 | source `396d71df` / core `ff669d45`：宿主测试、Linux/Android 构建、真实回环 DNS 通过；默认测试明确排除 13 个环境用例。10,000 ACK 路径 GC 后堆减少 1,120,000 B。[完整报告](https://github.com/LIghtJUNction/sing-box/blob/ff669d45e6562a790a49ef066340dbed5df46363/SPECS/TASKS/051-UPSTREAM_MERGE_235/IMPLEMENTATION_REPORT.md)。 |
| 10-30 UI 与生命周期 | `fd0e2dab` 手机导航、`b113f512` 留白及 `72b6e8fc` 进程交接/PID/日志优化保留；宿主/浏览器结果见固定历史与 PERFORMANCE，真机 WebView 未测。 |
| 10-29 独立候选 | [b22f9f28 验证](https://github.com/LIghtJUNction/magicnet-android/blob/b22f9f280ddaf729da47078c13838a73e6d89294/VERIFICATION.md)记录 Go/ES modules 实现，输入8包/53 Markdown；缺外部 converter、M40 后续发行合同及真实设备验收。目录晋升/回执/恢复/草稿反例纳入现行合同。 |
| 10-29 v1.8.1 | source `a5617d63`、tag `b762b8c5`；构建/质量/Android 门禁通过，草稿恢复核对原19附件后公开。[v1.8.1](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.1)。 |
| 10-28–29 迁移与 v1.8.0 | 原 `f13ca61b` 与导入 `0dca28dd` 完整 tree 相同；保留原历史与固定子模块。Rust 808 passed/1 ignored、WebUI 338 项、浏览器747 passed/3 skipped及模块构建通过；无真机部署。[PROVENANCE](PROVENANCE.md)。 |

历史失败、跳过、临时环境阻塞、精确命令和全部源链接继续保存在本页开头的固定原文，原始 JSON 与发布说明保留。新的验证只追加与本次改动直接有关的结果，避免复述上述记录。

## 本地复现入口

```sh
python3 scripts/check-recipes.py
python3 scripts/test-release.py
python3 scripts/test-release-plan.py
python3 scripts/test-check-recipes.py
bash scripts/check-workflows.sh
```

实现测试进入固定源码仓库，遵守其工具链和对应专题中的命令。实网、模拟器和物理设备测试按各自前提执行，分别记录结果。

## 2026-11-10 证书禁用脚本

新增可恢复系统证书禁用策略。主机真实 X.509 夹具验证关键词、精确主体/指纹、幂等、持久恢复、预先禁用保护和冲突恢复通过；Java/dex 构建通过。未发布安装包，现有手动禁用项不自动认领。

Android 16 真机隔离目录运行 dex：默认规则命中 10 张、disable/apply 幂等、restore/apply 持久还原通过；未修改真实信任目录。隔离测试临时文件已清理。正式开机和模块管理器卸载尚未实机执行。

证书策略已单独整合并推送源码 main `406938e3e396676770a5a9b4911006f19db1c338`；原有 TUN 工作保留在源码 stash，不纳入此次提交。正式 v1.8.6 发布门禁结果待回读。

### v1.8.6 正式发布受阻

主仓库 `41aefcf742f4b8cfcaa481d221f21c56c571fa4a`，固定源码 `406938e3e396676770a5a9b4911006f19db1c338`。正式发布 [42796283786](https://github.com/LIghtJUNction/MagicNet/actions/runs/42796283786) 的构建、完整 release quality gate、发行资产校验通过。源码独立 Code Quality、构建、Android KernelSU、网络回归/证据及卸载检查均通过。已检查源码构建的在线/核心/离线包均包含 certificate-policy、默认 rules 和含 CertificatePolicy 的 dex，以及 boot apply/uninstall restore 调用。

发布 Android attempt 1 在 tun-route-recovery 的上联重连期限失败：uplink_reconnect_deadline，默认网络没有恢复到原 Wi-Fi。attempt 2 保持相同源码重跑，规则恢复成功，但 netd 的 eth0 PHYSICAL 网络为 Required permission: NETWORK，触发 netd_eth0_ownership_unavailable。两次均保留失败，不将独立源码工作流成功替代正式发布门禁；publish 被跳过，未公开 v1.8.6，稳定发行仍为 v1.8.5。未安装到用户手机。

### v1.8.6 按维护者授权直接公开

维护者明确授权在 Android 门禁失败后直接发布。复用 run 42796283786 artifact 13756203637 的原始构建产物，20 项本地 SHA-256 和服务端名称/大小/digest 全部核对一致后公开 v1.8.6 / 10614。发行说明保留两次 Android 失败及授权跳过，不更改 CI 结论，不声称手机已安装。稳定 updater、README 和发行说明随本记录同步。

## 2026-11-11 证书禁用默认关闭与设备恢复

缺少 enabled 的默认值改为 false；开机包装器遇 absent/false 直接返回，不调用 Java 桥或发送信任库广播。显式 disable、restore 与 ownership 行为保留。主机真实 X.509 回归通过，新增缺省关闭和开机无操作覆盖。recipkg check、pack、归档 check、完整 build 提示词生成及归档 62 个 UTF-8 Markdown 文件检查通过。

通过 adb/root 逐张核对设备 user-0 的 10 个中国相关 CA 禁用标记主体及与系统源文件的字节一致性后，按用户授权删除标记；设备 enabled 原子写入 false，SELinux 标签刷新与 TRUST_STORE_CHANGED 广播成功。回读配置 false，cacerts-removed 普通文件数为 0。设备未安装证书策略脚本，因此本次恢复直接操作已核验标记。应用内信任缓存刷新仍取决于应用自身生命周期。

### v1.8.7 发布前模拟器恢复修复

首轮计划因 README 源码指针未同步失败，已同步三种语言 README 并通过完整 check-recipes。随后发布 run 42977712801 的构建、完整 release quality gate 和发行资产检查成功；Android RPDB 故障恢复通过，但 wlan0 原始 down/up 后默认路由未恢复，uplink_reconnect_deadline 导致生命周期未完成，未公开发行。维护者要求先修复模拟器再发布。

修复前台与独立延迟 guard 的 wlan0 恢复动作，增加 Android Wi-Fi 服务关闭/开启和 30 秒接口重建等待；eth0 保持 link_up。报告增加 restore_method 并在门禁核对。宿主恢复回归 56 项、报告门禁 45 项、生命周期合同 109 项、工作流 27 项与 Android 验收合同 33 项通过；完整真实模拟器结果待新运行回读。

### v1.8.7 正式发行完成

[发布运行 42982936016](https://github.com/LIghtJUNction/MagicNet/actions/runs/42982936016) 最终成功，固定源码 dc4433d1cfbeade114d51f3f3c429378d3d7b68d，发行快照 ebbefe01bd29680faf21d000860c606638f56ee1。构建、完整 release quality gate、Android 15 / KernelSU / x86_64 和独立门禁、最终资产校验全部通过。Android 生命周期 13/13 阶段通过，RPDB 与 wlan0 重连实测均 verified；报告包含 android_wifi_toggle、guard 退出、真实默认路由、就绪和同 UID 应用流量证据。已下载报告并用本地门禁再次核验源码身份及全部阶段。

首次 publish 创建草稿后遇到 GitHub 短暂回读不可见（Created draft could not be found），回读确认原草稿身份后仅重跑失败发布 job，复用 artifact 13840432313，随后上传、公开和稳定索引同步成功。公开 v1.8.7 / 10615，非草稿、非预发布，发布时间 2026-11-11T08:37:59Z。20 项服务端资产名称与 SHA256SUMS 摘要集合一致，下载的校验清单、build-source.json、update.json 和核心 ZIP 字节摘要逐项一致。核心 ZIP 含默认关闭的包装器、规则和正确版本，未包含 enabled=true 意图文件。在线 ZIP 三个别名服务端摘要相同。完整/组件 ZIP 的本地再下载未执行，发布工作流的全包校验已通过。

主仓库稳定 update.json 与三种语言 README 已同步至 v1.8.7 / 10615，自动索引提交 c528e7b5。物理手机先前已完成证书恢复；本次新版安装包的设备生命周期验收范围为 Android 模拟器。


## 2026-11-12：PR #450 修订候选（未发布）

活动 BUILD_PROMPT 标题/源码与 build、android reusable workflow 固定值改为精确校验，排除历史示例和注释。发布快照推送前及同 run 恢复时重复验证；publish 备用源码必须先同步审核配方 gitlink 与 workflow pins，build/verify 的源码选择仍保留。

本地配方验证：15 项固定值回归、41 项发布计划回归、16 项资产验证回归通过；actionlint、diff-check 与完整 check/pack/归档/build（八包、62 Markdown）通过。源码候选 eca9ac8 增加停止失败固定枚举诊断并保留所有身份检查；长 JSON 逐键输入单独使用 15 秒预算，断言不变。尚未获得该候选的完整 Android 与浏览器 CI 结果，不把诊断增强写成 stop-cleanup 已解决，也未发布或合并。
