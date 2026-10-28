# MagicNet

Android root 设备的透明网络工作台，以可重建的软件配方维护。

[English](README.en.md) · [Русский](README.ru.md) · [主配方](recipes/magicnet/BUILD_PROMPT.md) · [验收合同](recipes/magicnet/ACCEPTANCE.md)

配方是项目本体，编程语言由重建 Agent 选择；实现是可重新生成的产物。项目名称保持 MagicNet。

## 仓库内容

- recipes/magicnet/：产品要求、来源证据、性能基线和集成验收。
- recipes/magicnet-control-plane/：CLI、schema-1 JSON、认证 MCP、完整工具 Schema 与文件状态合同。
- recipes/magicnet-network-runtime/：订阅、进程、应用/Wi-Fi/热点、Tailscale、网络恢复事务。
- recipes/magicnet-packet-engine/：TUN/eBPF 与 sing-box 兼容合同。
- recipes/magicnet-routing-policy/：默认 selector、DNS、分类数据与次序。
- recipes/magicnet-web-console/：13 页操作流程、国际化与视觉重设计要求。
- recipes/magicnet-module-delivery/：root 模块安装、组件分发、可信更新与恢复。
- recipes/software-quality/：完整固定的设计、代码与性能质量合同。
- generated/<implementation-name>/：本地临时实现，不进入 Git 或配方归档。当前 android-reference 是迁移前源码的参考材料，不是按本配方独立重建的结果。

旧源码仍在 Git 提交 96993ea5c851b8d51cc562c3ca0766a2ca571210；当前源码的历史、已有分支、stash 与其他 worktree 保留。观察 checkout 与生成实现不是 Recipkg 依赖。
根目录 update.json 和公开品牌/校验资料保留旧发布兼容性；不把旧安装包或本机运行状态打进配方。现有用户可继续使用 [正式发布](https://github.com/LIghtJUNction/MagicNet/releases)，本次迁移不发布新 Android 版本。

## 使用

安装 Recipkg 后：
~~~sh
recipkg check recipes/magicnet
recipkg pack recipes/magicnet -o artifacts/magicnet-0.1.0.recipe.tar.gz
recipkg build artifacts/magicnet-0.1.0.recipe.tar.gz --lang zh-CN --output artifacts/magicnet-build.md
~~~
先创建空 artifacts/ 目录；工具拒绝覆盖已有输出。最后一个命令只生成包含完整递归材料的提示词，把它交给 Agent 才开始实现与验收。
生成实现默认放 generated/<implementation-name>/；本项目按用户约定将它视为临时产物，不为生成源码另建带 recipkg 后缀的项目，也不在本次迁移创建新的远程仓库。

## 已确认的重建方向

完整保留 Android root / arm64 的现有行为和 tun|ebpf 边界；语言/框架自由；保留流程并重新设计视觉，避免通用 AI 模板；沿用现有语种和切换行为。性能预算未知，真实原实现基线及限制见 [PERFORMANCE.md](recipes/magicnet/PERFORMANCE.md)。
[PROVENANCE.md](recipes/magicnet/PROVENANCE.md) 区分文档、源码、实际测量、推断和未知；[VERIFICATION.md](recipes/magicnet/VERIFICATION.md) 记录本次材料交付检查。写出并打包配方不证明已重建软件。

## 维护

业务变更先更新配方、接口与验收，再在 generated/ 中实现。本地验证后同步原仓库的授权分支，不为普通迭代启动重型远程 CI。正式发布的构建、签名、设备和业务验收单独执行。
发布配方的 GitHub 仓库需保留原 topic 并包含 recipkg；标签只用于发现。私密 .env、订阅、凭据与设备身份始终留在本机，不进入补丁或归档。

MIT，见 [LICENSE](LICENSE)；第三方实现/规则/工具遵循各自许可，参见配方内的许可与外部前提。

本仓库提交钩子运行 recipkg check recipes/magicnet；提交前应确保安装的 Recipkg CLI 在 PATH。共享 Git hook 保持标准 pre-commit 入口，其他 worktree 使用各自配置。
