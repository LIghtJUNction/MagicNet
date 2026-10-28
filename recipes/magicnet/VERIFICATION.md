# 迁移交付检查

本轮交付为软件配方与仓库布局迁移，没有独立重建或发布新的 Android 实现。

## 已执行

- 原源码固定在 96993ea5c851b8d51cc562c3ca0766a2ca571210；原工作区干净后才迁移。历史提交、6个 stash、其他 worktree 均保留。
- 读取 Recipkg 仓库当前更新的英文迁移技能及旧安装版的差异；按用户更正保留 MagicNet 原项目名，删除误建的本地平行项目，没有新建远程。
- 本地原实现转移至 ignored generated/android-reference/；六个原源码子模块 revision 与干净状态逐个核对，私密 .env 仍留根目录且未追踪。
- 八个完整本地配方，递归图闭合；software-quality 来自固定有效配方。
- recipkg check recipes/magicnet 通过。
- recipkg pack 生成校验归档；recipkg check <archive> 通过。
- 遍历归档：47个普通 UTF-8 .md 文件（含 LOCK），无文件系统链接、NUL、源码/二进制/安装钩子/私密文件路径。八个包名均存在且无重复。
- recipkg build <archive> --lang zh-CN 成功，检查每份非 LOCK Markdown 原文完整出现在提示词，没有只放摘要或依赖链接。
- git diff --check 通过；未运行、触发或等待远程 CI。
- 原实现 release CLI 的3种空模块读接口各预热1次、报告7次；生产 WebUI 窄屏/桌面各7次；认证 MCP initialize/tools/list 成功，共84个完整工具 Schema，未认证请求被拒绝。具体方法/限制见 PERFORMANCE/PROVENANCE。

## 保留的失败与限制

- 真机安装 metadata 为旧版，CLI 的机器接口调用失败，未当成当前源码或网络成功；未更改设备配置、安装、抓包、重启或测速。
- 生产浏览器预览已有 CSP frame-ancestors meta 告警仍存在，不以零 JS 异常掩盖它。
- 本地 RSS 的初次 wait4 高水位受继承污染，排除；改用验证 exe 后的存活采样，并注明不是精确全进程峰值。
- 无真实网络吞吐/核心启动/设备WebView/多厂商基线；性能预算未知。
- 旧实现留在历史/临时参考，不代表已经按配方独立重建；全部重建业务验收仍未运行。

## 版本与发布边界

本地迁移使用原仓库的 migrate/recipes-primary-20261028 分支。没有合并 main、关闭 issue、合并 README PR 或创建新 Android 版本。
根 update.json 与公开品牌/校验文件保留；默认 main 的现有正式发行工作流未修改。旧构建/发行代码保存在参考源与历史中；正式将主线切成配方前，须确定配方生成实现后的构建/签名/发行入口，不能声称本次已发布可安装新实现。
GitHub 发布该配方分支时使用原仓库，保留既有 topics 并添加 recipkg，再回读核验；标签不保证语义完整。
