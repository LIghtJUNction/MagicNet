# 实现与发行验证

## v1.8.0 本轮开发

2026-10-28，按照当前递归配方继续开发既有 Rust、Shell、Vue 实现。源码固定 `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf`，软件版本 v1.8.0 / versionCode 10608，配方版本 0.2.0。源码位于本地忽略的 `generated/magicnet-android/`，通过原仓库软件标签提供；没有新建平行仓库或源码远程分支。`android-reference` 已按要求移入回收站。

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
