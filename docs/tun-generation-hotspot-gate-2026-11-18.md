# MagicNet 热点观察与 TUN 缓存代际迭代报告

日期：2026-11-18（Asia/Taipei）。CI 快照：2026-11-18 19:30:12（UTC+08:00）。

## 交付结果与版本

本轮修复热点查询参数回归，以及核心重启后 TUN 缓存仍可能显示旧核心状态的问题。两项修复均有修改前失败、修改后通过的证据。源码分两次提交推送，主仓同步配方、依赖、工作流和源码固定点；集成时保留了并行发布的 v1.9.1 索引。

| 对象 | 固定点 |
| --- | --- |
| 热点参数修复 | [6d67ce0d](https://github.com/LIghtJUNction/magicnet-android/commit/6d67ce0df8e4dac896e58706e4af6b20f4aff833) |
| 最终源码与缓存代际修复 | [a9746751](https://github.com/LIghtJUNction/magicnet-android/commit/a97467513e5f3c9842b470112f31a961e2bc99b0) |
| 最终源码 tree | `e5accaaba9ed2d4a81743c9d7e3987be42a9fdc8` |
| 主仓集成 | [896c8134](https://github.com/LIghtJUNction/MagicNet/commit/896c813424be189c2fee8cc906e981d1cc6f0132) |
| 产品 / 网络运行时配方 | `0.3.33 / 0.1.20` |
| 当前公开稳定版 | [v1.9.1 / 10619](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.9.1) |

公开 v1.9.1 的发布说明固定源码为 `5169e07155a47d16f3c5e610a8aa368cc2d08b02`，发布于台北时间 19:22:48。本轮两个新提交尚未包含在该安装包中，本轮也没有另行发布版本。结构化记录见 [JSON 证据](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/evidence/tun-generation-hotspot-gate-2026-11-18.json)。

## 热点观察：恢复规范参数，让独立夹具发现真实差异

基线 `ada4f32f` 已将热点 IPv4 就绪判断改为按有效配置的必要范围核验 FIB，本轮保留这项进展。其查询代码却把表号参数从 `"2022"` 改成了 `" 2022"`。单元夹具复制了这个空格，新的 CLI 夹具还同时接受两种写法，因此小测试没有发现差异。

独立 fake Magisk 内核模型只匹配规范表号，错误参数得到空路由输出，机器热点状态无法成为 active。原 [构建运行 44288240688](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44288240688) 因此在 Verify artifact contents 的热点状态断言失败。

修复恢复规范 argv，并同时收紧两个小夹具，保留独立内核模型与 active 断言。修复生产代码前，严格单元用例以 exit 101 报告错误参数，9 项热点 CLI 用例也全部失败；修复后网络观察组 8 项、热点 CLI 组 9 项通过。完整 `fake-magisk-smoke.sh` 随后以 exit 0 结束，耗时 282.77 秒，覆盖源码目录模式的模拟生命周期。

开发机 iproute2 7.3.0 对两种参数均返回 exit 0，且输出一致。因此，本轮证据证明的是非规范参数造成验证环境与实现不一致，不能据此宣称所有 Android 手机都会拒绝带空格参数或发生热点断网。

## TUN 状态：缓存证据必须属于当前核心

原观察器已经保存核心 PID 与启动时间，并用它们区分恢复计数的代际；只读 JSON 投影却只确认“存在正整数 PID”。核心 A 退出、核心 B 接替后，下次正常观察尚未执行时，A 的 present 仍可能被显示成 B 的状态，且 warning=false。多个核心同时出现时也有同类问题。

PID 可以被重新分配，因此只比较 PID 不足以确认仍是同一个进程。本轮对未过期的 present/missing 缓存，同时核对当前单一已归属 PID 与实时启动时间。PID 更换、同 PID 不同启动时间、保存身份缺失、多个 PID 或身份不可读时，投影为 unknown 并给出警告。

既有前置顺序保持：停止或停用优先为 paused，时钟或进程摘要不可用为 unknown，逾期证据优先为 stale；这些路径不会额外读取进程身份。not_required 不进入启动代际核对，但仍受前置状态覆盖。普通同代际缓存继续可读。读取复用已知归属摘要，不再扫描归属，不发起网络或路由探测，不写 canonical、不调整失败计数或恢复预算，也不公开 PID/starttime。

新增代际回归在修改前实际得到 present、预期 unknown，cargo exit 101。修复后 TUN 组 11 项通过；完整 connectivity_runtime 28 项通过。新增 3 个内部用例覆盖代际矩阵、身份读取失败及状态优先级，另有 1 个真实 CLI 用例同时检查 connectivity.status 与 service.status.data.connectivity，并核对状态文件原始字节、预算、探测次数和动作记录保持。

## 本地验证与复查

| 验证组 | 通过数 |
| --- | ---: |
| 内核网络观察单元测试 | 8 |
| 热点机器状态 / canonical CLI 回归 | 9 |
| TUN 恢复与缓存代际单元测试 | 11 |
| 连通性其余单元测试，排除上述 TUN 组 | 22 |
| 完整连通性运行时 CLI 夹具 | 28 |
| 配方检查器测试 | 19 |
| 合计 | 97 |

97 项由 78 项源码测试与 19 项配方检查器测试组成，参数组合和重复执行不重复计数。Clippy 全目标检查、格式检查、git diff 检查、actionlint，以及 8 包 / 62 份 Markdown 的完整配方检查、打包、归档检查和提示词生成均通过。Clippy 的较长总耗时包含开发机共享编译锁等待，不代表测试执行耗时。

先按仓库固定 gitlink 初始化配置与 kamfw，再在源码目录复查：

```bash
git submodule update --init -- src/MagicNet/.config/sing-box src/MagicNet/lib/kamfw
cargo test --locked -p magicnet-cli --bin magicnet-cli network_observation::
cargo test --locked -p magicnet-cli --test hotspot_observation
cargo test --locked -p magicnet-cli --bin magicnet-cli connectivity::tun::tests
cargo test --locked -p magicnet-cli --bin magicnet-cli connectivity:: -- --skip connectivity::tun::tests
cargo test --locked -p magicnet-cli --test connectivity_runtime
cargo clippy --locked -p magicnet-cli --all-targets -- -D warnings
cargo fmt --all -- --check
bash scripts/fake-magisk-smoke.sh
```

fake Magisk 脚本还要求其声明的宿主工具，包括 sing-box、jq 等。本轮使用源码目录模式，没有传入 ZIP；这项结果不替代新生产 ZIP 的内容验收或 Android 设备结果。

配方主仓复查：

```bash
python3 scripts/check-recipes.py
python3 scripts/test-check-recipes.py
bash scripts/check-workflows.sh
git diff --check
```

## CI 快照、集成与剩余范围

以下状态对应最终源码 `a9746751`，截取于 2026-11-18 19:30:12（UTC+08:00）。工作流均由正常推送触发。

| 工作流 | 快照状态 |
| --- | --- |
| [Network Regression Evidence](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44293729835) | success |
| [Code Quality](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44293729890) | in_progress |
| [Build MagicNet source](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44293729943) | in_progress |
| [Android KernelSU Acceptance](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44293729877) | in_progress |

主仓集成保留 [4bbe8da8](https://github.com/LIghtJUNction/MagicNet/commit/4bbe8da8586544e4c8c1ae502610b86d95f6396f) 中 v1.9.1 的 update.json 和发布说明原字节。三语 README 同时保留新发布索引并指向本轮新配方与源码，变基后重新通过完整配方检查。已有并行工作区保持，工作已转入用户指定的新会话继续。

本轮没有新的真机验收、安装或发布。尚在运行的 CI 不计为通过；热点范围观察、主机模拟流程与真实设备联网分别记录。[#436](https://github.com/LIghtJUNction/MagicNet/issues/436) 的 OEM 路由消失根因仍需受控设备证据，本轮修复不能证明所有网络切换故障已经解决。

## 复核记录

| 维度 | 结论 |
| --- | --- |
| 改动贡献 | 一个有 CI 失败证据的热点参数回归，一个能先复现的缓存代际误报 |
| 表述清晰度 | 区分规范参数差异、缓存身份、恢复动作与已发布版本 |
| 实验强度 | 严格夹具、真实 CLI、完整主机模拟流程和静态检查 |
| 覆盖范围 | 明确同代际、PID 复用、未知身份及状态优先级，分别报告主机与 CI |
| 设计一致性 | 独立只读复核通过；保留文件状态、隐私、预算和既有接口字段 |
