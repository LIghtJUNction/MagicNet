# MagicNet

Android root 设备的透明网络工作台，以可重建的软件配方维护。

[English](README.en.md) · [Русский](README.ru.md) · [重建指南](#重建指南) · [主配方](recipes/magicnet/BUILD_PROMPT.md) · [验收合同](recipes/magicnet/ACCEPTANCE.md) · [Issue 反馈](recipes/magicnet/FEEDBACK.md)

配方是项目本体，编程语言由重建 Agent 选择；实现是可重新生成的产物。项目名称保持 MagicNet。

## 仓库内容

- recipes/magicnet/：产品要求、来源证据、性能基线和集成验收。
- recipes/magicnet-control-plane/：CLI、schema-1 JSON、认证 MCP、完整工具 Schema 与文件状态合同。
- recipes/magicnet-network-runtime/：订阅、进程、应用/Wi-Fi/热点、Tailscale、网络恢复事务。
- recipes/magicnet-packet-engine/：TUN/eBPF 与 sing-box 兼容合同。
- recipes/magicnet-routing-policy/：默认 selector、DNS、分类数据与次序。
- recipes/magicnet-web-console/：14 页操作流程、国际化与视觉重设计要求。
- recipes/magicnet-module-delivery/：root 模块安装、组件分发、可信更新与恢复。
- recipes/software-quality/：完整固定的设计、代码与性能质量合同。
- generated/<implementation-name>/：本地临时实现，不进入 Git 或配方归档。当前 android-reference 是迁移前源码的参考材料，不是按本配方独立重建的结果。

初始观察源码固定在 Git 提交 96993ea5c851b8d51cc562c3ca0766a2ca571210；代码 PR #420–#423 和 README PR #416 合并后的完整源码固定在 ae4de1ce4d77f1a2a4c8d9656da8101c472fa3a0，本地 android-reference 已同步这些改动。历史、stash 与其他 worktree 保留。观察 checkout 与生成实现不是 Recipkg 依赖。
根目录 update.json 和公开品牌/校验资料保留旧发布兼容性；不把旧安装包或本机运行状态打进配方。现有用户可继续使用 [正式发布](https://github.com/LIghtJUNction/MagicNet/releases)，本次迁移不发布新 Android 版本。

## 重建指南

重建时需要 Git、Recipkg CLI，以及能够生成并验证 Android root 软件的代码 Agent。首次检出后初始化共享技能：

~~~sh
git submodule update --init --recursive
recipkg check recipes/magicnet
mkdir -p artifacts
recipkg pack recipes/magicnet -o artifacts/magicnet-0.1.0.recipe.tar.gz
recipkg check artifacts/magicnet-0.1.0.recipe.tar.gz
recipkg build artifacts/magicnet-0.1.0.recipe.tar.gz --lang zh-CN --output artifacts/magicnet-build.md
~~~

把 `magicnet-build.md` 和配方归档一起交给代码 Agent，要求它完整阅读提示词，按其中的组件依赖与接口实现软件，并逐项执行 `ACCEPTANCE.md`。完整需求在 `recipes/`；提示词包含递归依赖，不要只交根配方文件。实现源码放在 `generated/<implementation-name>/`，作为可重新生成的本地临时产物。

完成后把真实构建、功能、失败恢复、Android 设备及网络验收结果写入 `recipes/magicnet/VERIFICATION.md`。归档和提示词检查通过只说明重建材料完整，不代表实现已生成、Android 包可安装或真实流量可用。不要把 `.env`、订阅、凭据、设备状态或原始私密日志交给 Agent，也不要打进归档。

Recipkg 只生成完整的构建提示词，不会调用模型或自行实现软件；软件重建和验收由代码 Agent 执行。

## 已确认的重建方向

完整保留 Android root / arm64 的现有行为和 tun|ebpf 边界；语言/框架自由；保留流程并重新设计视觉，避免通用 AI 模板；沿用现有语种和切换行为。性能预算未知，真实原实现基线及限制见 [PERFORMANCE.md](recipes/magicnet/PERFORMANCE.md)。
[PROVENANCE.md](recipes/magicnet/PROVENANCE.md) 区分文档、源码、实际测量、推断和未知；[VERIFICATION.md](recipes/magicnet/VERIFICATION.md) 记录本次材料交付检查。写出并打包配方不证明已重建软件。

## 维护

业务变更先更新配方、接口与验收，再在 generated/ 中实现。本地验证后同步原仓库的授权分支，不为普通迭代启动重型远程 CI。正式发布的构建、签名、设备和业务验收单独执行。
发布配方的 GitHub 仓库需保留原 topic 并包含 recipkg；标签只用于发现。私密 .env、订阅、凭据与设备身份始终留在本机，不进入补丁或归档。

MIT，见 [LICENSE](LICENSE)；第三方实现/规则/工具遵循各自许可，参见配方内的许可与外部前提。

本仓库提交钩子运行 recipkg check recipes/magicnet；提交前应确保安装的 Recipkg CLI 在 PATH。共享 Git hook 保持标准 pre-commit 入口，其他 worktree 使用各自配置。
