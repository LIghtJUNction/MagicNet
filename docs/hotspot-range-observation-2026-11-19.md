# MagicNet 热点路由观察修复与验收

交付记录：2026-11-19 03:41（Asia/Taipei）。本记录承接 2026-11-18 开始的热点状态修复。

## 结果

本轮已将热点状态改为依据实际 TUN 配置及路由覆盖判断，修复“条件路由误报正常”和“合法私网排除路由误报等待”。源码提交为 [ada4f32f](https://github.com/LIghtJUNction/magicnet-android/commit/ada4f32f90299ec4b25deb591a2eb476a0a9cd17)。

该提交的初版还引入了非规范表号参数，独立构建检查发现后，后续主线已通过 [6d67ce0d](https://github.com/LIghtJUNction/magicnet-android/commit/6d67ce0df8e4dac896e58706e4af6b20f4aff833) 修正。最终交付必须包含这个后续修正，不能单独把 ada4f32f 当成完成全部门禁的候选。

回读主仓 [6270ab90](https://github.com/LIghtJUNction/MagicNet/commit/6270ab90c02665d8f99d2557f5a6463ad83851df) 时，其固定源码为 [75da8b30](https://github.com/LIghtJUNction/magicnet-android/commit/75da8b3064350dd335844da1957cd45b6c347f9c)，已包含本轮修复与后续修正。本报告只补充证据，不回退后续源码、界面、配方或发行固定点。

## 问题与改动

一条路由存在，不代表所有目标流量都能使用它。旧热点观察器主要寻找指向 magicnet0 的 default，或两条 /1，然后把它们视为完整 IPv4 覆盖。这遗漏了两个相反的问题：

1. `default tos 0x10 dev magicnet0` 仅匹配特定流量条件。旧代码没有检查该条件，可能显示 active。
2. 默认配置排除私网后，合法 FIB 会由多段前缀组成。已有夹具包含 50 条这样的路由，却没有字面的 default 或两条 /1；旧代码会显示 pending。

修复复用普通 TUN 的范围观察器：根据唯一有效 tun-in 的 route_address，扣除静态 route_exclude_address，再检查必要范围是否被可用路由覆盖。原有 RPDB、FORWARD 和内部 peer 回程证据继续必需。

| 观测 | 结果 |
| --- | --- |
| 合法静态排除后的完整分段覆盖，且其余必要证据完整 | active |
| 必要前缀缺失、只有半范围路由或仅 linkdown 路由 | pending |
| 相交的非零或无法确认的 TOS/DS、source、多路径条件 | unknown |
| 同范围或更具体的竞争路由，缺乏足够选路证据 | unknown |
| 明确数值零 TOS/DS | 保留普通匹配语义 |
| 条件路由完全位于已排除范围 | 不影响完整或缺失结论 |
| 配置缺失、损坏、受管入站重复、接口或表号不匹配 | unknown |
| RPDB 或 FORWARD 已知缺失 | pending，不能被其他证据掩盖 |

配置沿用有界 JSON reader，最多读取 4 MiB。机器 JSON 与 .state/machines/hotspot.state 使用同一观察结果；公共输出仍只含状态、布尔和计数。新的 CLI 回归还检查状态查询不修改文件、reconcile 不改变配置或资源归属记录，以及敏感 canary 不泄漏。

实现与回归：[共享 TUN 观察器](https://github.com/LIghtJUNction/magicnet-android/blob/75da8b3064350dd335844da1957cd45b6c347f9c/crates/magicnet-cli/src/diagnostics_tun.rs)、[热点观察器](https://github.com/LIghtJUNction/magicnet-android/blob/75da8b3064350dd335844da1957cd45b6c347f9c/crates/magicnet-cli/src/network_observation.rs)、[真实 CLI 回归](https://github.com/LIghtJUNction/magicnet-android/blob/75da8b3064350dd335844da1957cd45b6c347f9c/crates/magicnet-cli/tests/hotspot_observation.rs)。

## 本轮直接取得的本地结果

修改前固定基线为 `2a7dcddd471ea80f9510b780168a152a067ca5e0`。加入新回归但不修改生产实现时，9 项测试得到 4 passed / 5 failed；失败同时覆盖假绿、假红和不确定配置被误当正常。修复后同组 9 项全部通过。

| 命令或检查 | 本轮直接观察结果 |
| --- | --- |
| `cargo test --locked -p magicnet-cli --test hotspot_observation`，旧实现 | 4 passed / 5 failed，exit 101 |
| 同一组命令，ada4f32f 实现 | 9 passed / 0 failed |
| `cargo test --locked -p magicnet-cli --bin magicnet-cli hotspot` | 33 passed |
| `cargo test --locked -p magicnet-cli --bin magicnet-cli diagnostics::tun::tests` | 25 passed |
| `cargo test --locked -p magicnet-cli --test observation_state` | 9 passed |
| `cargo clippy --locked -p magicnet-cli --all-targets -- -D warnings` | 通过 |
| `cargo fmt --all -- --check`、`git diff --check` | 通过 |

不同过滤组可能重叠，因此不把表中数字相加为独立测试总数。最初隔离目录缺少锁定的配置模板及 kamfw，补齐固定依赖后，编译和全目标 Clippy 才通过。

测试使用真实 CLI 子进程与临时 MODDIR，内核观察命令由受控只读夹具提供。它们证明给定配置与内核观测的判定、公共状态投影及副作用边界，不等同于真实 Android 热点流量验收。

## 初版 CI 失败与后续修正

初版把热点路由表 argv 从 `"2022"` 改成了 `" 2022"`。单元夹具复制了这个写法，CLI 夹具又同时接受两种写法，所以本轮小测试漏掉了该差异。独立 fake Magisk 内核模型只接受规范参数，构建检查因此失败。

[6d67ce0d](https://github.com/LIghtJUNction/magicnet-android/commit/6d67ce0df8e4dac896e58706e4af6b20f4aff833) 恢复规范参数，并收紧两处夹具。后续主线的[修正记录](tun-generation-hotspot-gate-2026-11-18.md)保存了修改前失败、修正后网络观察 8 项与热点 CLI 9 项通过，以及完整 fake-magisk-smoke.sh 通过的证据。这些结果来自后续迭代记录，不能冒充本轮重新执行。

本轮回读到的 ada4f32f CI 最终结果：

| 工作流 | 最终状态 |
| --- | --- |
| [Network Regression Evidence](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44288240726) | success |
| [Build MagicNet source](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44288240688) | failure |
| [Code Quality](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44288240872) | cancelled |
| [Android KernelSU Acceptance](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44288240849) | cancelled |

这些历史状态保持原样，不将取消算作通过，也不将后续修正写成初版 CI 全绿。开发机对两种 argv 的兼容性与严格夹具不同，因此该失败不能证明所有 Android 设备都会拒绝带空格参数。

## 当前整合与复查范围

后续主线已承接热点有效范围合同，并在 runtime 0.1.20 / 产品配方 0.3.33 时整合规范参数修复；当前产品配方继续推进到 0.3.35。主仓 BUILD_PROMPT、ACCEPTANCE 与固定源码保留这些要求。本轮准备但尚未提交的旧 0.3.32 候选不再发布，以免覆盖后续版本。

本轮追加发起了对 75da8b30 的热点 CLI、network_observation 和格式检查；开发机会话回读被中断，未取得最终返回，故不计入上述通过结果。也没有为本轮取得新的真机热点客户端、IPv6、OEM 换网或安装包验收。

需要复查时，在固定源码工作树初始化其配置与 kamfw gitlink，然后运行：

~~~bash
git submodule update --init -- src/MagicNet/.config/sing-box src/MagicNet/lib/kamfw
cargo test --locked -p magicnet-cli --test hotspot_observation
cargo test --locked -p magicnet-cli --bin magicnet-cli network_observation::
cargo clippy --locked -p magicnet-cli --all-targets -- -D warnings
cargo fmt --all -- --check
~~~

本轮闭环是：可复现地发现状态误报，提交共用观察器修复，保留独立构建失败，再核对后续规范参数修正已进入当前固定源码。真实热点联网结果仍需要对应设备与客户端流量证据。
