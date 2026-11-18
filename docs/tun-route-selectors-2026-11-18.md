# MagicNet：修复条件 TUN 路由的健康状态误报

日期：2026-11-18。源码修复已进入 [`magicnet-android/main@9943eb12`](https://github.com/LIghtJUNction/magicnet-android/commit/9943eb128aaef46ca3bb01f9151b49c23ac67c41)，主仓配方通过 [`d1cb47ee`](https://github.com/LIghtJUNction/MagicNet/commit/d1cb47eeb7ab8806bad68ab269333d3bd6ef15b1) 固定同一源码。当前配方为 MagicNet 0.3.30、network-runtime 0.1.17。

## 问题与修复

旧观察器把 `default tos 0x10 dev magicnet0` 当成整个地址范围的普通 TUN 路由。这条路由实际要求报文匹配特定的服务类别标记；普通报文没有满足这个条件。旧代码因此可能让健康检查、机器 readiness 和 watchdog 同时显示正常。

修复在共用的 FIB 观察器中检查 `tos` / `dsfield`。非零、命名或无法解析的值，以及缺值，均沿用 `route-selectors-unobserved` 表示未知；明确数值零继续默认匹配。机器接口在没有其他已知缺失时返回 `dataplane_ready=null`，watchdog 记录 `unknown`、清除连续缺失计数且不执行恢复；原联网观测、恢复次数和冷却继续保留。生产代码复用现有数字解析器、状态和接口。

| 输入 | 修复后的结果 | 验证入口 |
| --- | --- | --- |
| 非零 TOS/DS 条件 | FIB 未知，完整观测标记为 false | 路由观察器回归 |
| 命名值、非法值、行尾缺值 | 保留未知 | 路由观察器回归 |
| 明确数值零、普通默认路由 | 正常覆盖 | 正向对照 |
| 健康规则与条件 FIB 同时存在 | 机器 `dataplane_ready=null` | 机器状态投影 |
| 已有联网成功与条件 FIB 同时存在 | 联网结果保留；TUN 未知、零恢复、零额外探测 | 真实 CLI 子进程 |

## 已执行验证

回归测试先在旧生产代码上失败，实际断言为 `Some(true)`，预期为 `None`；应用修复后通过。源码测试使用 Rust/Cargo 1.100.0 与仓库锁文件，真实 CLI 子进程使用受控命令和探测夹具。

| 检查 | 结果 |
| --- | --- |
| `cargo test --locked -p magicnet-cli --bin magicnet-cli diagnostics::tun::tests` | 24 项通过 |
| `cargo test --locked -p magicnet-cli --bin magicnet-cli tun_machine_readiness_uses_the_same_live_routing_evidence_as_health` | 1 项通过 |
| `cargo test --locked -p magicnet-cli --bin magicnet-cli connectivity::tun::tests` | 8 项通过 |
| `cargo test --locked -p magicnet-cli --test connectivity_runtime` | 26 项通过 |
| `cargo clippy --locked -p magicnet-cli --all-targets -- -D warnings` | 通过 |
| `cargo fmt --all -- --check`、`git diff --check` | 通过 |
| `python3 scripts/test-check-recipes.py` | 19 项通过 |
| `python3 scripts/test-release-plan.py` | 42 项通过 |
| `python3 scripts/check-recipes.py`，固定 `d1cb47ee` | check、pack、归档检查和完整提示词生成通过；8 个包、62 份 Markdown |

以上共有 59 项源码定向测试和 61 项配方/发布工具测试。配方检查同时核对源码 gitlink、两处复用工作流、三语 README、配方版本与已发布索引；归档包含完整 Markdown 依赖闭包。独立代码审查通过。

## Linux 内核选路实测

开发机中创建了一次性用户/网络命名空间，使用 `dummy` 类型的 `magicnet0` 和文档保留地址。实际内核为 `7.3.4-arch1-1`，iproute2 为 `7.3.0`。测试只查询内核选路，没有发送外网数据包。结构化结果见 [证据记录](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/evidence/tun-route-selectors-2026-11-18.json)。

| 路由与查询 | 内核结果 |
| --- | --- |
| 只有 `default tos 0x10 dev magicnet0`；查询普通流量 | 退出码 2，`Network is unreachable` |
| 相同路由；查询 `tos 0x10` 流量 | 退出码 0，选择 `magicnet0` |
| 将默认路由改为 `tos 0`；查询普通流量 | 退出码 0，选择 `magicnet0` |

下列命令可在允许非特权网络命名空间的 Linux 开发环境复查。所有接口和路由属于临时命名空间，子进程结束后随命名空间释放。

```sh
unshare --user --map-root-user --net sh <<'SH'
set -eu
ip link add magicnet0 type dummy
ip link set magicnet0 up
ip address add 192.0.2.1/32 dev magicnet0
ip route add default dev magicnet0 tos 0x10
ip -4 route show
if ip -4 route get 198.51.100.10; then
    exit 1
fi
ip -4 route get 198.51.100.10 tos 0x10
ip route del default dev magicnet0 tos 0x10
ip route add default dev magicnet0 tos 0
ip -4 route show
ip -4 route get 198.51.100.10
SH
```

## 交付与设备范围

源码、机器接口文档和联网诊断文档已同步。主仓更新了 BUILD_PROMPT、运行时合同、M70/CON-A08 验收、依赖版本和固定源码引用。开发机源码与配方仓库均已快进同步，工作区干净。已有 Zashboard 界面提交保留在修复的父提交历史中。

本轮手机只读采样显示安装版本为 v1.8.9 / 10617，核心运行、TUN 路由为 present，缓存联网检查为 online。发布索引仍为 v1.9.0 / 10618。本轮证据覆盖源码、真实 CLI 进程和隔离 Linux 内核选路；Android 新包安装、ARM64/OEM 换网与此前 #436 的路由丢失触发原因继续需要受控真机验收。

## 交付复核

| 复核维度 | 结论与证据 |
| --- | --- |
| 修复目标 | 明确解决条件路由造成的假绿；旧代码失败回归与内核选路实测对应 |
| 表达与复现 | 给出准确字段、提交、命令和预期结果 |
| 实验有效性 | 普通流量、匹配流量和零值对照分别验证 |
| 覆盖范围 | 覆盖共享观察器、机器投影与 CLI 恢复路径，设备范围单独记录 |
| 实现复杂度 | 复用既有解析器和状态，保留零值语义与原恢复预算 |
