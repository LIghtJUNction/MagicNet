# MagicNet：节点恢复与全部手机页面迭代

整理时间：2026-11-19 02:58（Asia/Taipei）。这是实现与验证记录，本轮没有创建或覆盖公开 Release。

**全部 14 个手机页面已完成改版，并已把最终版本的 77 个页面资源文件更新到手机；有效节点从 2 个恢复为 27 个。** 最终源码为 `75da8b3`，本地完整包 v1.9.1 / 10619 已通过构建及安装迁移检查，也已由 KernelSU 成功暂存。当前代理继续运行，数据面就绪；普通应用的 Google / Cloudflare 严格 HTTPS 204 复验均通过。

**完整模块仍待手机正常重启后激活，最终 14 页的真实 WebView 逐页点击检查尚未完成。** 手机现场存在同时进行的手动操作，因此停止了前台自动点击。页面文件更新、正常安装暂存、当前联网与重启后验收分别记录。#436 的严格物理实验结论继续保持 **`NOT_VERIFIED`**。

| 对象 | 固定身份与范围 |
| --- | --- |
| 最终源码 | [`75da8b3064350dd335844da1957cd45b6c347f9c`](https://github.com/LIghtJUNction/magicnet-android/commit/75da8b3064350dd335844da1957cd45b6c347f9c) |
| 源码 tree | `c12d49b393ee718d2f2340dcabec93db517396cb` |
| 主仓实现与配方集成 | [`921d490746f51e9dfc961c37721980fb76a591e3`](https://github.com/LIghtJUNction/MagicNet/commit/921d490746f51e9dfc961c37721980fb76a591e3)；gitlink 固定到最终源码 |
| 固定核心 | `LIghtJUNction/sing-box@3a155d21872b22e6b9b75326c98d11f7ff159a2e` |
| 导航验收 | [导航报告](https://github.com/LIghtJUNction/MagicNet/blob/921d490746f51e9dfc961c37721980fb76a591e3/docs/navigation-2026-11-19.md) · [导航脱敏证据](https://github.com/LIghtJUNction/MagicNet/blob/921d490746f51e9dfc961c37721980fb76a591e3/docs/evidence/navigation-2026-11-19.json) |
| 本轮完整记录 | [脱敏证据汇总](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/evidence/mobile-iteration-2026-11-19.json) |

## 1. 节点为什么只剩 2 个，以及实际修复结果

订阅进入应用要经过“读取 → 解析 → 按用户规则筛选 → 写入配置 → 展示”几个步骤。本次不是订阅只提供 2 个节点：原始数据可解析出 48 项，其中 34 项为旧式 Shadowsocks、14 项为 VMess。外部转换结果丢失了有效 SS，而 Android awk 的兼容性错误又使原生回退输出空认证字段，因此最后只剩下部分 VMess。

本轮修正共享 JSON 编码表达式，兼容设备上的 awk；转换结果中出现普通无效受支持节点时拒绝接受不完整结果，转而要求完整原生解析。公告、保留标签和用户排除规则继续生效。另修复合法方括号标签被误判为日志，以及显式空 selector 重新引入候选的问题。[节点身份修复](https://github.com/LIghtJUNction/magicnet-android/commit/920ec2be79f421db3caba0c01226b7db687768c4) · [Android awk / SS 回退修复](https://github.com/LIghtJUNction/magicnet-android/commit/43e0de3e5eab7ef22ceaf0d36ec0808b9228a78e)

| 核对阶段 | 结果 |
| --- | --- |
| 原始可解析条目 | 48 |
| 原有排除规则 / 公告行 | 19 / 2 |
| 应保留条目 | 27 |
| 修复后当前配置 / 最终暂存配置 | 25 Shadowsocks + 2 VMess |
| CLI 实际列表 | 27，标签集合与当前配置一致 |

设备 awk 对照还确认：修复前存在语法错误且认证字段为空；修复后认证字段、端口和完整性检查有效，stderr 为空。这里验证的是导入与展示完整性，不能据此推断全部 27 个出口的公网连通性。

## 2. 14 个页面都按手机任务重新组织

第一阶段 `1731973` 完成首页、112px 服务主按钮、底部导航和左侧抽屉；该阶段 CLI/WebUI 已热更新到真实 KernelSU WebView，73 个文件哈希核对通过。第二阶段 `a5062e1` 扩展到全部页面。`adbfe716` 与 `6c71b1a` 随后修正重排页面后的测试定位和前置条件，相关历史结果按各自批次保留。[首页与导航](https://github.com/LIghtJUNction/magicnet-android/commit/1731973da7a93573602a264be6b334fb80d15ee0) · [全页改版](https://github.com/LIghtJUNction/magicnet-android/commit/a5062e1c5f7f773d0b857b5fdb257f2110fe815b)

导航的最后两次提交包含实际代码修复。`4110fc9a` 让选中的导航入口在布局变化后保持可见；`75da8b3` 进一步按实际滚动区域计算边界，向外取整并保留 1px 内缩，观察侧栏尺寸变化，同时关闭影响高度测量的过渡。两提交之间只改动 `App.vue` 和 `styles.css`。最终版本包含这部分导航行为修正及对应的定向验证。[导航修复](https://github.com/LIghtJUNction/magicnet-android/commit/4110fc9a31e57ea76d080e1971e1251220b9548d) · [最终两文件差异](https://github.com/LIghtJUNction/magicnet-android/compare/4110fc9a31e57ea76d080e1971e1251220b9548d...75da8b3064350dd335844da1957cd45b6c347f9c)

| 页面 | 主要变化 |
| --- | --- |
| 概览 | 服务操作、真实运行状态、模式、延迟与内存组成首屏；未知和未就绪指导保留 |
| 节点与代理组 | 当前选择、搜索、刷新与节点选择采用紧凑单列层级 |
| 订阅 | 来源、未保存状态和更新操作优先，编辑器与用量区分开 |
| 应用名单 | 接管模式、三类名单数量、搜索与批量选择按操作顺序排列 |
| 拦截规则 | 状态与开关优先，手动阻断/放行可直接编辑，社区缓存按需展开 |
| 链式代理 | 两跳节点采用纵向步骤，保留保存、确认和应用边界 |
| Tailscale | 真实连接状态、设备名与网页登录优先，Auth key 等低频配置收起 |
| 配置文件 | 配置类型、文件状态、操作、编辑器和校验反馈相邻 |
| Zashboard | 打开面板、读取及校验结果优先，安装修复和原始报告分层 |
| 诊断 | 健康检查、结论数量和诊断包导出优先，详细证据放在后面 |
| 终端 | 命令输入在输出之前，手机快捷命令采用两列 |
| 最近输出 | 当前命令及本次输出在前，后台任务与运行日志独立成区 |
| 工具 | 8 个工具区按网络、配置、诊断分组，保留键盘可访问折叠操作 |
| 流量路径 | 短竖向路径和实际状态在前，运行步骤、模式与技术说明按需展开 |

主操作、草稿、确认、错误与未知状态仍由原有逻辑控制。订阅页增加纯派生的 `isLocalSource` 计算属性，以消除模板检查器的生成代码类型错误，没有使用类型抑制。全页改版阶段的 14 页浅深主题截图已逐页检查；该浏览器证据不代替最终版本的真实手机页面检查。

以下是 CI 的 **390px 手机视口夹具截图**，不是真机安装证明：

[浅色 1](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/images/mobile-iteration-2026-11-19/light-1.jpg) · [浅色 2](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/images/mobile-iteration-2026-11-19/light-2.jpg) · [深色 1](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/images/mobile-iteration-2026-11-19/dark-1.jpg) · [深色 2](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/images/mobile-iteration-2026-11-19/dark-2.jpg)

## 3. 验证按提交、批次和范围记录

各批次回答不同的问题，不能相加为一个去重总数，也不能把旧提交的通过结果改记为最终提交重跑。最终导航验证来自开发机原生运行日志，现场已读回结果；日志摘要、原始失败批次和几何观测已随[导航证据](https://github.com/LIghtJUNction/MagicNet/blob/921d490746f51e9dfc961c37721980fb76a591e3/docs/evidence/navigation-2026-11-19.json)提交。

| 验证批次 | 实现或运行范围 | 实际结果 |
| --- | --- | --- |
| Rust 节点测试 | 节点身份与显式空列表修复阶段 | 12 通过 |
| 订阅脚本测试 | Android awk 与 SS 原生回退修复阶段 | 41 项：35 通过，6 可选跳过 |
| 工具构建 hook | `87ce1596`；真实 hook 的失败传播 | 8 通过，含 3 个新增场景 |
| 最终 WebUI 单元测试 | `75da8b3` 正常完整构建中的前端检查 | **399 通过、0 失败、0 跳过** |
| 全页 WebUI 类型检查 / 生产构建 | 同一全页改版阶段 | 均通过 |
| 390px + 430px 手机布局与编辑器 | 全页改版阶段，含浅深主题 | 62 通过 |
| 360px 首次完整回归 | 全页改版阶段 | 143 通过、6 失败，共 149 项 |
| 360px 定向回归 | 修正内容对应 `adbfe716`，4 个文件 | 15/15 通过，覆盖此前 6 处失败 |
| 最终导航定向回归 | `75da8b3`，6 个视口、3 个测试文件，共 78 项 | **76 通过、2 个视口条件跳过、0 失败** |
| 最终类型检查 / 生产构建 | `75da8b3` 的开发机验证 | **均通过** |
| 主仓发布与配方脚本 | gitlink 为 `adbfe716` 的隔离快照 | 18 + 42 + 19 = **79 项通过**；该计数属于此前快照 |
| 既有配方完整闭包 | 原版固定 CLI；最近一次 gitlink 为 `6c71b1a` | check → pack → archive check → build 全部通过，**8 包 / 62 Markdown** |
| 最终配方集成与闭包 | 主仓 `921d490`，源码 pin 为 `75da8b3` | **check → pack → archive check → build 全部通过，8 包 / 62 Markdown**；[记录](https://github.com/LIghtJUNction/MagicNet/blob/921d490746f51e9dfc961c37721980fb76a591e3/docs/evidence/navigation-2026-11-19.json) |

360px 的首次完整运行和后续 15 项定向运行各自保留。修正定位时仍检验当前输出、菜单、就绪提示、队列、原始数据保真、焦点、溢出和错误提示，不能将两批结果写成“同一批 149 项全通过”。[定向修正](https://github.com/LIghtJUNction/magicnet-android/commit/adbfe716057c4d910eca12ac0698005353c579ea)

GitHub 在 `adbfe716` 的较大浏览器矩阵中曾记录 **884 通过、5 失败、5 跳过**。其中 4 个失败来自长页前置或翻译标签定位，`6c71b1a` 已修正这些测试前置。剩余导航可见性问题随后由 `4110fc9a` 和 `75da8b3` 修改实际代码处理。最终的 6 视口、3 文件验证保留完整可见性与页面滚动断言；它覆盖的是本次导航修复，不等于原较大矩阵或全仓测试重新全部运行。[原始 CI 结果](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44356085163) · [前置修正](https://github.com/LIghtJUNction/magicnet-android/commit/6c71b1a3992edcff60afc9f971b102915606fc96) · [最终修复](https://github.com/LIghtJUNction/magicnet-android/commit/75da8b3064350dd335844da1957cd45b6c347f9c)

`75da8b3` 提交带有 `[skip ci]`，最终源码的证据是上述开发机定向测试与本地正常完整构建，没有宣称该 SHA 的完整 CI 全部通过。前一提交 `4110fc9a` 的 GitHub 运行已读回最终结果：

| `4110fc9a` 工作流 | 最终结果 |
| --- | --- |
| [Build MagicNet source](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44361470479) | success |
| [Network Regression Evidence](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44361470560) | success |
| [Android KernelSU Acceptance](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44361470403) | success |
| [Code Quality](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44361470363) | failure；浏览器布局/交互步骤未通过 |

这些运行属于 `4110fc9a`，其中 Android 工作流也不能代替最终版本在用户实体机上的重启后验收。

## 4. 最终整包已构建，手机已完成暂存和页面更新

工具下载失败传播已经修复。首次本地构建遇到 yq / OpenSSL 下载超时，并复现 yq 失败被后续 jq 成功覆盖退出码的问题；`87ce1596` 让任一工具安装失败立即返回非零，同时保留来源、摘要核验与原子安装。最终构建使用正常 KAM 流程和经过校验的源码缓存，没有手写成功标记或借用设备现成 ELF。[失败传播修复](https://github.com/LIghtJUNction/magicnet-android/commit/87ce15968dbf230bed76309fe54c76d1e1b6fe8a)

### 最终候选包

| 字段 | 已核验结果 |
| --- | --- |
| 文件 | `MagicNet.zip` |
| 源码 | `75da8b3064350dd335844da1957cd45b6c347f9c` |
| 版本 | v1.9.1 / 10619，本地候选身份 |
| 大小 | 104,219,361 bytes |
| SHA-256 | `61639f93bd2903d700eecb4908f26b62e0d37941ba3be27d61d818d1e08ab58c` |
| 构建与检查 | KAM 正常构建退出 0；package smoke、package install smoke 通过；安装迁移测试 22 项通过 |
| 核心 | `1.15.0-alpha.13+LIghtJUNction.3a155d21872b` |

此前 `4110fc9a` 的本地 v1.9.1 / 10619 包也已通过相同两项 smoke，大小为 104,219,272 bytes，SHA-256 为 `0415cce4dbb5220c662b70e71916824da4dd48daa6b4ef84b64fb847173f8001`。两份产物分别记录，实际手机暂存的是上表最终 `75da8b3` 包。

历史 [adbfe716 CI 构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44356085246)使用 v1.8.5 / 10613 元数据；其[外层 artifact](https://github.com/LIghtJUNction/magicnet-android/actions/runs/44356085246/artifacts/14454200379)为 128,030,673 bytes，SHA-256 为 `bf8e8b25edd6e4b9724a6f0544b01642d514cd180a1c0018d54e46a0df6f5eff`。该外层归档摘要不与本轮模块 ZIP 混用。

### 手机上的实际结果

| 操作或检查 | 结果 |
| --- | --- |
| 升级前备份 | 私有完整模块备份已验证，162,281,984 bytes / 533 成员；摘要与恢复索引留在私有记录 |
| 当前页面更新 | 仅更新 webroot，**77 个文件逐一 SHA-256 匹配**，并与独立前端构建逐文件一致 |
| 页面更新后的运行状态 | 同一次开机、同一核心 PID/starttime；当前配置、探测 REQUEST 和选择记录字节保持；dataplane / overall readiness 均为 true |
| 正常完整包安装 | KernelSU 非交互安装退出 0；新版已暂存，update 标记存在，**待正常重启激活** |
| 暂存包固定内容 | WebUI、CLI、核心及订阅脚本合计 **80 个固定文件**哈希匹配 |
| 暂存配置 | **25 SS + 2 VMess，共 27 节点**；按原始 tag 对应后，真实节点参数全部保留 |
| 升级迁移数据 | 订阅来源、本地输入、过滤规则、User-Agent、selector 选择记录、透明模式均保持 |
| 暂存后的当前服务 | 当前核心、开机身份、运行配置、REQUEST、选择记录保持；readiness 仍为 true |
| 普通应用联网复验 | 同一非 root 应用 UID：Google **672 ms**，Cloudflare **840 ms**；均为 204、0 重定向、0 响应体字节 |
| 清理 | 测试 APK `best.lmm.magicnet.probe` 已卸载；本次最终安装的 4 个中转文件及其目录已移除；备份与待激活模块保留 |

安装器会从新模板重建暂存配置，再导入用户节点；因此验收的是节点参数和用户输入的保留。当前运行配置的字节未改变，是另一个已实际比较的结果。未把旧进程状态或当前开机的探测 REQUEST 强行复制为未来开机状态。

最终 14 页的真实 WebView 逐页点击检查仍未完成。现场存在持续的手动操作，已停止前台自动点击；全页浏览器截图和 77 文件校验作为各自证据保留。当前页面文件可在重新打开 MagicNet WebUI 后加载，整包其余内容需正常重启后再验收。

## 5. #436：缺失检测与独立恢复观察成立，严格实验未通过

本次物理 runner 精确删除了本模块 2 条 IPv4 `lookup 2022` 捕获规则。注入期间核心与 TUN FIB 保持，非本模块规则未被注入步骤删除；readiness 拒绝、health 报 missing，随后观测到一次恢复尝试。

实验的关键缺口同样保留：故障阶段同一普通应用的 Google / Cloudflare 严格 HTTPS 204 仍全部成功，原问题中的应用断网没有复现。约 91.93 秒后，配置变化守卫停止了严格 runner；该数字是观察停止点，不是恢复耗时。原始结论保持 **`NOT_VERIFIED`**。[Issue #436](https://github.com/LIghtJUNction/MagicNet/issues/436)

之后独立只读观察显示：同一次开机中核心 PID/starttime 已改变；dataplane 与 overall readiness 为 true；自有捕获规则恢复；恢复计数为 1、状态为 ok；同一应用的两个严格 HTTPS 204 再次成功。这个观察支持“设备后来处于恢复后的健康状态”，不能改写严格实验结果。

配置差异仅包含 34 个 selector 的 `interrupt_exist_connections` 从缺省变为 true，以及出站定义顺序变化。按 tag 配对后，27 个真实节点参数、成员顺序、默认选择和 route.final 保持；selector 标记写入已定位到[固定 kamfw 正常启动代码](https://github.com/MemDeco-WG/kamfw/blob/a7788737b938a9ed930645befe2526b626999a22/__singbox__.sh#L184-L208)。这不证明同一函数负责排序。其他规则最终仍有 IPv4 新增/移除各 1、IPv6 新增/移除各 2 的未归因差异，OEM 自然触发原因也未确定，所以 issue 不关闭。

## 6. 延迟如何理解

首页数字是当前指定代理完成一次严格 HTTPS GET/204 的总耗时。它包含必要的解析、代理连接、TLS 和 HTTP 处理，不是单纯的 ICMP ping；现有证据没有把这些阶段分别计时，也不能把普通应用路径与指定代理探测混为同一条件。

本轮有限样本中，同一当前代理先后测得 1941 ms 和 1146 ms；3 个 SS 候选为 2215 ms、1194 ms、超时；普通应用另一次为 Google 921 ms、Cloudflare 1707 ms。先前真实首页另一个时刻显示 695 ms。它们说明路径与时刻会影响结果，不能证明界面改版使网络普遍更快；没有自动切换用户选中节点来制造更低的数字。

最终暂存与页面更新后的普通应用复验，另录得 Google 672 ms、Cloudflare 840 ms，均满足严格 204 判据。这是这一次应用路径的成功样本；它没有分离 DNS、连接和 TLS 各阶段，也不构成普遍提速结论。

## 7. 交付与尚未完成的验收

产品配方为 **0.3.35**、web 为 **0.2.13**、control 为 **0.2.15**，本轮新增要求覆盖 M79–M83，并同步了最终导航契约。主仓 `921d490` 的 gitlink、可复用发布工作流、三个 README 与依赖记录已固定到 `75da8b3`；最终 8 包 / 62 Markdown 闭包通过。

交付入口：

- [本轮完整报告](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/mobile-iteration-2026-11-19.md)
- [脱敏验证记录](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/evidence/mobile-iteration-2026-11-19.json)
- [导航修复报告](https://github.com/LIghtJUNction/MagicNet/blob/921d490746f51e9dfc961c37721980fb76a591e3/docs/navigation-2026-11-19.md)
- [Google 云盘 MagicNet 目录](https://drive.google.com/drive/folders/1l506lcpZnJS-42-bpKHdk4W8yiAZenrc)，保存本报告 Markdown 与脱敏 JSON 副本

剩余验收有明确边界：手机空闲时正常重启，确认暂存模块已激活，再完成最终 14 页真实 WebView 检查、27 节点与普通应用联网复验；#436 则需要复现原先的应用断网，并在同一冻结配置下得到完整恢复证据后才能结案。截至本次核对，主仓只剩 #436 一个 open issue，源码仓没有 open issue。

真实订阅、节点名、认证字段、原始配置、设备标识和私有备份内容不进入公开仓库或云盘报告。页面预览使用浏览器夹具，设备结果只发布脱敏计数、固定产物身份与可复核的结论。
