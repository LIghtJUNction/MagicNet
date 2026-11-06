# 来源、证据与未验证项

## 2026-11-06 / DNS 默认出口

输入为用户要求“修复dns泄露问题”。从当前固定源码 `ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9` 与模板 `6b5f68a261818a4ffda6eb9a11b21eef9b755650` 追踪生产物化和默认解析规则，确认未分类查询实际落到无代理 detour 的 bootstrap，而原健康检查只确认存在已知厂商的代理 DNS，可能漏报未使用该解析器的情况。没有把旧设备诊断样本或历史 CI 作为本次修复后的结果。

增量推送模板 `ba5793b41fd06704102116fe2536eef5988f2905`、源码 `e2725d7f74f890c349024f8ae164935458f9340e`；对应 [模板 PR #21](https://github.com/LIghtJUNction/MagicSingBox/pull/21) 与 [源码 PR #2](https://github.com/LIghtJUNction/magicnet-android/pull/2)。源码统一固定模板 revision/digest，精确迁移旧官方配对并保留用户自定义配置。没有升级核心或新增运行依赖。 独立审查随后发现默认类型元数据导致诊断跳过无条件直连规则，补正为 `47097272655e5bf9bb80dcc910d110e56667be05` ，随后继续补正边界。该 `4709727` 增量只有 DNS 诊断及其回归，先确认旧反例失败，再通过 26 项定向与完整 Rust gate；原生产 DNS 数据包证据仍绑定 `e2725d7`，不改变其提交身份。

最终源码 pin 为 `38c6eea6a42eb5f2cc3697c81225f35fd3c82d5c`，tree `1e83b5b00e2f8b3aa2018358717a81e228820a94`。自动审查后补齐空匹配器、真实出站链、受管 TLS 验证、失败 profile 回滚和 WebUI 初始状态；复用既有配置锁和路由诊断，不新增依赖。33 项 DNS/profile、完整 Rust gate、Shell/source lint 与 24 项 WebUI 检查通过。显式 resolver 保留既有接口语义，不因默认 profile 强制重写用户图。

证据包含旧代码反例、生产 materializer 测试、合法 standalone/直连/bootstrap 对照及精确核心数据包测试。真实核心在本地受 AF_NETLINK 限制，转由 [GitHub 42182836598](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42182836598) 的必需步骤运行并成功；测试仅将生产图的网络端点及 TLS 信任替换为本地夹具，观察代理连接、上游收到的查询和失败结果。没有关闭 TLS 校验或借用用户私密订阅。

本轮记录按 Research-Paper-Writing-Skills 的证据、自审和边界要求组织。配置级健康检查不等于完整动态出口证明，真实核心回环证据也不等于物理 Android 抓包。直连分类、用户显式 override/standalone、Private DNS 和应用自身加密解析的边界见 [DNS 修复记录](DNS_REPAIR_2026-11-06.md)；未经当前设备验收的范围不写成已修复或已部署。

## 2026-11-06 / 联网诊断、真实框架集成与交付验证

输入为用户要求：最终模块不打包测试目录；在本机模拟并测内存/性能；连接后低频Google检查，失败明确警告、指数退避并尝试订阅等恢复；一键导出覆盖路由、核心、订阅及相关信息的单文件诊断。

增量推送源码e8aad9e（打包）、9d545e1（WebUI）、aefcbfb（联网/导出）、027e91f（CI依赖与核心转发测量）、81a6010（真实监督器锁分离/诊断日志/Android导出验收）、d22b122（安装夹具清理和实包worker行为）及b5fa1cd（实际机器状态结构保真和有效MCP观察入口）。框架a7788737只新增字面路径回归，生产修复来自上游ea8758bf。该阶段候选源码b5fa1cd64788bdc5d1dbbd6b88d799c25f895944，tree fe78eb29a1dd8ab06292606b4ccf84b27e13cb88；核心d850ff0、模板6b5f68a保持。

随后实际Android和归档审计发现b5缺少curl，fa0e1ad补入正式共享构建的HTTPS组件及诊断证据；原生init已成功后重复late-load触发ETXTBSY的问题通过只读核验原生启动修正。2bbbf2a修复宿主版本解析兼容，其后f0d2407修正KAM输出权限并明确界面执行器原因，f0实际ZIP和安装模拟通过，但测试临时项目遗漏新帮助脚本；218e165仅修复该夹具依赖。218质量、Build和Network通过后，Android在ADB reverse列表解析失败；ceb7d54只补充官方合法空白行兼容。最终验收源码为`ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9`，tree `794e53afe208f03429748bdea554a71b792b5f3b`。两次b5生命周期失败、fa0/2bb权限及版本前置失败、f0夹具失败及218解析失败保留，未由后续通过记录覆盖。固定输入、许可证和摘要见delivery/EXTERNAL_ASSETS.md。

最终提交的四条CI均成功：[Quality42173653819](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653819)为7/7 jobs、122项RUN/PASS及3项Rust结果HIT；[Build42173653787](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653787)和全部14个ZIP的独立审计通过；[Network42173653682](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653682)为3/3 jobs；[Android42173653691](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653691)在attempt1完成12/12阶段、5/5重启，0 JUnit失败。本地应用UID/TUN控制、生命周期与真实单文件导出已有AVD执行证据，不外推为ARM64物理手机、真实公网代理出口或续航已验证。

实际模块curl的版本、gzip、内嵌CA身份和本地TLS正负控制通过，但Google没有返回HTTP 204。一次显式正常产品tick记录`tls_failure`、HTTP为null、警告为true及60秒退避；直连对照也失败且只有首次失败，未触发订阅刷新或重启。原因审查未取得具体curl失败码或握手原文，不能把fixture猜成唯一原因。固定curl官方源码与构建选项的只读审查未发现默认内嵌CA加载路径断开；这仍不证明该次公网握手已完成CA加载或接受公共证书链。不同架构和每次curl构建都按各自产物摘要验证，不宣称跨构建字节相同。

同期f7188cc的报告、PID边界和实际sleep观察，以及主项目407f5fa的重写合同和M59通过快进与三路整合保留。根配方0.3.14扩展真实框架LIFE-006和诊断证据范围；control0.2.6、runtime0.1.7、delivery0.2.6，仍为八包配方闭包；正式负载新增curl及静态TLS/压缩依赖。DIAG-A07要求对真实安装后的导出验证机器状态结构、公共语义与隐私；含URL的JSON不能被整段抹去，采集只使用支持的只读入口。GitHub更新使用预期SHA检查，没有覆盖并行工作。

真实CI失败促成两层锁分离、旧测试夹具兼容修正以及对真实诊断内容的二次审查。d22虽然原门禁全绿，独立文件审计发现内容缺陷后仍停止交付；修改前CLI复现失败，最终15项导出unit、3项CLI集成和独立实际文件解析通过，再运行精确提交CI。初轮失败、宿主权限阻断和未覆盖范围保留，不能把fixture或编译通过当作手机数据面通过。

新CLI重新测量并按六个冻结Rust文件与提交的逐字节一致性绑定ceb7d54及6e989c28二进制；fa0至ceb生产Rust等价链逐项核对；保留测时b5工作树dirty的原始状态，不将其改写为clean。watchdog测量保留81a原身份；该框架与运行路径未变。七轮核心CI分别保存样本、二进制摘要和环境，使用相同固定核心不等于共享runner上的受控版本A/B。Android核心75,900KiB、11线程、51FD是单一AVD fixture快照；实际诊断64,649字节、48节、764ms与宿主样本分别记录。完整门禁、归档身份、Google原因审查和默认CA源码审查见[报告](../../docs/connectivity-diagnostics-2026-11-06.md)及[CI证据](../../docs/evidence/connectivity-diagnostics-ci-2026-11-06.json)。

完整离线模块与实际设备诊断样本已经交付。模块为68,476,029字节，SHA256 `8dc73eb02ed508b772ed55618fa835ef869906ec8f3ae326e594fc94a0fd4d63`；[模块交付文件](https://drive.google.com/file/d/1b0qGXu15kLS01dFjhhF74_tqphRmYaAt/view?usp=drivesdk)与[诊断样本](https://drive.google.com/file/d/1e_Cj7QrqJmOCjXNzWdDhxRrKH5bsdaoJ/view?usp=drivesdk)保留对应实际产物。本轮未新建正式Release或部署用户设备。

## 2026-11-06 / 跨层重写与原版行为对照

输入为用户要求先观察已有功能，再替换内部实现，覆盖 kamfw 并与原版比较，尽量精简。比较原版固定为 `magicnet-android@aefcbfbab80fe14008e4467eb0292251f7ce8f89` 和 `kamfw@bb0dc7582ee2c27e31e49d2d3b714b97528defef`；这两个基线含同期联网恢复、诊断及安装包清理。后续上游 CI/测试修正 `027e91f19330404d5a52120c1ed171f203d90175` 通过主线整合保留。

该重写阶段的完整回归使用生产实现 [d58dbdc5ed8a43bc1fee5050187b529a0f7136b7](https://github.com/LIghtJUNction/magicnet-android/commit/d58dbdc5ed8a43bc1fee5050187b529a0f7136b7) 及其当时的框架pin `ea8758bf7f9c831931a99dfaa454356c81ed191a`；最终依赖随后固定到 [kamfw@a7788737b938a9ed930645befe2526b626999a22](https://github.com/MemDeco-WG/kamfw/commit/a7788737b938a9ed930645befe2526b626999a22)。后一个提交只增加测试，相对已测 ea8758bf 的生产文件逐字节相同；新增 fswatch 方法在四 Shell × 两种 find 后端的 8 个组合中通过。WebUI、Rust、Shell、安装器、打包和框架分别完成分批提交，再提交交叉审查发现的 ZIP 长度与 fswatch 排除兼容修正。完整回归后保留同期主线 `81a60108477d31ca6131f930f955580ad4fa8ba1` 的监督器锁分离、诊断日志与 Android 验收脚本修正，并对受影响路径单独复验。主仓库 gitlink 还包含最终验收文档及行为测试夹具修正；固定 sing-box、模板、规则及其许可继续复用。

该重写阶段当时的源码交付提交为 [f7188cc1f1184e5b5ac8da2d24b2dabeb42503ea](https://github.com/LIghtJUNction/magicnet-android/commit/f7188cc1f1184e5b5ac8da2d24b2dabeb42503ea)，包含完整验收证据、connectivity 行为夹具和 Android 验收脚本 PID 上限修正，主仓库以 gitlink 固定。

本轮替换各层共享实现及 kamfw 运行时，保留部分稳定协议、事务算法、声明和页面模板，不宣称每个历史文件逐行重写。框架运行时代码由 6,614 降为 3,349 行；删去 MagicNet 重复的核心生命周期 overlay，使用共享框架。故障修正与严格等价场景分开记录，完整矩阵、原始 JSON、复现命令和测量口径见[重写验收报告](https://github.com/LIghtJUNction/magicnet-android/blob/f7188cc1f1184e5b5ac8da2d24b2dabeb42503ea/docs/rewrite-verification-2026-11-06.md)。

根配方更新为 0.3.13，新增 REWRITE_CONTRACT.md 与 M59；八包闭包、同期 M56–M58 和子包版本保留。本轮是用户明确授权读取原版后进行的跨层重写，不是无旧源码独立重建。宿主结果不推导 Android 或实际网络已通过；浏览器被宿主 socket 权限阻断，自动审批拒绝扩大权限。未创建新 Release 或部署设备。


## 2026-11-06 / 大陆教育域名分类与默认模板迁移

输入为用户要求补充大陆学校与教育网站直连。本轮依据官方主站、服务说明及 CERNIC 的域名管理职责，选择 16 个后缀：`edu.cn`、`moe.gov.cn`、`chsi.com.cn`、`smartedu.cn`、`neea.cn`、`ncss.cn`、`icourse163.org`、`icourses.cn`、`xuetangx.com`、`yuketang.cn`、`chaoxing.com`、`zhihuishu.com`、`eol.cn`、`cnki.net`、`wanfangdata.com.cn`、`cqvip.com`。逐项官方 URL 与用途见 [POLICY_INVENTORY.md](../magicnet-routing-policy/POLICY_INVENTORY.md)，查阅日期为 2026-11-06。后缀覆盖根域名与子域名；不扩展为全球 `.edu`、全部 `.cn` 或共享 CDN，也不据此断言每个子域名的服务器位置。

模板固定为 [`MagicSingBox@6b5f68a261818a4ffda6eb9a11b21eef9b755650`](https://github.com/LIghtJUNction/MagicSingBox/commit/6b5f68a261818a4ffda6eb9a11b21eef9b755650)，`config.json` SHA-256 为 `cda86a582c15e6976e6b9eb1e3c7a00811b6efea4e604bcf3f44ecae443a3db3`。路由复用 `cn-direct`（默认 `direct`），DNS 复用现有本地加密解析器；前序模式、LAN、用户与应用分流、广告及 DNS 防护保留优先级。不增加 selector、规则数据来源或运行依赖，五个指定目标拒绝、Voice 清理与原生 TUN 默认值继续保留。

实现为 [`magicnet-android@cb7f63bc8eb426c8633de70ef03c9f8af0034ef6`](https://github.com/LIghtJUNction/magicnet-android/commit/cb7f63bc8eb426c8633de70ef03c9f8af0034ef6)，父提交为 `44f3c69f1f9366ab373afcb62b03584e61459d2e`，保留同期运行时和 launcher 维护。安装器在既有旧默认迁移清单中新增官方默认仓库、`dacc776dad4bd2519d5dd0dfbf3839713f9e438c` 与对应摘要的精确配对；原有四组配对保留，统一迁移至新模板，用户自定义 repo/ref/digest 保留。根配方为 0.3.11（M55），routing-policy 为 0.2.4（POLICY-A16–A20）；这是既有实现维护，没有独立重建。

直接证据包括 32 项模板测试、生成一致性检查和固定模板提交的 [配置 CI 成功记录](https://github.com/LIghtJUNction/MagicSingBox/actions/runs/42149178371)。源码定向检查与各自基线、未完成的构建及设备范围见 VERIFICATION.md。本轮软件仍为尚未公开发行的 `v1.8.5 / 10613` 候选，官方更新索引保持公开 `v1.8.4`。

## 2026-11-06 / 目录与运行时修复

输入为用户六项反馈：合并两组目录、删除 SVG、迁移 TUN stack、处理缺失默认接口及停止时 config.lock 超时。起点为 magicnet-android@c75583b00527acf96310e96c124805db010d939a、sing-box@d0b1422df5c36f49e7dbbccd0d49732040051974。开发过程中源仓进入 e8aad9e4b97c2601d029dcfa1f2b56ac90abd106，主仓进入 de5484f；通过三路合并保留全部同期规则和包装更新，再提交本轮修复。

最终实现为 [magicnet-android@fafd08c3e1b2a7bce10222cdff0e13c7ebba5096](https://github.com/LIghtJUNction/magicnet-android/commit/fafd08c3e1b2a7bce10222cdff0e13c7ebba5096)。内核新增 helper/tests/spec 的提交为 8ec36f0423ce5b52251828c270c2649a6ec9c0d2，上游文件带 lx 标记的接入独立提交为 [d850ff0ff68e11a71aa8207627e0a826cb52808f](https://github.com/LIghtJUNction/sing-box/commit/d850ff0ff68e11a71aa8207627e0a826cb52808f)。模板原生栈先行提交 b1fa62b6912861292c895db58a88b8c5bdff3451，最终消费其后继 dacc776dad4bd2519d5dd0dfbf3839713f9e438c，配置 SHA-256 为 08996a10e24adc6ffb6a75f96d436a543264734d95f50f9952a7a265bb58213e。

依据为四 shell 的真实 worker/父进程故障复现、fswatch 并发复现、固定核心代码路径和[官方 TUN 迁移说明](https://sing-box.sagernet.org/migration/#migrate-tun-stack)。修改既有实现，不是独立重建。M51–M53 分别承接目录、锁和接口观测；M50 的同期 Voice 清理继续保留。完整修复与实际验证见[报告](../../docs/runtime-repairs-2026-11-06.md)和 VERIFICATION.md。本轮没有把主机结果推广为设备已修复，也没有新建 Android 正式发行。

## 2026-11-05 / 指定目标拒绝与 v1.8.5

输入为用户指定五个目标并要求提交、推送及发布新版本。目标用途说明未独立核验，本轮仅记录匹配与拒绝行为。四个完整域名和 `dm.wo.com.cn:18080` 的精确范围见 routing-policy/POLICY_INVENTORY.md。

固定模板为 [`MagicSingBox@6da399473a1ab3f99661556886e0b6701581af24`](https://github.com/LIghtJUNction/MagicSingBox/commit/6da399473a1ab3f99661556886e0b6701581af24)，配置 SHA-256 为 `6365ee9b4144974ced6012dc99b9712ceef3f721f58ae9eb0943024373b81d81`。它基于当前 main `2bb30e333a0bc78d68a58549b068fd9d2bca4eb4`，该提交与此前模板 pin 的文件树一致；仅增加两条原生拒绝规则、生成配置、范围回归及说明。

实现为 [`magicnet-android@c75583b00527acf96310e96c124805db010d939a`](https://github.com/LIghtJUNction/magicnet-android/commit/c75583b00527acf96310e96c124805db010d939a)，固定上述模板并同步 CLI、安装器、WebUI 默认来源及软件版本。产品配方为 0.3.7，routing-policy 为 0.2.2；未独立重建，也未安装到设备。验证与公开发行状态见 VERIFICATION.md。

## 2026-11-03 / #434、#435 与 v1.8.4

输入为用户要求修复 #434、合并 PR 并发布。#435（文档合同）已合并；其引用的 `b1d235e0…` 未公开，现由 [`d22086d28499ceb25c9f2b7d965e783ded6c286a`](https://github.com/LIghtJUNction/magicnet-android/commit/d22086d28499ceb25c9f2b7d965e783ded6c286a) 实现并成为 gitlink。runtime 配方 0.1.4 增加 SUB-A21，产品配方 0.3.6。不是独立重建。

## 2026-11-02 / 日常 issue、安全与冗余扫描

输入为定时扫描。公开产品 issue 只剩 [#434](https://github.com/LIghtJUNction/MagicNet/issues/434)；#426 已由维护者关闭。无开放 PR。现行公开源码仍固定 [`689bd6146b2dfdd481c8e6df395e05509b51593f`](https://github.com/LIghtJUNction/magicnet-android/commit/689bd6146b2dfdd481c8e6df395e05509b51593f)，配方继续 0.3.3，不是独立重建，也不更新公开 gitlink。

本轮只吸收已在宿主复现的两项：订阅解析把 IPv4-mapped 地址按嵌入 IPv4 校验并钉选；MCP generic 文件读取与人类 CLI 不再转储路由/屏蔽域名、block URL、WARP 端点和节点名。#434 现场根因、代理通路和真机订阅仍未验证。

## 2026-11-01 / issue 与 PR 整合、v1.8.2 发布准备

本轮按用户授权处理两个仓库的全部开放项：MagicNet #431、#432、#433 与 magicnet-android #1；公开 issue 只有 MagicNet #426。先合并订阅预算与任务反馈合同，再实现 MCP 热点、应用及接口元数据的通用访问限制，保留显式私密工具和脱敏状态入口。源码沿用既有实现维护，不是独立配方重建。

Android 软件版本选择补丁版 v1.8.2，versionCode=10610；配方版本继续 0.3.3，依赖图不变。固定内核和配置提交保持现行合同。#426 仍缺乏现场因果与真机复测，不以 PR 合并为由关闭。实际源码 SHA、本地检查及正式发行状态见 VERIFICATION.md 本轮记录；不把发布准备说成已发布。

## 2026-10-30 / 手机端导航与输入体验

输入为用户进一步美化手机端使用体验的要求，沿用前轮的留白、配色和边框规则。先更新 `magicnet-web-console` 的 BUILD_PROMPT、DESIGN 与验收 20–25，再实现底部分区页面面板、可视视口内的快捷跳转、应用列表分批展示、终端分行输入与配置编辑器可读性。现有 Vue 实现的设计版本更新为 Fieldnotes 5.2.0。

实现提交为 [`fd0e2dabf668e9b8cd6e16f5058e06517fe110c2`](https://github.com/LIghtJUNction/magicnet-android/commit/fd0e2dabf668e9b8cd6e16f5058e06517fe110c2)，tree 为 `1de7a117b2b54ba48dcd12b2447fbe43bef19474`，父提交为 `396d71df3bd98316324e3533e2d2106e7392250e`；开发期间到达的订阅修复 `0952cb01b001e41e1074c2e5f4a731a4ad42b222` 和内核更新完整保留，两者没有 WebUI 文件交叠。

直接证据包括 338 项前端测试、类型检查与生产构建、14 页窄屏浏览器检查、135 个合成应用的递增展示、130 条逻辑夹具的选择范围，以及焦点、草稿和编辑器尺寸观察。新增及更新 E2E 文件仅完成语法检查，未运行 Playwright runner；无原生桥的浏览器预览不作为 Android 软键盘、设备写入或网络成功证据。实际结果与本轮通过的配方目录、归档和完整提示词检查见 VERIFICATION.md 本轮记录。

## 2026-10-30 / 配方 0.3.3：最终内核与消费固定点

最终采用 [sing-box `ff669d45e6562a790a49ef066340dbed5df46363`](https://github.com/LIghtJUNction/sing-box/commit/ff669d45e6562a790a49ef066340dbed5df46363)，tree `b5e4c5a7559369fa8f46842b0a0fc45c5aa1ca13`，包含上游 testing `e5d91fa79f6319d5de940d6c81d81f0fe53b9476`。fork 主线从 `ef1ac197876a45aee818ee608b15740c10b8fa3b` 继续合并，保留真实 merge 父提交与 fork 功能；消费仓原固定点则是 `871b7a3440cd9c850f1b09ef3b4ada9babb4384b`，两者角色不同。旧消费基础版本为 `1.15.0-alpha.10`，而其 `git describe` 为 `v1.14.2-386-g871b7a34`；保留这一历史差异，以完整提交和产物元数据确认身份。上游完整差异、WireGuard 复制源码来源及最小修复依据见[内核报告](https://github.com/LIghtJUNction/sing-box/blob/ff669d45e6562a790a49ef066340dbed5df46363/SPECS/TASKS/051-UPSTREAM_MERGE_235/IMPLEMENTATION_REPORT.md)。

当前 Android 实现为 [`396d71df3bd98316324e3533e2d2106e7392250e`](https://github.com/LIghtJUNction/magicnet-android/commit/396d71df3bd98316324e3533e2d2106e7392250e)，tree `3c758dfbe38c482d909bb96160ec64bafdea7da5`，父提交为 `0952cb01b001e41e1074c2e5f4a731a4ad42b222`。仅更新 sing-box gitlink、sing-box.version 为 `1.15.0-alpha.13` 和验收材料；原五个其他嵌套 gitlink、订阅修复、生命周期和最新 UI 保留。主仓库 `generated/magicnet-android` 固定该公开提交；配置仓库 MagicSingBox 仍为 `e4ecf47499c35bf25e10d04257a21a4f7975ebad`。

源码测试对象 `9caf2637c42113a40f1302b87ff9525220a0ff54` 与 GitHub canonical `d6316199ef905c8271e58b23dbf52456d2e49dde` 的 tree 同为 `a6b2907483435e507d5090cb5ce00d84899d10f5`。最终内核相对该 tree 只更新 SPECS 报告和文本证据。最终 Linux/Android 二进制从干净 `ff669d45e6562a790a49ef066340dbed5df46363` 重新构建并核对身份，随后用最终 Linux 产物重新运行配置和 loopback DNS 检查，结果与摘要见[消费仓验收](https://github.com/LIghtJUNction/magicnet-android/blob/396d71df3bd98316324e3533e2d2106e7392250e/docs/sing-box-update-2026-10-30.md)及 VERIFICATION.md。

配方先定义 CORE 合同，再实施与测量。普通 merge 保留同期 `MagicNet@48d539315ffd1814d0f394d6d2d83d4365ac629b` 的订阅、恢复和 README 改动；已整合的配方前缀对象为 `81c298443c6264cc0c1afd23fa542611aac1512f`，tree `231df500850dc0d133f1346cb8f9102fc8ce5a42`。根配方为 0.3.3、engine 为 0.2.1，核心验收为 M48；原先 M44–M47 的订阅要求保留。

## 2026-10-30 / 内核同步合同与配方 0.3.3 整合

输入为用户更新 fork sing-box、同步上游、降低内存和规范修复 bug 的要求。配方基线为 `MagicNet@a7a05308aadbbf4d8362780d2773bf963437b1a5`，当时实现为 `magicnet-android@b113f5128549172da6cb1f6e62f0b42d31adb956`，其内核固定 `sing-box@871b7a3440cd9c850f1b09ef3b4ada9babb4384b`。

本轮先定义 engine/CORE_LIFECYCLE.md，目标为 [SagerNet/sing-box testing e5d91fa79f6319d5de940d6c81d81f0fe53b9476](https://github.com/SagerNet/sing-box/commit/e5d91fa79f6319d5de940d6c81d81f0fe53b9476)，保留 1.15 预发布轨道、fork 专属协议和全部生产 tags。内核合同初稿在本地使用根包 0.3.2、engine 0.2.1 与 M44。合并同期主线的订阅配方 0.3.2 后，根包提升为 0.3.3，核心验收顺延为 M48，CORE-A01–A06 保持原名；其他组件合同和历史实测归属保持原版本。合同先行阶段使用上述旧内核 gitlink，最终固定点和实际检查见本文件首节。

## 2026-10-30 / 配方 0.3.2：候选需求整合与主线维护

配方候选 [`8acb763ff50f3626213c94165f4f3e3ae35ef247`](https://github.com/LIghtJUNction/MagicNet/commit/8acb763ff50f3626213c94165f4f3e3ae35ef247) 提供目录晋升、回执重放、完整网络策略基线和 B/C 草稿反例，已通过合并提交 [`25ff00f4d537f1db99d079a3a6ba5de4f7a2adc9`](https://github.com/LIghtJUNction/MagicNet/commit/25ff00f4d537f1db99d079a3a6ba5de4f7a2adc9) 整合到最新主线合同。候选源码 `b22f9f280ddaf729da47078c13838a73e6d89294`、冻结输入和既有验证均作为独立历史证据保留；主线继续基于 `b113f5128549172da6cb1f6e62f0b42d31adb956` 维护，M41–M43、最新 UI 和正式发布合同保留。

本轮新增实际冲突引用、逐源已知计数下界、公共/私密共享只读来源观测，以及根 module.yaml 与引用资源的合同。根 0.3.2、control 0.2.3、runtime 0.1.3 的规格先于源码实施；计数下界不证明完整字段保真，候选测试不证明当前 main 通过。新增验收的实际结果与仍未知项统一记于 VERIFICATION.md。

随后发布的现行源码修复为 [`0952cb01b001e41e1074c2e5f4a731a4ad42b222`](https://github.com/LIghtJUNction/magicnet-android/commit/0952cb01b001e41e1074c2e5f4a731a4ad42b222)，tree `ca1bfbb33779c9fbdf541b3399029269e5f0502d`，父提交为上述 b113f512；主仓库 gitlink 固定此提交。直接证据包括两个旧版失败反例、逐来源与引用的六组回归、共享有界观测的坏输入/零写入/脱敏测试，以及 827 个不同 Rust 测试的最终通过结果。真实转换器和 #426 现场仍未证实，不将数量下界写成完整订阅语义保真。

## 2026-10-30 / 前端留白与边框精修

输入为用户“多点留白、少一点边框”的界面要求，在现有 Vue WebUI 上统一空间、排版、导航与容器层级。实现提交 [`b113f5128549172da6cb1f6e62f0b42d31adb956`](https://github.com/LIghtJUNction/magicnet-android/commit/b113f5128549172da6cb1f6e62f0b42d31adb956)，父提交为 `72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae`，tree 为 `2e18248622aa946ca88a243915aa5ed015e9ad37`；父提交的服务交接、PID 校验与日志修复完整保留。

整合后重新通过 338 项前端测试、类型检查和生产构建。浏览器预览中的多页面、多尺寸、语言主题、草稿及焦点检查，以及 Android 真机和网络验证范围，见 VERIFICATION.md 本轮记录。

## 2026-10-30 / 配方 0.3.1：生命周期、PID 与日志路径

输入为 MagicNet [#429](https://github.com/LIghtJUNction/MagicNet/issues/429)、[#430](https://github.com/LIghtJUNction/MagicNet/issues/430) 及既有 #426 记录，固定实现基线为 `magicnet-android@a5617d6371fe17494fb4b4a6f655a0c8a0f7461e`。本轮实际修改现有 Rust/shell 实现，提交 [`72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae`](https://github.com/LIghtJUNction/magicnet-android/commit/72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae)，tree `1976d9f38b6a2e0520535c7256130ebe1cff114b`。未更换六个嵌套源码依赖，不是从配方独立重写。

直接证据包括：真实 mksh 的整数溢出与生产锁函数复现；真实 Linux 进程组、管道、flock、fd 与控制进程退出实验；旧/新日志函数的输出对照和 allocator 计数。核心网络行为使用受控假进程，不能作为 Android 网络数据面的成功证据。最终门槛、失败夹具修正和未执行项见 VERIFICATION.md；日志基准绑定原始基线与随源码提交的复现工具，见 PERFORMANCE.md。

配方增加 runtime/LIFECYCLE_CONTRACT.md，根包为 0.3.1、control 为 0.2.2、runtime 为 0.1.2，完整闭包仍为八包。当前源码 main 修复不改变已公开 v1.8.1 的标签或安装物，也不证明 #426 的现场因果。历史性能和发行记录保留各自原提交，不移作本轮测量。

## 2026-10-29 / 配方 0.3.0：源码再提取

本节记录首次提取阶段：从配方0.2.1固定提交0a773436c3b21a56931bbfc77b323c42218cf52b继续，实际读取独立源码0dca28dd984d82333707cbf4b222596934b4d847及固定内核871b7a3440cd9c850f1b09ef3b4ada9babb4384b。当时源码与gitlink未修改，也没有发布Android新版本。后续源码修复另见本文件末尾。

MagicNet文件路径相对于固定源码根；以下是本轮读取的关键证据指纹，不是要求重建者复制其内部结构：

| 源码路径 | SHA-256 |
| --- | --- |
| crates/magicnet-cli/src/subscriptions.rs | dc1e81e793225063f55389211755fc5e27bc71ce5b157d97adb0c9dea7ec5900 |
| crates/magicnet-cli/src/webui_payload.rs | dea85238faac5a980770961ca73fbcc3f455afe2f2b488a6331aebea35eb1c4d |
| crates/magicnet-cli/src/machine.rs | ac7caaa540c1fae08e6ff600f1e5b90cbcdc177da3432b6ffaf80a52c0a22600 |
| crates/magicnet-cli/src/machine/subscription.rs | 4848f46dbfc5585fff081dff3e66ef9e9974e7abf2b95dabcda8366b6d3e2c77 |
| crates/magicnet-cli/src/state.rs | 62f55ebece3f29b1d6810c38401ed114d5fa30708f00ba8522e458d5ecaeb99d |
| crates/magicnet-cli/src/mcp_server/rpc.rs | 0b4c574e5a257785a9b77ecf53b9bbcfb3487f0988333be9af8ed2c0d857b4a0 |
| crates/magicnet-cli/src/routing_overlay.rs | 8b9a3287a392c18f24cccb9e1417e05a280944e246c72da51cfdbd6e7bc810da |
| crates/magicnet-cli/src/overrides.rs | d1215e9b839f897a663a443721eddea06f2fe8a9f81159b5e03fd2f914770eb1 |
| src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh | c1af8da7c889ecc067a90e43dad7cff6fb2efec324c490e33d75ae429d6ac1b9 |
| src/MagicNet/lib/magicnet/singbox_subscribe/common.sh | 3aee9c41a714afee80b498ffb040fc2a29dca56b8106ee4c76e88872a8b97f4e |
| src/MagicNet/lib/magicnet/singbox_subscribe/parse.sh | 4f3186770acbeb0f2fa5e42e6b38ffdc3d58f4a3b9f8f47ab4b2eba33baecaf4 |
| src/MagicNet/lib/magicnet/singbox_subscribe/proxylink.sh | 97c6735201e9567c72e24f610f5f15a73625e30fba36a0801190547d934b91a5 |
| src/MagicNet/lib/magicnet/singbox_subscribe/config.sh | fe5602e3246997f0d961f2eda721324c14818c30c30976b01318bb90624d386b |
| src/MagicNet/lib/magicnet/singbox_subscribe/update.sh | a7d614802acc19498b4223e40b49f375b01ec8a2de5f9d19a4b9b4821fd7c5d3 |
| webui/src/components/pages/SubscriptionsPage.vue | 13a45f91663ea480212f36451d6c91b840d7645ad26cd6aaf2c00c30e8079e1a |
| webui/src/components/pages/subscriptionPreview.ts | 612e4df74b76518fc7668c7341db2cf6221d3061b5b0934c199d7eea782c9bb0 |
| webui/src/composables/subscriptionUsage.ts | 94be3bbee8b16a9049ed5cabd313f1799ce622e43d510fbfc0c7d970533bf020 |
| webui/src/composables/backgroundTasks.ts | 3bd4486ced42aece003e59bc131abc5c0d37a648f4b89912f3265956d10d5f22 |
| webui/src/composables/machineStatus.ts | 4a0879d696e0827cee06382e6006bd2a45d9edb0cecb59d6623e11ea0af1d100 |
| webui/src/components/pages/RoutingEditor.vue | dc7ad4bf8b37c4a4008363819da0c7dc4ea9be10a27444fdf677da8c4e5a5cfd |
| scripts/package-components.py | 5bcdceaeaa8ec5ece4e5412c532272ad7575afee56bab9989d99077d8437533e |

固定sing-box客户端Encryption证据经GitHub读取并校对Git blob身份，本地保存字节的SHA-256如下：

| fork路径 | SHA-256 |
| --- | --- |
| option/vless.go | d3af3ef892d0b178d2d577b8378d7c78d6c0ff2ac353d5f722eba31ed50fc517 |
| protocol/vless/lx_encryption.go | 65830c1dfb57e34d6dd76e26b2052c2df99225f31f210021fd3f0da41fdb6765 |
| protocol/vless/outbound.go | e2d345e830c237f5059673e2588e0392ce5c9e567336b1eb46d9fc919b2d79f6 |
| protocol/vless/encryption/client.go | 0329a8c3bbe8220b6b615ee28a6326ac37f8012c35ba9d476336e4c05e8c1538 |
| protocol/vless/encryption/common.go | 2734a8e34ba265a95a28a4bbfcf26ba224b1c6f7b5dd137afe8db07280ad063d |

首次提取时新要求的地位：统一URL身份、同名不同节点保留、subscription_batch_v1、UI计数修正与Encryption管理链路保真是重建目标；当时的基线源码尚未修复。后续有限源码改动单独列在本文件末尾。#426现场因果仍未知。旧产品性能、构建、浏览器、MCP等历史结果继续绑定各自原提交，不移动到0.3.0新实现名下。

提取方法使用software2prompt@4920378377332c0ca9779ede6062029fb15dacdb与本项目固定software-to-prompt技能；Recipkg CLI来源与标准库检索决策均记录在SOURCE_AUDIT.md。没有更新共享技能gitlink或引入新的源码型配方依赖。


主来源：LIghtJUNction/MagicNet，https://github.com/LIghtJUNction/MagicNet ，完整提交 96993ea5c851b8d51cc562c3ca0766a2ca571210，module.prop v1.7.2。迁移前 main 与 origin/main 一致，工作区干净；保留全部 stash、其他分支与其他 worktree。
迁移阶段只抽取需求/接口/可观察语义，没有独立重建实现。原临时参考目录 generated/android-reference/ 已按用户要求移入系统回收站；Git 历史保留固定来源，不成为 Recipkg 依赖。

## 证据等级

- 直接运行：当前源码 release CLI 编译；空模块3种成功机器读的重复测量、unsupported machine write 的结构化拒绝；生产 WebUI 构建与真实浏览器预览/重复可见性测量；真机 root/metadata/失败机器接口观察。结果/限制见 PERFORMANCE.md。
- 静态提炼：命令登记的公开 argv、machine capabilities 实际结果、MCP 名称目录、文件状态/事务与安全文档、前端页面/locale/style 定义、默认模板和规则标签、锁定构建输入。
- 测试材料：发现原项目 host/Android/Playwright regression 入口，阅读相关文档和部分用例；没有把测试名称当作实测通过，也没有重跑完整原产品套件。
- 推断：在非独占宿主上 helper 启动/等待影响状态响应；必须保留测量边界，不推广成设备性能结论。
- 未知：全产品最低 Android/WebView、其他 OEM 内核与 root 管理器、完整网络/多协议/热点/外部VPN/Tailscale业务验收、重建新设计、稳定性能预算。未覆盖的深层第三方协议规范依赖其合规外部实现/规范，不冒充随包提供。

## 原始文件指纹

以下路径相对来源提交的旧源码根；迁移后它们不再是配方包必需的本地文件。指纹固定观察对象，不要求未来实现复制结构或代码。

| 来源路径 | SHA-256 |
| --- | --- |
| AGENTS.md | 4bdc9f58d2147d34eff765d015d473d9a21859b593d7354182457435e4b69676 |
| ARCHITECTURE.md | 8d563661fe35ebf0e46933db36a65f6c15d6d62869542ffe771ebd14cff386f9 |
| README.md | 467e99e074ed9749777657287902a0832082d7d9f78ca6e7f58c54153f3489c8 |
| Cargo.toml | bb1f248f8897e5907484bf517f0c90f339906d5d31090e0f125c38fb92facfac |
| crates/magicnet-cli/src/commands.rs | 4aa4e8088ca083c5680a86b09230631784c856bc3f60d844d960757181ba08f1 |
| crates/magicnet-cli/src/machine.rs | 9f1310e26fd6288a85e815a59d31fe083e02d3ddfd9f70fb52246d7db2d9b060 |
| crates/magicnet-cli/src/mcp.rs | aaee6486375fde46cc8f55987fffb4aed63442eb9e9b0f20f6534a250ac202ca |
| docs/state-plane.md | 2ad902f716f5270b7e51ea28ae21873963041d6e4673aa67ca85a96bd875d1ba |
| docs/machine-interface.md | 2c81e6e5414d663f5886bfbad138daa034cf61beed8a5d379019bfad9199a64c |
| docs/user-guide.md | 9d28ce2bd4e25a83b540bf0ae0004288bbee9fa716d536c947ff2d78b7ec9080 |
| docs/config-overrides.md | 25fe3538249778f7dcb9b89152afd0c2e3a0a94918ff187e148a4f4c2a4afb23 |
| docs/module-update.md | 878cf4f3c931f4d3aaa7ca382a9e0c3fd1a83bef52d89dc27b664b6e016b1de2 |
| docs/component-packaging.md | 44cfcbd705d3735e3c04914ddf07704cdfe81637ff1da3ba40e55a0ec2809f07 |
| docs/runtime-resource-bounds.md | 6f8568f1ba1355a0a59661cc6674c019e6651152644bc6b969a720e6b9532be8 |
| docs/build.md | 93c095ddfec15a82835aea6bef0499b7390c98f8f896289ddc5fdc7cafd03438 |
| docs/local-simulation.md | dc30c3f649043c41e292c2b8dff6743c376a85c391f75660fd31b864a18f6d2b |
| docs/mcp-control-plane.md | ff6e3602dae02f70da97cb51c8884ddd02e6f6f9561920ab4ed5004bbd5cfd0d |
| docs/maintained-routing.md | eb29e6edfe823559ea38fbff0cf5d5ce3fb35a076f0ea58089e2b1e76d69a18f |
| docs/network-access-recovery.md | de4dc3b476f0ccbbfd676e190daf7e185c3a65ea7f59dc7e3562dfa1ebd47c06 |
| docs/tailscale.md | 3a01459d1d5c9e0627fc1801b3b31e4f795989a1b186701f19c7cfe60aeace06 |
| webui/package.json | c3f7e7729575656cbe0838457056bfd4d976e3c9125ecd5decdde98623a7c096 |
| webui/src/App.vue | 09fa1204aa1794cd3e2c7ecd5e91c4f3aa8145ebe2d6f65b73c5d9441dd24bd5 |
| webui/src/styles.css | 57b1757cf9496c3eeeb7f6ab68911b0e2259ce1a06cfafb94f14c1aecc511423 |
| webui/src/i18n/README.md | fbc59a405019c4b466cacdfa8d2c560f8b2b03d9022ddba714fd5c10be209106 |
| webui/e2e/README.md | ab98cccd3a9ac7c7784cfa54b4e050a421fd6ab4f00ba15fc15025c264466923 |
| sing-box.version | 35b28be4ba7795a5e4a0eff87d3d1e4aab9a4b63ec58a13834e1ec9032de8c33 |

## 子模块固定点

| 路径 | revision |
| --- | --- |
| .kam/bases/hooks | 13cff0dc1f30d8d0842e563008c7e2712233243f |
| .kam/bases/workflows | f21050a31c33f0ebcbf429af3056ec43c1b816ef |
| rules | f3335f9420d07b8c50b26488df2a9492da6bbb44 |
| sing-box | 871b7a3440cd9c850f1b09ef3b4ada9babb4384b |
| src/MagicNet/.config/sing-box | e4ecf47499c35bf25e10d04257a21a4f7975ebad |
| src/MagicNet/lib/kamfw | 35b2284c08446f6e22447a63d7c3331619e2e854 |


## 配方与工具来源

复用 software-quality@0.1.0 是来自 https://github.com/recipkg/recipkg 在 c1300de130b297445c92ebefeebe7817d816b491 的有效 Markdown 配方，已完整放入本地依赖，不指向源码仓库冒充配方。
迁移采用该项目工作树中已更新的英文 migrate-to-recipkg 技能；工作树存在其他用户正在进行的结构迁移，未修改、提交或清理它。实际使用 generated/src 中的本地 Recipkg CLI，支持 --lang/search；不是声称这版技能已发布。
recipkg search "android network" 实际候选为空；不代表不存在相关软件，也不证明自写配方完整。

2026-10-28 按用户要求先合并代码 PR #420、#421、#422、#423，再合并 README PR #416，形成完整源码提交 ae4de1ce4d77f1a2a4c8d9656da8101c472fa3a0。上面的文件指纹和 PERFORMANCE.md 仍固定初始观察版本，不挪作新版本基线。本地参考目录的 26 个变更文件已核对无本地修改后同步；新增的节点与代理组入口、名称安全、锁争用和单一迁移清单要求同步进入所属配方。
组合源码在隔离 detached worktree 本地验证：Rust 808 passed / 1 ignored、fmt 与严格 all-target/all-feature Clippy；前端单元测试/类型检查/生产构建；代理组相关浏览器用例 18 passed；安装器 10 项与网络恢复迁移 3 项及配置刷新合同通过；透明模式安全脚本在 Bash 和本地构建的 mksh R59 上通过。初次因未初始化配置/KAM 子模块失败，补齐固定 revision 后通过；不将其记作产品修复，也没有将主机夹具推广为真机验收。
按用户随后授权，18 个产品 Issue 已在需求迁入配方后关闭，实际设备与业务验收仍待执行。没有创建 MagicNet-recipkg 远程；误建的本地目录已移入回收站，配方在 MagicNet 原仓库维护。

## 许可

参见 LICENSE.md。全部原始实现、数据集和工具仍遵循自身许可证；配方的 MIT 不改变 sing-box 的 GPL-3.0-or-later 或其他第三方义务。归档只包含说明与公开接口材料，不含源码、二进制、生成资产、安装脚本或私密文件。

## MCP 公共目录实际观察

隔离宿主夹具的 initialize/tools/list 成功，完整工具参数 Schema 已提炼；未认证请求被拒绝。未执行业务工具，临时服务/secret/夹具已清理。结果：{"tool_count": 84, "initialize_ok": true, "catalog_ok": true, "unauthenticated_rejected": true}。

## v1.8.0 实现迭代

用户随后授权按新配方开发、提交推送并发布。实现从 ae4de1ce 的完整源码继续，开发时位于本地忽略的 generated/magicnet-android/，使用 Rust、Shell、Vue 以保留既有边界；这不是独立从零重建。当时 main 保留配方，源码通过同一仓库的 v1.8.0 标签固定。该临时布局已由下述源码子模块布局取代。

结构化增量分流、私密应用名 inspector、WebUI 视觉与表单改动有对应接口/验收更新；配方版本 0.2.0 与 Android 软件版本 v1.8.0 分开。初次本地构建因 Go 的持久化 GOPROXY=direct 无法取得五个上游旧提交而失败；核对公共代理中的固定版本与 go.sum 后，构建脚本默认使用 https://proxy.golang.org,direct，未更换依赖版本、未关闭摘要校验。构建继续执行真实内核和包检查，结果见 VERIFICATION。

本轮实现源码固定为 f13ca61b9c3477aee3b1380d71815c84b3a2a6bf（原仓库 v1.8.0 标签）；host release CLI 的 capabilities 已实测，认证 MCP 工具目录为 85 项，未认证与 generic app inspector 请求均被拒绝。

## 2026-10-29 源码子模块布局修正

用户要求按 migrate-to-recipkg 技能执行，保留现有同仓库 recipes/ 布局与主项目 MagicNet。实现复用原干净目录，不复制源码、不改变语言、功能、语种、平台或性能预算；独立源码仓库为 https://github.com/LIghtJUNction/magicnet-android ，通过 generated/magicnet-android/ 的固定 gitlink 公开。

源码提交为 0dca28dd984d82333707cbf4b222596934b4d847，完整 tree 为 bcb709f66bc2eb6a19021bd2f969f7cf2fa2198a，与原 v1.8.0 提交 f13ca61b9c3477aee3b1380d71815c84b3a2a6bf 完全相同，包括六个嵌套子模块。新仓库从当前干净快照开始，不重发原历史中已删除的本地工具数据库。原历史与发布标签保留在 MagicNet；本地 legacy/magicnet-v1.8.0 分支与 upstream 远程保留原来源。

配方根包提升为 0.2.1，修改范围为仓库布局、获取/构建入口、依赖边界和相应验收。已发布的 v1.8.0 与 0.2.0 发布归档保持原样。共享技能复用既有 11 个 canonical 子模块，原自定义技能不替换。材料检查与公开检出结果见 VERIFICATION.md；结构修正不构成重新构建、重新发布 Android 包或真机验收。

## 2026-10-29 订阅源码修复

用户要求继续完善项目后，在独立源码仓库 `main` 提交并推送 `ed01282e8ee4bcfc27ce5f95f37723c34aebf745`（tree `072233c5df4610d3b31f008b70a0b0a01c966bc1`），并将 MagicNet 的 `generated/magicnet-android/` gitlink 更新到该固定提交。改动覆盖订阅节点身份/计数、跨入口 URL 规范化及预检、缺少 metadata 的来源行、VLESS `encryption` 保真和安装恢复调用点。细节与未解决的来源归属、批次观测见 SOURCE_AUDIT.md。

这是源码 `main` 的未发行修复；未创建 Android 包、签名或部署。没有读取/复制根 `.env`，没有设备操作。实际本地检查和未执行项列在 VERIFICATION.md；#426 的现场原因仍未知。
