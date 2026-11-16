# MagicNet v1.8.9 维护与发布验收

**MagicNet v1.8.9（versionCode 10617）已正式公开发布。** 完整发布工作流成功，20 个附件均已上传；公开下载与稳定索引回读通过，完整离线包中的 171 个组件文件已逐项核验。

本轮完成了 CI 阻断修复、sing-box fork 与规则更新、兼容依赖刷新，以及规则安装和版本来源的局部精简。最终维护源码为 `c5a13686`，其构建、代码质量、网络回归和 Android 验收四条工作流全部成功。以下分别记录源码、发行快照与公开下载证据。

## 一、发行身份与证据入口

正式版本为 **v1.8.9 / versionCode 10617**。主仓库保存配方、发布计划与源码固定引用；独立源码仓库提供实际实现。发布快照冻结本轮版本和源码身份，后续维护报告提交不会改变这份快照对应的安装包。计划依据为[本轮 release-plan.json](https://github.com/LIghtJUNction/MagicNet/blob/81e558051819dc3a8b61c0aaa5c37b421d4808f8/release-plan.json)。

| 对象 | 固定身份 |
| --- | --- |
| 维护源码 | [c5a1368639da929ae619a5a74444dc79e657618a](https://github.com/LIghtJUNction/magicnet-android/commit/c5a1368639da929ae619a5a74444dc79e657618a) |
| 源码 tree | `2a403c8ed096eff8fd354840f81d71b35922453f` |
| 主仓库发布基线 | [2bb8399993bc4e30205d543dff1df0a58a50c490](https://github.com/LIghtJUNction/MagicNet/commit/2bb8399993bc4e30205d543dff1df0a58a50c490) |
| 不可变发行快照 | [81e558051819dc3a8b61c0aaa5c37b421d4808f8](https://github.com/LIghtJUNction/MagicNet/commit/81e558051819dc3a8b61c0aaa5c37b421d4808f8) |
| 正式发布运行 | [43936244947](https://github.com/LIghtJUNction/MagicNet/actions/runs/43936244947) |
| 公开发行页 | [MagicNet v1.8.9](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.9) |
| 公开发布时间 | 2026-11-17 03:49:59（UTC+8；`2026-11-16T19:49:59Z`） |
| 公开下载验收时间 | 2026-11-17 03:52:24（UTC+8；`2026-11-16T19:52:24.809219+00:00`） |

源码 SHA、versionCode 和发布快照分别回答三个问题：代码来自哪个提交、模块管理器怎样判断升级次序，以及这次发行究竟把哪份代码与哪个版本组合在一起。公开下载后的来源文件和包内模块元数据需要同时对应这份计划；仅核对一个显示版本号无法建立完整的产物对应关系。

## 二、实际失败原因与修复

### 下载成功响应中包含了错误内容

旧 zlib 下载端点返回 HTTP 200，但内容是 HTML 页面，原 SHA-256 校验因此拒绝继续构建。HTTP 状态描述请求结果，归档的摘要才约束本次构建应使用的具体字节。此次改为审核过的官方 GitHub Release 资产；缓存命中也重新检查摘要，损坏缓存重新获取，新下载只有校验成功才替换缓存。错误页面与错误摘要继续使构建失败。[失败日志](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43916363849/job/133471990323)、[构建输入修复](https://github.com/LIghtJUNction/magicnet-android/commit/89a86a2ba75035d71845592f29946797b9436bdd)。

curl、OpenSSL、zlib 与内嵌 CA 的构建和验收现在读取同一组固定输入。证书包的摘要、字节数和证书数由同一锁文件提供，减少手写预期值与构建内容不同步的机会。CA 仍需从实际构建的 curl 导出核对，TLS 成功和拒绝对照继续执行；更新版本号本身不代表已经取得这些运行证据。

### 创建草稿后立即查列表，未找到刚创建的发行

此前发行在构建、Android 和资产门禁之后，因创建草稿后再次列举发行时未找到该草稿而终止。发布器现在使用创建响应直接返回的数字 release ID，继续完成上传、摘要核验和公开步骤。源码、运行、artifact、版本及目标提交等身份约束保持有效，已存在资产仍按恢复规则核验。新增回归覆盖列表暂未出现新草稿的情况。[原失败步骤](https://github.com/LIghtJUNction/MagicNet/actions/runs/43916818151/job/133507075123)、[发布器修复](https://github.com/LIghtJUNction/MagicNet/commit/15ec79eaf224c8c245b959c239e11cb2171aa2c9)。

### 新版 eCapture 的合法 ELF 格式被旧描述词检查误拒绝

eCapture 2.11.0 的官方 Android ARM64 文件采用静态 PIE 格式。原检查依赖 `file` 输出中的特定文字，新格式的描述没有命中原条件。新的验证器直接检查 ELF 的架构、程序入口、解释器和动态依赖：接受符合要求的 Android 动态程序与静态可执行程序，拒绝错误架构、GNU 解释器、存在外部动态库依赖的无解释器文件及普通共享库。真实官方资产与正反例均用于验证。[ELF 修复与回归](https://github.com/LIghtJUNction/magicnet-android/commit/d9995229e10d5552ae278f7b497f4078dc590973)。

TLS/GoTLS 的命令构造同时明确选择 eCapture 的 `hook` 文本来源，以适配上游默认值变化。现有时长、输出限制和进程过滤继续参与命令构造。这里取得的是参数兼容与无效输入行为的测试证据；抓取实际用户流量不属于本轮验证范围。[兼容修复](https://github.com/LIghtJUNction/magicnet-android/commit/1acb1f431da97a834b5a32901e02155ca285654b)。

### 生产版本更新后，模拟器与界面仍引用旧发行

候选运行在准备 x86_64 载荷时，发现 eCapture 模拟器固定值仍为 2.5.2，与生产 2.11.0 不一致。该一致性门禁正确阻止了继续发布。此次单独审核了 2.11.0 的 Android amd64 归档和摘要，并增加当前版本通过、生产版本失配提前拒绝、坏摘要拒绝三个行为回归，使这类遗漏能在早期合同检查中被发现。[原阻断步骤](https://github.com/LIghtJUNction/MagicNet/actions/runs/43931861481/job/133527040021)、[消费者同步修复](https://github.com/LIghtJUNction/magicnet-android/commit/c5a1368639da929ae619a5a74444dc79e657618a)。

同次检查还同步了两条实际消费路径。AVD 的 yq 构建直接读取生产 release lock，消除独立维护的旧版本号；WebUI 的 Zashboard 默认与候选下载更新到 3.30.0，并分别验证普通包和无字体包的摘要。夹具脚本固定 C locale，避免中文主机上的 `readelf` 字段翻译影响架构判断。完整载荷准备脚本已经实跑成功，保留下载前版本审查和下载后摘要校验。

跨架构同步要求同一上游版本，但两种架构的文件各自拥有不同字节和摘要。ARM64 生产资产通过校验后，仍须独立审核 amd64 模拟器资产；将两个文件强行共用一个摘要会失去验证意义。此次固定值同步保留了这种区分，并通过早期测试保证生产版本变更时，未审核的模拟器输入不能静默继续执行。

## 三、更新后的依赖与规则

下列数值对应本轮固定源码和发行快照。外部压缩包、可执行文件及证书输入均保留审核摘要，完整记录见[外部资产表](https://github.com/LIghtJUNction/MagicNet/blob/81e558051819dc3a8b61c0aaa5c37b421d4808f8/recipes/magicnet-module-delivery/EXTERNAL_ASSETS.md)；前端声明和 Rust 实际解析版本分别见 [package.json](https://github.com/LIghtJUNction/magicnet-android/blob/c5a1368639da929ae619a5a74444dc79e657618a/webui/package.json) 与 [Cargo.lock](https://github.com/LIghtJUNction/magicnet-android/blob/c5a1368639da929ae619a5a74444dc79e657618a/Cargo.lock)。

| 范围 | 本轮固定值或处理 |
| --- | --- |
| sing-box fork | [5604500d](https://github.com/LIghtJUNction/sing-box/commit/5604500d0b894af3b6fbc3c48a4ee71c1ff0e167)，基础版本 1.15.0-alpha.13 |
| 规则发行 | `rules-20261116-df4863416dd56ad6` |
| HTTPS 构建 | curl 8.23.0、OpenSSL 3.5.9 LTS、zlib 1.4 |
| Mozilla CA | 2026-11-05，200116 字节、118 个证书 |
| eCapture | 2.11.0；生产 ARM64 与 AVD amd64 分别固定资产及摘要 |
| 工具 | yq 4.54.3；jq 保持经核对的 1.8.2 |
| Zashboard | 3.30.0；默认无字体包，界面同时提供经审核的普通包候选 |
| WebUI 基础 | Vue 3.5.45、Vite 8.3.8、Tailwind 4.3.5、KernelSU SDK 3.3.0 |
| WebUI 相关依赖 | plugin-vue 6.0.11、highlight.js 11.12.0、tailwind-merge 3.7.0、vue-tsc 3.3.14 |
| 测试与类型工具 | Playwright 1.65.1；TypeScript 声明范围为 `^5.9.3`，沿用 5.x 兼容范围 |
| Rust 解析版本 | cfg-if 1.0.5、itoa 1.0.19、libc 0.2.191、serde_json 1.0.154、syn 3.0.10、unicode-ident 1.0.27、zeroize 1.9.1 |

fork 本次新增的是两个 CI 修复提交，基础协议版本仍为 1.15.0-alpha.13；本报告不将其描述为新增协议能力。规则数据使用新编译发行，规则配方提交保持原有固定身份。实际校验覆盖全部 116 个 SRS 文件，默认模板安装了 54 个规则文件和对应 marker；文件数量不能换算成单条网络匹配规则数量。[规则集成提交](https://github.com/LIghtJUNction/magicnet-android/commit/98634f6a89df2d4aede5033028f35df07009250c)。

## 四、代码精简的实际范围

规则安装将重复的文件内容比较合并到一次判定。未变化的文件不重写，损坏的已安装文件仍会修复，版本 marker 继续与结果对应。这样减少了重复比较与分支维护，同时保留安装语义；对应行为由规则和下载回归覆盖。

构建与验证中的版本来源也做了收敛：AVD yq 读取生产锁，CA 验收读取构建锁，ARM64 ELF 验证读取文件结构。每项调整都针对已观察到的重复来源或格式依赖，便于以后更新依赖时发现遗漏。Rust 和前端锁文件的自动去重不用于推导启动、内存或吞吐提升，本轮没有相应性能测量结论。

## 五、验证结果与适用范围

### 已完成的 CI

最终源码的四条工作流均已成功，结果对应同一提交 `c5a13686`。主仓库的 Recipe checks 也已通过。正式发布使用独立发行快照执行自己的构建和 Android 门禁，不能用源码仓库的成功记录代替该运行的最终结论。

| 工作流或门禁 | 结果与证据 |
| --- | --- |
| 源码构建 | 成功：[43935993029](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43935993029) |
| Code Quality 与最终 CI Quality Gate | 成功：[43935993061](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43935993061) |
| Network Regression Evidence | 成功：[43935993063](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43935993063) |
| 源码 Android / KernelSU 验收 | 成功：[43935993201](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43935993201) |
| 主仓库配方与固定引用 | 成功：[43936177060](https://github.com/LIghtJUNction/MagicNet/actions/runs/43936177060) |
| 发行快照 Android 验收 | 成功：[Android job](https://github.com/LIghtJUNction/MagicNet/actions/runs/43936244947/job/133542733823)、[Simulation Gate](https://github.com/LIghtJUNction/MagicNet/actions/runs/43936244947/job/133559656662) |
| 正式构建及 Release quality gate | 成功，Release quality gate 耗时 20 分 18 秒：[build job](https://github.com/LIghtJUNction/MagicNet/actions/runs/43936244947/job/133542168020) |
| 最终资产验证、公开发行与稳定索引同步 | 全部成功：[正式发布运行](https://github.com/LIghtJUNction/MagicNet/actions/runs/43936244947) |

### 本地与定向验证

下表按测试范围记录结果；部分用例会在完整 CI 中再次执行，不能将各行简单相加作为独立测试总数。依赖阶段的 Rust 数字保留其阶段身份，最终代码的质量结论由上表工作流提供。原始维护记录见[本轮验收记录基线](https://github.com/LIghtJUNction/MagicNet/blob/2bb8399993bc4e30205d543dff1df0a58a50c490/docs/maintenance-2026-11-17.md)。

| 范围 | 已取得的证据 |
| --- | --- |
| 发布计划 | 42 项通过，含新草稿尚未出现在列表中的恢复路径 |
| 规则及下载器 | 20 + 6 项通过；规则实物摘要和默认模板安装核验通过 |
| WebUI | 392 项通过，类型检查、构建、npm/Bun 冻结锁检查通过；当轮 npm audit 返回 0 漏洞 |
| Rust 依赖更新阶段 | 873 个单元测试、68 个集成测试通过，1 个既有 ignored；严格 Clippy 通过 |
| eCapture 参数兼容 | 9 项通过，覆盖命令参数及无效输入无副作用 |
| curl 与模拟器合同 | 13 + 114 项通过；实际内嵌 CA 的 4 项定向检查通过 |
| Android ELF | 14 项通过，包含真实新版 eCapture static PIE 和拒绝错误输入的对照 |
| AVD 工具与工作流 | 33 项通过；完整载荷准备、固定 Proxylink 构建和 yq 4.54.3 实际构建通过 |
| Dashboard 候选 | 两种 3.30.0 ZIP 的实际 SHA-256、ZIP 完整性通过；类型检查与私密载荷合同通过 |
| 配方材料 | 八包、62 份 Markdown 的 check、pack、归档检查及完整构建提示词生成通过 |

新增 AVD 回归由真实准备脚本执行到下载边界，观察返回码、下载器调用、后续 Git 构建调用及输出目录状态。当前审核版本应请求对应的 amd64 归档；模拟生产版本失配时应在网络请求前拒绝；模拟下载内容错误时应在提取和构建前停止。这些对照验证的是失败边界，使未来更新者能够区分版本遗漏、下载损坏和后续构建故障。

开发机系统 curl 的完整 TLS proof 曾因 `zlib-ng` 版本后缀被既有解析器拒绝，不能把这次本地执行记为全绿。正式 Ubuntu/Android 验收使用锁定的 zlib 1.4 构建，相关结果按其工作流记录。输入不同的测试结论分别保留，避免用一个环境的成功覆盖另一个环境的失败。

本轮验证覆盖开发机定向测试、CI 和 Android 15 / KernelSU 模拟器；没有在用户物理手机安装新包、变更订阅或重新配置网络。eCapture 官方 Android 资产未提供 nspr/nss，本轮也未生成新的实际流量捕获证据。公网提速、长期续航和全部真实应用兼容性均不在这些检查的证明范围内。

## 六、公开附件与安装入口验收

公开附件检查核对了发行可见性、实际 tag 指向、源码与快照身份、附件内容以及稳定更新索引。实际回读结果：Release ID `447518808`，`draft=false`、`prerelease=false`；20 个附件全部为 uploaded。实际 tag 与 target 均指向 `81e558051819dc3a8b61c0aaa5c37b421d4808f8`，`releases/latest` 也返回同一个 v1.8.9。

| 项目 | 实物验收结果 |
| --- | --- |
| 已上传附件数量 | 20，全部 uploaded 且字节数非零 |
| 组件数量 | 10 |
| 离线包中逐项核验的组件文件数 | 171 |
| 全部附件与 SHA256SUMS 的对应关系 | 通过：SHA256SUMS 覆盖其余 19 个附件，逐项与 GitHub API 摘要一致；清单自身也已实际下载并对照 API 摘要 |
| 核心包及两个在线别名 | MagicNet-core.zip、MagicNet.zip、magicnet_installer.zip 的摘要一致；核心包与 installer 已分别实际下载并重新计算摘要 |
| 包内组件清单、文件摘要与权限 | 通过：两包内 components.json 与独立附件字节一致；171 个组件文件逐项核验大小、SHA-256、普通文件类型和 Unix 权限 |

| 安装文件 | 下载入口 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| 在线安装入口 | [magicnet_installer.zip](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.8.9/magicnet_installer.zip) | 3466085 | `230291fbea330664b8e5e0bfe15b05e1dffa084615de854792c59ef67f00b5ec` |
| 完整离线包 | [MagicNet-full.zip](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.8.9/MagicNet-full.zip) | 61366576 | `c062b8c789994da58dcac677554d092079a97a96a188814f56bb2d66b7095940` |

完整附件摘要入口为本发行的 [SHA256SUMS](https://github.com/LIghtJUNction/MagicNet/releases/download/v1.8.9/SHA256SUMS)。已实际下载在线安装入口、核心包、完整离线包，以及 SHA256SUMS、来源、子模块、更新和组件清单共 8 个文件；两包内 `module.prop` 均为 v1.8.9 / 10617。实际执行结论：全部通过。核心包 194 个条目、完整离线包 365 个条目，路径与开发/测试目录排除检查通过。独立组件 ZIP 按 API 摘要与发布清单核对，其内容在完整离线包中逐文件核验；8 个实下载文件均完成大小与 SHA-256 对照。

稳定更新索引回读结论：通过：根 update.json 为 v1.8.9 / 10617，zipUrl 指向本版实际 installer；三语 README 的当前发行、安装说明和源码 c5a13686 均一致。对应主仓库提交为 `4334f6d93e0ef36f31ab46c1f653ce4dce71a366`。回读已覆盖根 `update.json` 的版本、versionCode 与安装 URL，以及三语 README 的当前发行入口；历史维护记录继续保留各自的日期、源码和发布身份。
