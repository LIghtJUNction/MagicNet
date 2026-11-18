# MagicNet 网络恢复边界迭代报告

日期：2026-11-18（Asia/Taipei）。证据快照：2026-11-18 18:39:46（UTC+08:00）。

## 结果与版本

本轮修复两个能阻碍网络恢复的确定性缺陷：无关目的网段上的条件路由会污染 TUN 健康证据；排队的手动检查会持续阻止核心退出后的后台清理。两个回归用例均先在修改前失败，再在修复后通过。源码、配方和工作流固定点已提交并推送，累计 162 项本地测试通过。

| 对象 | 本轮固定点 |
| --- | --- |
| 实现源码 | [2a7dcddd](https://github.com/LIghtJUNction/magicnet-android/commit/2a7dcddd471ea80f9510b780168a152a067ca5e0) |
| 源码 tree | `ffe959c97bd2368004ab815b50afbc12fd4a081f` |
| 配方集成 | [9d717fa1](https://github.com/LIghtJUNction/MagicNet/commit/9d717fa18eb7061ed7a5e78f81f2f781037cc1c8) |
| 产品配方 | `magicnet@0.3.31` |
| 网络运行时配方 | `magicnet-network-runtime@0.1.18` |
| 公开稳定版本 | `v1.9.0 / 10618`；本轮没有发布新版本 |

结构化记录见 [JSON 证据](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/evidence/network-recovery-boundaries-2026-11-18.json)。本报告对应本轮源码提交和集成提交，历史验证记录保持原样。

## 修复一：让健康判断只受实际必需的目的范围影响

TUN 就绪判断需要回答一个具体问题：配置要求经过 TUN 的目的地址，是否具有可观测的路由覆盖。原实现会在看到某些无法确认匹配条件的 TUN 路由时立即返回“未知”，没有先判断该目的网段是否属于本次策略的必需范围。例如，只要求 `203.0.113.128/25` 经 TUN 时，另一条 `198.51.100.0/24 tos 0x10 dev magicnet0` 也会使判断变成未知。未知状态必须保持谨慎，因此这类无关证据还可能使真实缺路由无法进入既有恢复路径。

修复在有效目的前缀解析后，先计算该网段是否与必需范围相交；必需范围已经扣除了配置中的排除网段。完全不相交的路由不再参与后续条件判断。与必需范围重叠的条件路由、无法充分观测的默认路由，以及无效前缀，继续遵守原有证据规则。恢复仍受连续观察、启动宽限、冷却和预算限制，机器接口保持 schema 1。

新增用例 `conditional_fib_routes_only_affect_required_destinations` 覆盖 48 个组合：IPv4/IPv6 × 四类条件（tos、dsfield、from、nexthop）× 三种目的关系（包含范围外、排除范围内、与必需范围相交）× 必需普通路由存在/缺失。修改前测试以 exit 101 失败，观察到 `None` 而预期为 `Some(true)`；修复后 TUN 定向组 25 项全部通过。48 是一个回归用例内部的组合数量，不另计入测试函数总数。

相关实现为 `crates/magicnet-cli/src/diagnostics_tun_routes.rs`，回归用例位于 `crates/magicnet-cli/tests/internal/diagnostics_tun.rs`。

## 修复二：排队检查不再阻塞核心退出后的清理

手动连通性检查的职责是观察。原实现把“正在执行手动命令”和“队列里存在手动检查请求”合并为同一个禁止清理标志。核心已经退出时，该分支又不会消费请求，导致后续自动 tick 每次都看见排队状态，持续跳过已有清理函数。

修复将核心退出分支的清理条件限定为“当前不是手动命令”。手动命令自身继续不执行清理；后台 tick 在确认 `core_stopped` 后可以进入原有资源清理流程。已有锁、资源归属、禁用/未知状态、核心重新出现与取消检查均保留。本轮没有增加启动核心或发起连通性探测的动作。

新增真实 CLI 夹具测试 `connectivity_pending_manual_check_does_not_block_crashed_core_cleanup` 先完成三次基线探测，然后只终止夹具拥有的模拟核心进程，执行手动检查，再执行后台 tick。它验证手动检查不清理、不增加探测，后台 tick 清除夹具 DNS 捕获残留，状态保持 `paused/core_stopped`，且核心不会被重启。修改前测试以 exit 101 失败，`dns-capture-attached` 残留仍在；修复后全部 27 项 connectivity_runtime 测试通过。

相关实现为 `crates/magicnet-cli/src/connectivity.rs`，回归用例位于 `crates/magicnet-cli/tests/connectivity_runtime.rs`。这里的清理证据来自主机隔离夹具，不代表已在真实手机上执行相同操作。

## 验证结果与复查命令

| 验证组 | 通过数 |
| --- | ---: |
| TUN 路由证据单元测试 | 25 |
| 连通性逻辑单元测试 | 30 |
| 机器就绪状态与健康证据一致性 | 1 |
| 真实 CLI 的连通性运行时夹具 | 27 |
| 发布工具测试 | 18 |
| 发布计划测试 | 42 |
| 配方检查器测试 | 19 |
| 合计 | 162 |

源码目录运行以下命令，均 exit 0：

```bash
cargo test --locked -p magicnet-cli --bin magicnet-cli diagnostics::tun::tests
cargo test --locked -p magicnet-cli --bin magicnet-cli connectivity::
cargo test --locked -p magicnet-cli --bin magicnet-cli tun_machine_readiness_uses_the_same_live_routing_evidence_as_health
cargo test --locked -p magicnet-cli --test connectivity_runtime
cargo clippy --locked -p magicnet-cli --all-targets -- -D warnings
cargo fmt --all -- --check
git diff --check
```

配方主仓在集成提交 `9d717fa1` 运行以下命令，均 exit 0：

```bash
python3 scripts/check-recipes.py
python3 scripts/test-release.py
python3 scripts/test-release-plan.py
python3 scripts/test-check-recipes.py
bash scripts/check-workflows.sh
git diff --check
```

完整配方流程完成检查、打包、归档检查和完整构建提示词生成，共 8 个包、62 份 Markdown；固定源码与公开稳定索引检查通过。Clippy 使用 `-D warnings`，actionlint 为 1.7.12。实测工具链为 `rustc 1.100.0 (0ef1bc386 2026-11-09)` 和 `cargo 1.100.0 (3acc79c0c 2026-11-05)`。另由独立复核检查最终代码差异及既有保护条件，没有发现阻断项；复核没有重复计入测试数量。

## 自动 CI 与验收边界

下表为 2026-11-18 18:39:46（UTC+08:00）的源码提交 CI 快照。所有运行均由正常推送触发，本轮没有手动派发 CI。

| 工作流 | 快照状态 |
| --- | --- |
| [Code Quality](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44286015161) | success |
| [Network Regression Evidence](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44286015133) | success |
| [Build MagicNet source](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44286014957) | in_progress |
| [Android KernelSU Acceptance](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44286015001) | in_progress |

本轮证据支持这两个判断与清理缺陷已经修复，并通过列出的本地回归。它不能证明所有断网场景均已解决。网络切换后路由消失的 OEM 根因及受控真机验收仍属于 [#436](https://github.com/LIghtJUNction/MagicNet/issues/436) 的后续工作；尚在运行的 CI 不计为通过。此次没有进行新的真机验收、手机安装、手机配置变更或版本发布。

配方同步更新了 BUILD_PROMPT、验收条件、连通性合同、依赖版本、三语 README、源码 gitlink 和可复用工作流引用。交付保留固定 tun/ebpf 模式、默认 tun、文件状态权威来源及既有恢复预算。当前可发布性仍应由对应版本的完整发布流程与设备验收决定。

## 报告复核

| 维度 | 本轮结论 |
| --- | --- |
| 改动贡献 | 两个可以先复现失败、再验证修复的确定性边界缺陷 |
| 表述清晰度 | 分开说明错误证据、队列状态和各自行为变化 |
| 实验强度 | 定向单元测试、真实 CLI 夹具、静态检查、配方和发布工具检查 |
| 覆盖范围 | 明确 48 组合与 162 项测试的计数区别，并区分主机、CI、真机 |
| 设计一致性 | 保留证据未知、资源归属、互斥锁及既有有界恢复条件 |
