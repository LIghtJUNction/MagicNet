# 实现与发行验证

## 2026-10-29 / 跨仓库 CI 与发行入口修复

修复前，MagicNet main 没有根 `.github/workflows/`；旧工作流位于实现子模块，不能替主仓库运行。正式发行仍使用 LIghtJUNction/MagicNet，源码仓库固定为 magicnet-android。当前源码提交为 `b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7`，已先推送源码 main 并回读核对。软件版本仍为 v1.8.0，未创建新标签、草稿或发行版。

- 新增主仓库手动 release.yml、PR/手动轻量 recipes.yml；默认 build 只产出 artifact，publish 必须通过同一 gitlink 的构建、完整质量门槛和 Android/KernelSU 验收。只发布 job 申请 contents:write。
- 恢复版本固定的官方 installer URL；记录配方/源码两个提交。最终资产检查包括完整文件清单、组件/内嵌 manifest、大小和 SHA-256、三个核心别名、模块身份与版本。上传草稿后再次检查 GitHub 的资产清单、大小及摘要，失败不公开。
- 源码接受显式 source_sha，并在两个 Android job 检出后核对完整 SHA；模拟器 fixture 正确记录实现提交。旧源码发行脚本拒绝从源码仓库创建发行请求。源码仓库的七个修改文件已提交并推送，未触发远程 Actions。
- 本地 155 项相关回归通过：主仓库发布边界 13、源码发行准备 42、发行门槛 5、Android 模拟器主机回归 69、模拟器工作流/夹具回归 26。它们是主机与合成测试，不是已经运行 Android 模拟器。
- actionlint v1.7.12 检查两个主仓库工作流及修改的 Android 工作流通过；26 个主仓库 Actions/composite shell 步骤语法通过，非 Python heredoc 步骤同时通过 ShellCheck。源码 760 个受跟踪文本文件的 sanity 检查通过。
- 本地 recipkg check、pack、归档 check、完整 build 提示词检查通过：8 个包、54 个普通 UTF-8 Markdown 文件，依赖包身份完整，无链接、unsafe path、NUL 或非 Markdown；所有非 LOCK 正文完整进入提示词。临时归档与提示词随检查自动删除。

本轮未执行完整 Android/WebUI 构建、远程 Actions、真实上传发布、签名或设备/真实网络验收。已有 dist/MagicNet.zip 保留，未作为本次源码构建通过的证据。工作流静态与回归检查通过不等于 CI 端到端已经跑通。工具下载曾遇到 TLS 错误，改用同版本 actionlint 固定源码本地编译；临时工具及编译目录在任务结束清理。

## 2026-10-29 / 配方0.3.0：#426源码提取与重建准备

本节只记录本轮事实；下方源码迁移、v1.8.0开发和初次迁移记录保持其原提交归属。当前产品源码固定0dca28dd984d82333707cbf4b222596934b4d847、tree bcb709f66bc2eb6a19021bd2f969f7cf2fa2198a，没有修改产品文件或gitlink。配方从0.2.1升至0.3.0；没有构建、发布或声称新Android版本。

### 材料和结构

- 使用实际Recipkg CLI 0.1.1（源码d0879adba69989cfe3edc7cf0d069a7b139f6410），运行extract生成提取任务，并实际按固定源码阅读；extract本身只渲染文字，不冒充自动读源。
- `recipkg check recipes/magicnet`通过；临时pack生成magicnet-0.3.0.recipe.tar.gz，归档再次check通过；`recipkg build <archive> --lang zh-CN --output <temporary-prompt.md>`通过。
- 归档包含8个包、53个普通UTF-8 Markdown文件（含LOCK），无链接、NUL、源码/二进制、Git元数据或私密文件。逐份比对所有非LOCK Markdown正文均完整进入build提示词，5份新增详细合同/源码审查材料均存在，没有只给根文件或摘要。
- 根集成验收M01–M39连续且唯一，原M01–M29未删除；新SUB/C-SUB/UI-SUB/VE/POLICY合同接入入口和验收。版本与DEPENDENCIES表一致。临时归档/提示词按仓库约定在检查后清理，不将生成物提交Git。
- `git diff --check`通过。旧源码工作区干净，.gitmodules、源码gitlink和共享技能gitlink保持不变；GitHub回读topics为recipkg，无需修改。独立重建不再要求先初始化旧产品源码。

### 真实执行的旧源码检查与探针

环境为隔离Linux宿主：GNU Bash 5.2.21、jq 1.7、Python 3.12.14、Node v24.22.1。全部使用合成数据；没有真实订阅、设备或流量。

| 命令/场景 | 实际结果 | 证据层次及限制 |
| --- | --- | --- |
| 在固定源码根运行 `python3 -I scripts/test-clash-subscriptions.py` | 28项：24通过、4跳过，退出0 | 原源码解析/合成测试；4项因未提供真实转换器跳过，不算通过 |
| `bash scripts/test-subscription-usage.sh` | 通过，退出0 | 合成响应头/用量行为，不是服务商现场 |
| `bash scripts/test-subscription-transaction-atomicity.sh` | 5项恢复场景通过，退出0 | 原测试使用模拟核心validator，只证明对应文件恢复机制 |
| 同名节点聚合探针 | 单独A/B成功；同名不同端点组合返回1；仅改B名称组合返回0，探针整体退出0 | 真实旧提取/计数/聚合函数，转换器输出为合成stub；退出0表示旧缺陷成功复现，不是已修复 |
| VLESS原生解析探针 | YAML完整性/输出返回0却缺encryption；带encryption=none分享链接完整性返回1；探针退出0 | 原函数+框架bootstrap替身；不是完整导入、核心check或协议互通 |
| 在固定源码webui目录运行 `node --experimental-strip-types --test subscription-user-agent.test.mjs` | 1通过、0失败，退出0 | 无需安装依赖的原前端helper测试；不是Vue页面/原生桥/E2E |

探针的合成输入、关键原始输出和具体源码位置已固化在SOURCE_AUDIT.md及runtime合同。复现脚本SHA-256：同名聚合e9eb6a902385b9b4b65e2aaee7ee9d84ec67c367cda5617297be62d376184f1d；VLESS探针源与输出在本轮临时观察材料，原产品文件指纹见PROVENANCE.md。临时脚本不作为配方执行依赖或新实现测试成果。

### 未执行及结论

本轮未运行真实转换器完整兼容、Rust整套/新Android编译、浏览器E2E、Android原生桥、真实多来源订阅、加密服务器互通、设备安装升级、多OEM/热点IPv6/实际应用及长期网络测试，也未进行从空上下文独立重建。缺少Vue/TypeScript依赖，因此没有把单个Node helper测试扩大为前端全套通过；没有为此下载大依赖。

#426的附件只证明单源成功记录，本轮发现的聚合缺陷可解释同类症状，但尚不能确定其现场根因。Issue保持待实现/待验证；配方更新不等于旧实现修复。新增subscription_batch_v1、URL统一身份、同名节点保留、VLESS管理链路保真均是未来实现验收目标。


## 2026-10-29 源码子模块迁移

根配方版本为 0.2.1，Android 软件仍为 v1.8.0。独立源码提交 `0dca28dd984d82333707cbf4b222596934b4d847` 与原已发布提交 `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf` 的完整 tree 均为 `bcb709f66bc2eb6a19021bd2f969f7cf2fa2198a`，含六个固定嵌套子模块。当前目录无源码修改，原分支与历史保留；根私密 `.env` 未追踪，未复制到实现或配方。

11 个共享技能逐个核对 origin、完整提交、干净状态、SKILL.md 和 Markdown 资源；原项目自定义技能保留。源码仓库仅发布当前 tree，不带入原历史已删除的本地工具数据库。

- `recipkg check recipes/magicnet`、临时 pack、归档 check 与完整 build 提示词生成通过。遍历归档确认 8 个包、48 个普通 UTF-8 Markdown 文件，无链接、NUL、源码、Git 元数据或私密路径；每份非 LOCK Markdown 的完整正文均出现在提示词中。临时归档和提示词已删除。
- 主仓库 index 的源码条目为 mode `160000`，固定上述源码提交；`.gitmodules` 指向独立源码 URL，入口未被忽略。源码 `.git` 由标准 `git submodule absorbgitdirs` 接管，递归检查既有嵌套子模块状态均干净；原自定义技能无差异。
- 独立源码仓库已公开，远端 main 与本地提交一致。禁用凭据 helper 后从公开 URL 做全新浅检出，核对完整 commit/tree、单提交历史及私密路径排除，再从各公开上游初始化全部六个直接子模块，固定点全部匹配。临时检出已清理。
- 原 MagicNet 仓库已有 topics 为 `recipkg`；幂等添加后回读仍为 `recipkg`，没有删改其他 topic。`git diff --check` 与 staged diff 检查通过。
- 主仓库布局提交 `18165e1ce100fb359dfead5322d9dafd794098ea` 已推送至 main；GitHub API 回读 generated 入口确实链接到独立源码仓库的上述固定提交。禁用全局/系统 Git 配置与凭据 helper，按 README 路径做全新公开递归浅检出，24 个子模块（含 11 个共享技能及全部嵌套源码）均匹配 gitlink，工作区干净，源码 tree 正确，主仓库与源码均无 `.env`，重新运行配方 check 通过。临时完整检出已清理。

这些检查只验证迁移结构、配方材料和公开源码可获取性。没有重新构建 Android、发布新版本或执行真机/网络验收；下述 v1.8.0 记录是同一源码 tree 的历史验证证据。

## v1.8.0 本轮开发

2026-10-28，按照当前递归配方继续开发既有 Rust、Shell、Vue 实现。源码固定 `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf`，软件版本 v1.8.0 / versionCode 10608，配方版本 0.2.0。当时源码位于本地忽略的 `generated/magicnet-android/`，通过原仓库软件标签提供；现已改为上节的独立源码子模块。`android-reference` 已按要求移入回收站。

- Rust：完整本地测试 808 passed、1 ignored；fmt 和严格 workspace/all-target/all-feature Clippy 通过。
- WebUI：338 项本地测试、类型检查、生产构建通过；新增分流、凭据编辑、冲突与撤销等 36 项浏览器任务通过。完整 750 项浏览器任务完成：747 passed、3 skipped、0 failed（6 种视口，中英俄与浅深主题、配置、订阅、导航、后台进度与恢复等）。
- 真实锁定内核：Linux amd64 和 Android arm64 均从固定 fork 源码构建，保留全部 release tags（含 eBPF、Tailscale、WireGuard 等）。用 Linux release CLI + 真正内核在隔离目录运行结构化分流 preview、save、materialize、重复生成、订阅新增项重叠、reset 检查通过；没有启动代理或修改宿主网络。一次最初夹具缺少 default_domain_resolver 被真实内核拒绝，补齐合法夹具后通过，没有关闭验证。
- 回归修正：先从当前配置和 checkpoint.effective 同时剥离自己的增量项，再执行旧 Merge Patch 的逆向合并，避免“同域名原规则还在”被误报外部冲突；应用/DNS/域名的真实归属与订阅新增项均有覆盖。
- MCP：隔离宿主 initialize 与认证 tools/list 成功，85 项 Schema 完整保存；未认证请求被拒绝；generic app inspect 被拒绝；临时凭据与监听进程已清理。
- 性能：对新 release CLI 的三个空模块读接口分别预热 1 次、测 7 次，均校验有效 envelope；全部样本与并行负载限制见 PERFORMANCE。本轮不宣称改善，未测 Android 吞吐、全模块 RSS、冷启动或公网 soak。
- Android 完整模块构建与 post-build 包检查通过，包含真实内核配置、订阅协议、TUN/eBPF 编排夹具及 78 项默认路由/DNS 检查。当前代码的安装升级夹具（含 21 项模板与配置迁移检查）、模拟 Magisk 完整生命周期、拆分后的完整包、最终轻量安装器检查通过；组件质量 gate、source/shell/host 全套回归通过。9 个组件的大小/摘要已与清单核对，最终 zip 的 CLI、桥接 jar 与生产 index 内容均与构建输入匹配。

## 保留的失败、未知与边界

本地 Go 原配置为 GOPROXY=direct，初次无法获取五个上游旧提交；公共模块缓存仍保留固定版本，使用默认 https://proxy.golang.org,direct 与 go.sum 重建通过，未改依赖版本。主机 shell 测试初次经 mise 的 Python shim 以 decoy argv0 启动失败；后续用真实系统解释器所在 PATH 复跑，不修改进程所有权逻辑。

最后统一字体后，布局/导航/分流相关浏览器复查 244 passed、2 skipped、0 failed。重新打包后只有 webui 组件摘要变化，其余 8 个组件及全部非 WebUI payload 与此前功能验收的内容一致；最终安装器身份/CRC/ELF/别名检查通过。远程发布/下载状态另行记录。

本轮 ADB 检查没有已连接设备，未把 Android 构建当成实际安装。应用名称 Java bridge 仅完成编译与打包，真实设备标签读取、WebView 触屏、多厂商 Play/GMS、热点 IPv4/IPv6、Tailnet 数据连通性和长期网络 soak 都没有当前版本的设备证据。所有 M01–M29 的完整设备业务验收不能写成已通过。

仍保留 mixed TUN stack；真实内核检查发出 stack 将在将来版本移除的 deprecation 告警。依 M29，没有受控设备 A/B 结果前不擅自切换默认。

## 迁移阶段历史记录

以下记录描述配方迁移当时的状态；其中“未重建/未发布”不代表随后 v1.8.0 开发的当前状态。

# 迁移交付检查

本轮交付为软件配方与仓库布局迁移，没有独立重建或发布新的 Android 实现。

## 已执行

- 原源码固定在 96993ea5c851b8d51cc562c3ca0766a2ca571210；原工作区干净后才迁移。历史提交、6个 stash、其他 worktree 均保留。
- 读取 Recipkg 仓库当前更新的英文迁移技能及旧安装版的差异；按用户更正保留 MagicNet 原项目名，删除误建的本地平行项目，没有新建远程。
- 本地原实现转移至 ignored generated/android-reference/；六个原源码子模块 revision 与干净状态逐个核对，私密 .env 仍留根目录且未追踪。
- 八个完整本地配方，递归图闭合；software-quality 来自固定有效配方。
- recipkg check recipes/magicnet 通过。
- recipkg pack 生成校验归档；recipkg check <archive> 通过。
- 遍历归档：48个普通 UTF-8 .md 文件（含 LOCK），无文件系统链接、NUL、源码/二进制/安装钩子/私密文件路径。八个包名均存在且无重复。
- recipkg build <archive> --lang zh-CN 成功，检查每份非 LOCK Markdown 原文完整出现在提示词，没有只放摘要或依赖链接。
- git diff --check 通过；本轮检查在本地执行。代码 PR 合并会触发仓库已有自动工作流；未手动调度或等待远程 CI。
- 本轮 Test Feedback 只读走查受设备版本断层与断连限制；19 条打开 Issue 的产品反馈已转录为 M18–M29 并纳入 FEEDBACK.md、所属子配方和性能基线来源说明。关闭 Issue 仅表示需求转入配方；不代表旧实现或新实现已通过。
- 原实现 release CLI 的3种空模块读接口各预热1次、报告7次；生产 WebUI 窄屏/桌面各7次；认证 MCP initialize/tools/list 成功，共84个完整工具 Schema，未认证请求被拒绝。具体方法/限制见 PERFORMANCE/PROVENANCE。
- 代码 PR #420–#423 的组合源码通过 Rust 808 项（1 项显式忽略）、fmt、严格 Clippy、前端 check、18 项代理组浏览器用例、安装迁移及模式安全脚本；环境缺子模块的初次失败和补齐后结果见 PROVENANCE。主机检查不替代新实现或真机验收。

## 保留的失败与限制

- 真机安装 metadata 为旧版，CLI 的机器接口调用失败，未当成当前源码或网络成功；未更改设备配置、安装、抓包、重启或测速。
- 生产浏览器预览已有 CSP frame-ancestors meta 告警仍存在，不以零 JS 异常掩盖它。
- 本地 RSS 的初次 wait4 高水位受继承污染，排除；改用验证 exe 后的存活采样，并注明不是精确全进程峰值。
- 无真实网络吞吐/核心启动/设备WebView/多厂商基线；性能预算未知。
- 旧实现留在历史/临时参考，不代表已经按配方独立重建；全部重建业务验收仍未运行。

## 版本与发布边界

2026-10-28 已先将代码 PR #420–#423 和 README PR #416 合并到远程 main；源码集成固定点为 ae4de1ce4d77f1a2a4c8d9656da8101c472fa3a0。用户已解除合并限制并授权直接合并；PR #424 承载最终配方结构与反馈，完整包含 #425 的共享技能提交。来源代码保留在上述 Git 历史和已更新的本地忽略参考中，重建要求保留新增行为。18 个产品 Issue 已按需求转入配方关闭；仓库治理 Issue #281 保持打开，不属于产品验收。未发布新 Android 版本。
最终迁移 PR #424 已合并为 084a189be2a07575441c7a627dbef5eff18cf98f；GitHub 将已被完整包含的 #425 也标记为 merged，打开 PR 数为 0。核对本批 7 个 PR 分支 tip 都是 main 祖先后，已删除这些远程分支及对应存在的本地已合并分支。本地 main 已快进到远程合并结果，其他工作区和未纳入本批的分支不受影响。
11 个共享 Recipkg 技能以各自上游仓库的固定提交接入为子模块；MagicNet 原有 Android、kamfw、设备调试和 Perfetto 项目技能仍保留在 `.agents/skills/`。技能代码不属于运行时依赖或配方归档。
根 update.json 与公开品牌/校验文件保留；配方迁移没有发布可安装的新实现。旧构建/发行代码留在本地忽略的观察参考目录和 Git 历史中；正式生成新实现前，仍须确定对应的构建、签名与发行入口。
GitHub 配方仓库继续使用原 MagicNet 仓库并带有 `recipkg` topic；该 topic 只用于发现，不代表配方有效或软件已重建。

## 2026-10-29 订阅源码修复（未发行）

源码提交 `ed01282e8ee4bcfc27ce5f95f37723c34aebf745` 已推送至 `LIghtJUNction/magicnet-android` 的 `main`，远端回读一致。源码 `cargo check --offline -p magicnet-cli` 通过（34 个 crate）；六个修改过的 shell 文件 `sh -n` 与 ShellCheck 通过；修改的 Rust 文件 `rustfmt --check` 通过；订阅预览 TypeScript 语法检查与本次 jq filter 语法检查通过；源码 `git diff --check` 通过。未运行测试套件、完整 Android/WebUI 构建或真实转换器。

配方与源码 pin 同步后，`recipkg check recipes/magicnet`、临时归档 `recipkg pack`、归档 `recipkg check` 和 `recipkg build --lang zh-CN` 均通过。归档有 8 个包、53 个 Markdown 文件，没有 `.env`、Git 元数据、源码或生成目录；build prompt 包含新固定提交及批次合同。临时归档和提示词在检查后清理。

未进行 Android 打包、签名、发布、安装、设备写入或真实多源网络验收。#426 仍只有单源成功附件，现场根因未确定；`subscription_batch_v1`、逐来源真实转换完整性、跨 tag 的来源归属、浏览器/真机验收仍未完成。源码 push 与本地/远端配方 gitlink push 分别记录，不把源码 `main` 更新称为产品发布。
