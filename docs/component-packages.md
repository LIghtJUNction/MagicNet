# 组件包实现已统一

以 [component-packaging.md](component-packaging.md) 为当前安装和发布约定。

PR #204 已先合入主线。PR #205 的冲突按功能合并，不同时启用两套安装器、两套清单或两次拆包钩子：保留 `installer/components`、`components.json`、`scripts/quality-gate.sh` 和主线的最终签名流程。

`MagicNet-core.zip` 与兼容名称 `MagicNet.zip` 都是核心包；`MagicNet-full.zip` 是完整离线组件包。管理器和旧 installer 原有更新入口继续取得核心包，未变化组件复用，CLI/MCP 也保持独立组件，不退回每次下载完整包。分包仍在工作流中统一生成，而不是同时运行另一套 pre/post-build 钩子。

合入 #205 的新增保护：拆包前限制总解压大小、拒绝非法软链接目标和穿过目录软链接的成员、拒绝目录/文件重名、重打包时复制 ZipInfo 避免污染源归档索引，以及安装引导解压前的软链接检查。`scripts/test-component-archive-safety.py` 的十项测试纳入现有共享质量检查。主线已有的下载哈希校验、离线/旧组件复用、暂存和普通写入错误回滚继续保留。

该合并不修改版本号或创建 Release，也不改变网络转发策略。构建及主机回归通过不能代替 Android 真机验证。
