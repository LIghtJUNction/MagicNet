# MagicNet

![软件与依赖汇聚为可重建的配方](https://raw.githubusercontent.com/recipkg/recipkg/main/assets/recipkg-cover.png)

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
- [generated/magicnet-android/](generated/magicnet-android/)：独立源码仓库 [LIghtJUNction/magicnet-android](https://github.com/LIghtJUNction/magicnet-android) 的固定提交子模块。main 跟踪这个入口，源码与六个嵌套子模块不进入配方归档。

初始观察源码固定在 Git 提交 96993ea5c851b8d51cc562c3ca0766a2ca571210；代码 PR #420–#423 和 README PR #416 合并后的完整源码固定在 ae4de1ce4d77f1a2a4c8d9656da8101c472fa3a0。android-reference 已按要求删除，源码历史仍保留。历史、stash 与其他 worktree 保留。观察 checkout 与生成实现不是 Recipkg 依赖。
根目录 update.json 和公开品牌/校验资料保留旧发布兼容性；不把旧安装包或本机运行状态打进配方。Android 安装包、完整离线包及组件见 [正式发布](https://github.com/LIghtJUNction/MagicNet/releases)；软件版本与配方版本分别管理。

## 重建指南

重建时需要 Git、Recipkg CLI，以及能够生成并验证 Android root 软件的代码 Agent。配方检查和提示词生成只需要 recipes/ 的完整闭包，无需初始化旧产品源码。直接在本仓库执行：

~~~sh
recipkg check recipes/magicnet
(
  set -eu
  recipe_tmp="$(mktemp -d)"
  trap 'rm -rf "$recipe_tmp"' EXIT
  recipkg pack recipes/magicnet -o "$recipe_tmp/magicnet-0.3.1.recipe.tar.gz"
  recipkg check "$recipe_tmp/magicnet-0.3.1.recipe.tar.gz"
  recipkg build "$recipe_tmp/magicnet-0.3.1.recipe.tar.gz" --lang zh-CN
)
~~~

把 `recipkg build` 输出的完整提示词交给代码 Agent，要求它完整阅读提示词，按其中的组件依赖与接口实现软件，并逐项执行 `ACCEPTANCE.md`。完整需求在 `recipes/`；提示词包含递归依赖，不要只交根配方文件。默认检查后清理临时归档；需要跨环境交接时，再明确保留归档和提示词文件。实现源码在独立仓库维护，并以固定提交的子模块接入 `generated/<source-repository-name>/`，仓库名与子目录名相同，使用小写字母和连字符。

完成后把真实构建、功能、失败恢复、Android 设备及网络验收结果写入 `recipes/magicnet/VERIFICATION.md`。归档和提示词检查通过只说明重建材料完整，不代表实现已生成、Android 包可安装或真实流量可用。不要把 `.env`、订阅、凭据、设备状态或原始私密日志交给 Agent，也不要打进归档。

Recipkg 只生成完整的构建提示词，不会调用模型或自行实现软件；软件重建和验收由代码 Agent 执行。

## 0.3.1 独立重建候选

本轮针对 [#426](https://github.com/LIghtJUNction/MagicNet/issues/426) 实际读取固定 v1.8.0 源码，补齐多来源订阅、同名节点、统一 URL 身份、缓存与逐源状态、WebUI 草稿/反馈、VLESS Encryption 字段保真及安装包别名合同。查看 [源码提取与覆盖记录](recipes/magicnet/SOURCE_AUDIT.md) 和 [本轮验证](recipes/magicnet/VERIFICATION.md)。0.3.1 补齐独立构建的规则素材定位、节点身份目标和集成职责。

`rebuild/recipe-0.3.1` 分支的实现从空目录和新上下文按完整配方重新生成，采用 Go 控制器、原生 ES modules WebUI 与 Android Java bridge，复用配方批准的固定 sing-box fork 和规则素材。本分支源码 gitlink 固定为 `b22f9f280ddaf729da47078c13838a73e6d89294`，候选软件版本为 **v1.8.1 / versionCode 10609**；配方版本为 **0.3.1**。宿主功能、失败恢复、安装包与 Android 交叉编译的证据分层记录，不代表真机、真实服务商或正式发布验收通过。

冻结的独立构建输入为 335,805 bytes、8 个配方包和 53 个 Markdown 文件，SHA-256 为 `502e160a363ffdc6e60477261ac15b74884b07f37de78af69558b0806f8e717a`。构建期间 main 新增的 M40/跨仓库发布合同未进入这一输入；当前配方闭包保留该合同，不能把最新重新生成的提示词冒充本轮实际输入。两个候选分支可用于审阅与设备验收；正式合入前仍需将 M40 发布流程适配到新实现并通过同提交门槛。

在本候选分支构建新实现：

~~~sh
git submodule update --init generated/magicnet-android
cd generated/magicnet-android
python3 scripts/fetch-build-inputs.py
bash scripts/build.sh all
python3 scripts/verify-package.py
~~~

完整离线候选包为 `generated/magicnet-android/dist/MagicNet-full.zip`。三个轻量别名逐字节相同，但本候选的在线组件尚未作为官方 Release 公开。源码、依赖与构建细节见 [新实现 README](generated/magicnet-android/README.md)。

## 已确认的重建方向

完整保留 Android root / arm64 的现有行为和 tun|ebpf 边界；语言/框架自由；保留流程并重新设计视觉，避免通用 AI 模板；沿用现有语种和切换行为。性能预算未知，真实原实现基线及限制见 [PERFORMANCE.md](recipes/magicnet/PERFORMANCE.md)。
[PROVENANCE.md](recipes/magicnet/PROVENANCE.md) 区分文档、源码、实际测量、推断和未知；[VERIFICATION.md](recipes/magicnet/VERIFICATION.md) 分别记录配方材料、实际软件、安装包与设备检查。写出并打包配方不证明已重建软件。

## 维护

业务变更先更新配方、接口与验收，再在 generated/ 的源码子模块中实现。本地验证后先推送已授权源码分支，再显式更新 MagicNet 的 gitlink；不要只提交未发布的源码指针。不为普通迭代启动重型远程 CI。正式发布的构建、签名、设备和业务验收单独执行。
发布配方的 GitHub 仓库需保留原 topic 并包含 recipkg；标签只用于发现。私密 .env、订阅、凭据与设备身份始终留在本机，不进入补丁或归档。

MIT，见 [LICENSE](LICENSE)；第三方实现/规则/工具遵循各自许可，参见配方内的许可与外部前提。

本仓库提交钩子运行 recipkg check recipes/magicnet；提交前应确保安装的 Recipkg CLI 在 PATH。共享 Git hook 保持标准 pre-commit 入口，其他 worktree 使用各自配置。

## main 的既有构建与发布入口

GitHub Actions 入口是 [Build and release MagicNet](https://github.com/LIghtJUNction/MagicNet/actions/workflows/release.yml)：选择 main，运行工作流时默认 mode=build，只构建并提供安装器、离线包、组件和摘要下载；mode=publish 才请求发布到本仓库 Releases。发布前先在源码仓库更新软件版本及 versionCode、同步两个仓库的 update.json 和发行说明，再更新本仓库的固定源码提交。当前 v1.8.0 已存在，工作流不会覆盖旧版本。

构建、质量门槛和 Android/KernelSU 模拟器验收固定同一实现 SHA；全部通过后先上传草稿、核对服务端附件，再公开。失败不公开，模拟器通过也不代表 arm64 真机或真实网络验收通过。源码子模块内的旧工作流不会替主仓库发布；日常 push 不触发主仓库重型构建，PR 只做轻量[配方检查](.github/workflows/recipes.yml)。本地同等检查可运行 `python3 scripts/check-recipes.py` 和 `python3 scripts/test-release.py`。

~~~sh
# 只构建，不发布
gh workflow run release.yml --repo LIghtJUNction/MagicNet --ref main -f mode=build
~~~

main 保存既有配方、固定源码子模块和公开发行入口。以下命令用于从 main 全新检出既有实现；本候选分支使用上节的 Go 构建入口：

~~~sh
git clone --branch main --recurse-submodules https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet/generated/magicnet-android
kam build -j 2
~~~

本轮候选发布时，main 的既有源码仍固定为 `b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7`，包含尚未发行的订阅修复及跨仓库构建发布兼容。导入基线 `0dca28dd984d82333707cbf4b222596934b4d847` 的完整 Git tree 与原仓库 v1.8.0 的 `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf` 相同；原历史及发布标签保留在 MagicNet。当前公开 Android 稳定版本仍为 v1.8.0。

已有同名目录时先核对其本地修改，不覆盖或清空。既有实现需要 Rust、cargo-ndk/Android NDK、Go、Node/npm、Java/d8、KAM 和打包工具，详情见 [固定旧实现的构建指南](https://github.com/LIghtJUNction/magicnet-android/blob/b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7/docs/build.md)。这些工具要求属于 main 的既有实现，不是本候选的 Go 构建要求。

v1.8.0 在既有实现上按新配方开发，并非声明从零独立重建。新增应用/域名分流、自定义组/出口、应用名查询和重新设计的配色；保留订阅及系统管理规则，变更先预览，再保存应用。安装说明见 [v1.8.0 发布说明](docs/releases/v1.8.0.md)。
