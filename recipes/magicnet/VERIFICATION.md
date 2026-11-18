# 实现与发行验证

更新日期：2026-11-18。文档整理基准为主仓 [`5094b8ad`](https://github.com/LIghtJUNction/MagicNet/commit/5094b8adffddd89547b5d198fcbf998546914842)；以下每组结果均绑定自己的源码与运行记录。

## 当前版本与证据范围

| 对象 | 固定版本与范围 |
| --- | --- |
| 当前主仓配方 | MagicNet `0.3.33` / network-runtime `0.1.20` |
| 当前 gitlink | [`a97467513e5f3c9842b470112f31a961e2bc99b0`](https://github.com/LIghtJUNction/magicnet-android/commit/a97467513e5f3c9842b470112f31a961e2bc99b0) |
| 固定核心 | `3a155d21872b22e6b9b75326c98d11f7ff159a2e` / `1.15.0-alpha.13` |
| 公开稳定版 | [v1.9.1 / 10619](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.9.1)，源码 `5169e07155a47d16f3c5e610a8aa368cc2d08b02` |
| 真机验收候选 | 同版本、同源码的本地构建；一台 ARM64 手机 |

当前 gitlink 已包含发布之后的并发修复。公开 v1.9.1 与本轮手机候选均固定在 `5169e071`；较新源码的验证结果只适用于其自身。

## 当前 main 的并发迭代

`2a7dcddd` 修复无关目的范围的条件路由污染 TUN 证据，以及排队手动检查阻止核心退出后的后台清理；相交范围中的未知条件仍为 unknown，手动命令自身不执行清理。修改前失败、修改后通过的用例及 83 项源码 / 79 项配方与发布工具检查见[范围与恢复边界报告](../../docs/network-recovery-boundaries-2026-11-18.md)。

随后热点观察改为核对配置所需的 IPv4 路由范围，`6d67ce0d` 恢复规范表号参数；`a9746751` 将未过期 TUN 缓存绑定当前核心 PID/starttime，身份不符或不可读时显示 unknown。78 项源码与 19 项配方检查器测试、完整主机 fake Magisk 流程、Clippy、fmt、actionlint 和 8 包 / 62 份 Markdown 配方流程通过，详见[报告](../../docs/tun-generation-hotspot-gate-2026-11-18.md)与[JSON 证据](../../docs/evidence/tun-generation-hotspot-gate-2026-11-18.json)。

以下为 `a9746751` 在 **2026-11-18 11:41 UTC** 读取的 CI 快照；后续状态见各运行链接，运行中不计为通过。

| 工作流 | 快照状态 |
| --- | --- |
| [Network Regression Evidence](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44293729835) | success |
| [Code Quality](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44293729890) | failure，另行定位 |
| [Build MagicNet source](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44293729943) | success |
| [Android KernelSU Acceptance](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44293729877) | in_progress |

较早 `2a7dcddd` 的 [Build](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44286014957)、[Quality](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44286015161)、[Network](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44286015133) 已 success，[Android](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44286015001) 为 cancelled。主仓配方集成 `896c8134` 的 [Recipe checks](https://github.com/LIghtJUNction/MagicNet/actions/runs/44295084605) 已 success；这些状态按 11:33 UTC 读取结果记录。

## 正式 v1.9.1 / 10619

[正式发布运行 44281871820](https://github.com/LIghtJUNction/MagicNet/actions/runs/44281871820) 固定主仓 `6b5524d3a64cbcaa13d8a383075d7eeaa32a22a2` 与源码 `5169e071`，不可变发布配方快照为 `d9f6f1546f519d1b1ccbe4ba505936506ff3a9ab`；attempt 2 最终 success。公开版本于 2026-11-18 11:22:48 UTC 发布。

同一源码的首轮 [Code Quality](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44280408002)、[Build](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44280408154)、[Network](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44280407987) 和 [Android](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44280408107) 均 success。

WebUI 实际通过 **399 项单元测试、typecheck、build，以及 865 项浏览器测试**；另有 **5 项既有视口条件跳过，0 失败**。浏览器覆盖手机、横屏和桌面；跳过项不计为通过。

正式 Android 首轮在故障注入前失败：UDP 基线 `baseline_app_not_captured`，5 秒超时、accepted=0；当时未删除路由规则、未执行恢复 tick。此失败保留于[首轮 artifact](https://github.com/LIghtJUNction/MagicNet/actions/runs/44281871820/artifacts/14418092905)，首轮未通过发布门禁。

保持源码、测试断言和超时不变，仅定向重跑失败的 Android job **一次**。第二次 **13/13 阶段、5/5 重启通过**；UDP 基线 6 ms / accepted=1，路由缺失被观察后在一次有界恢复内回到 present，应用连通性和上行重连验证通过，夹具恢复完成。随后 verify 与 publish 通过，见[第二次 artifact](https://github.com/LIghtJUNction/MagicNet/actions/runs/44281871820/artifacts/14421184121)。

同源码 source Android 首轮也通过，UDP 基线 7 ms / accepted=1，见[对照 artifact](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44280408107/artifacts/14418811244)。重跑成功没有确定正式首轮 UDP 超时的根因；两次结果均保留。

公开 [MagicNet-full.zip](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.9.1/MagicNet-full.zip) 为 **61,429,074 字节**，SHA-256：
`a3a6fae7c3959bdd40cbec8abd554337d289fbeca4da15c816dba48b76e6120a`。无认证实际下载的 HTTP、SHA256、364 文件 CRC 与来源核对见[公开下载证据](../../docs/evidence/publication-verification-v1.9.1.json)。

## 一台 ARM64 手机的验收候选

本节对应源码 `5169e071` 的本地 `v1.9.1 / 10619` 构建。已核对 CLI/core 哈希与构建记录一致；未将该本地 ZIP 与公开发布 ZIP 宣称为逐字节相同。

| 验收项 | 已观察结果 |
| --- | --- |
| 升级与配置 | 版本生效，原有配置保留 |
| 真实订阅与普通应用 UID | Google / Cloudflare HTTPS 返回 204；新鲜 strict/selected 与 mixed 观察 online，TUN 为 present |
| 导航 | 14 页导航已在手机检查 |
| Zashboard | 首屏按钮物理点击成功，Chrome 打开回环面板并携带 hostname/port；页面中的 3 个节点与本地 API 数据匹配，未公开名称 |
| 蜂窝中断 / 恢复 | 断开 10 秒后恢复，180 秒 / 13 次状态采样保持 TUN present；末尾应用两目标 204，但严格探测 degraded，因此整项保留 needs_review |

手机最初一次 Cloudflare 请求 connect timeout，随后同一普通应用 UID 使用默认与 IPv4 请求均返回 204（约 0.95 s / 0.84 s），未更换节点。该暂态失败的原因尚未确定。

前两次蜂窝实验因后台 Chrome UID 的 DNS 基线失败而在断网前中止；补充 INET 组无效。仅恢复 Chrome 前台、无 root 目标预热后，同命令取得两目标 204，说明该 UID 探针受前后台状态影响，具体系统策略未确定。最终实验在每组应用探针前确认 Chrome 前台。断网与 180 秒观察完成，末尾 Google / Cloudflare 分别为 204（1.39 s / 0.45 s），网络设置复原；严格所选代理探测为 degraded / endpoint_specific、mixed 为 online，原始 outcome 保持 needs_review。未观测到 TUN 规则丢失或自动恢复，不将此结果写为 #436 已修复。详见[本轮报告](../../docs/releases/v1.9.1.md)和[脱敏设备证据](../../docs/evidence/magicnet-v1.9.1-device.json)。

跨 OEM、最低 Android/WebView 版本、长期运行、持续性能与耗电仍未覆盖。[#436](https://github.com/LIghtJUNction/MagicNet/issues/436) 的换网触发根因和真机实际丢规则后的恢复仍开放；模拟器故障注入与本次未触发规则丢失的手机重连分别计证据。

## 历史记录与复查

压缩前的全部日期记录、旧版本、失败、计数、哈希和历史索引保存在[固定基准全文](https://github.com/LIghtJUNction/MagicNet/blob/5094b8adffddd89547b5d198fcbf998546914842/recipes/magicnet/VERIFICATION.md)。该链接指向不可变提交，旧记录中的“当前”仅表示当时的状态。

实现与发布操作见[源码构建指南](../../generated/magicnet-android/docs/build.md)、[发布指南](../../docs/releasing.md)和 [v1.9.1 说明](../../docs/releases/v1.9.1.md)；配方来源与许可见 [PROVENANCE](PROVENANCE.md)。各并发修复的精确源码复查命令保留在上方报告中。

主仓基本复查：

```bash
python3 scripts/check-recipes.py
python3 scripts/test-release.py
python3 scripts/test-release-plan.py
python3 scripts/test-check-recipes.py
bash scripts/check-workflows.sh
```
