# MagicNet 工作流

代码质量、打包和真实 Android 仿真分别执行。仿真阶段、缓存规则和未覆盖范围见
[Android / KernelSU 仿真说明](../../docs/android-simulation.md)。

## android-kernelsu-acceptance.yml

每个 PR、合并队列、`main` 推送和手动触发都会运行。先执行不缓存成功结果的
测试框架回归，再启动 Android 15 / KernelSU x86_64 AVD。默认使用本地测试配置，
检查真实安装、重启生命周期和普通应用 UID 的 TUN 数据路径。
`Android Simulation Gate` 对失败或未执行的前置任务报错；仓库的必需检查规则
仍需单独配置，不能把新增工作流等同于已经修改分支保护。

原 `init.yml` 已移除，其中 `kam validate`、`kam check`、发布工作流、订阅用量
和签名测试已迁入 Android 构建任务，位于打包之前。Code Quality 的 shell lint
继续保留，没有以减少工作流为由删除这些检查。

## exec.yml

`exec.yml` 用于构建模块。触发方式包括 `push`、`pull_request` 和手动
`workflow_dispatch`。

在 `main` 上手动运行工作流时，可通过 `bump` 直接提交版本更新：

| 输入 | 行为 |
| --- | --- |
| `none` | 构建当前已提交版本；勾选 `release` 可直接发布该版本 |
| `patch` | 补丁号加一，例如 `v1.3.9` → `v1.3.10` |
| `minor` | 次版本号加一并清零补丁号，例如 `v1.3.9` → `v1.4.0` |
| `major` | 主版本号加一并清零其余两位，例如 `v1.3.9` → `v2.0.0` |

选择升级时，工作流同步更新 `kam.toml`、`src/MagicNet/module.prop` 和
`update.json`，将 `versionCode` 加一，直接提交到 `main`，随后显式触发新提交的构建。
这是因为 `GITHUB_TOKEN` 推送不会自动触发另一个 `push` 工作流。
同时勾选 `release` 会写入发布请求，后续构建会发布；`prerelease` 也会保存在请求中，
且要求同时勾选 `release`。仅升级版本时只构建不发布。

若主分支已前进，旧运行重跑会拒绝操作，请重新从 `main` 发起工作流。

审查后可通过两种方式发布：

- 在版本更新提交中同时添加或更新 `.github/release-request`，首行为精确版本号，
  例如 `v1.3.9`。推送到 `main` 后，仅当该文件在本次 push 的 `before..sha`
  范围内发生变更时，才请求发布。文件会保留在仓库中；后续未修改它的 push
  不会重复请求发布。发布下一版时，将它更新为下一版的精确版本号。
  预发布可增加第二行 `prerelease=true`；省略时为正式发布。
  旧的单行版本标记继续兼容，旧的 `patch` 标记不再支持。
- 在 `main` 上手动运行 `exec.yml`，选择 `release=true`。
  手动发布时可选择 `prerelease=true`，将 Release 标记为预发布。
  此时 `bump` 保持 `none`，且当前版本标签必须尚不存在。

普通 push 和 pull request 只构建并上传 workflow artifact；如果存在
`KAM_PRIVATE_KEY`，上传内容也会包含模块签名旁路文件。

发布前会检查已提交的版本元数据是否一致；使用发布请求文件时，
其中的版本号也必须一致。目标 tag 和 Release 必须尚不存在。
发布要求签名成功，并通过产物内容及安装检查。Release 的 tag 指向实际构建的
`GITHUB_SHA`。已有 tag 或 Release 会被拒绝，发布资产不会被覆盖。

### 构建缓存

Go 缓存覆盖依赖下载和编译产物，缓存键包含 Go 版本、NDK、依赖锁文件、
sing-box fork 提交及构建脚本输入。源码变化时恢复兼容的旧缓存，并在 job 成功后
保存新缓存，避免仅用 `go.sum` 导致编译缓存长期停留在首次运行。

Rust 缓存覆盖 registry/git 依赖与 `target/`；模块构建和质量检查使用不同命名空间。
缓存键包含编译器、锁文件/配置、workspace 源码；Android 构建还包含 NDK。
源码或依赖变化时使用恢复前缀复用兼容产物，Cargo 继续检查自身构建指纹。
缓存命中不会直接跳过编译检查。

`cargo-ndk` 固定版本并单独缓存安装目录，精确命中后不再执行 `cargo install`。
补充 Node/npm 与 Bun 下载缓存，覆盖 WebUI 的两种包管理器。测试、类型检查、
打包、签名和冒烟检查照常执行；这些新增缓存不包含最终发布 ZIP 或签名私钥。

setup-kam 只保留 Kam 自身缓存，关闭整个 `~/.rustup` 的恢复，避免旧缓存覆盖
刚安装的 Rust 工具链。发布构建安装 `aarch64-linux-android` target；AVD 任务另行
安装 `x86_64-linux-android`。新缓存命名空间需要首轮填充，实际加速幅度取决于
后续命中情况。

## quality.yml

`quality.yml` 将代码质量检查与打包流程分离：

- Rust：格式检查、警告即错误的 Clippy、完整 workspace 测试；使用锁定依赖并覆盖所有 targets/features。
- Shell：通过 `bash scripts/lint-shell.sh` 检查主机工具和一方设备脚本，包括被 source 的运行时片段；通过 `bash scripts/test-host.sh` 执行 fixture 回归测试。
- WebUI：通过 `npm ci` 安装锁定依赖，再执行测试、`vue-tsc` 组件类型检查和构建；安装 Chromium 后，通过 `npm run test:ui` 检查手机、横屏和桌面布局，以及弹层焦点、键盘避让和草稿保留。浏览器测试使用 fixture，不访问真机。

本地 `scripts/pre-commit.sh` 复用这些入口，并用 `--with-routing-assets` 加跑需要
宿主机 sing-box 和预备规则集的路由/DNS 集成测试。CI 的 fixture 套件不包含这两项；
真机、打包和安装验证仍需单独执行。

## 按需预览与公网观测

重复自动运行的 `webui.yml` 已替换为仅手动触发的 `webui-preview.yml`，仍可导出
源码与预览产物；自动 WebUI 检查统一由 Code Quality 执行。
`network-regression.yml` 的公网观测也改为手动运行；真实 DNS NAT 测试继续保留，
且每次实际发包，不再复用旧的通过结果。

Android 工作流默认 `public_benchmark=false`。手动启用后，公网代理测试在离线
验收之后运行，不能替代生命周期和应用 UID 的验证。安装引导、卸载浏览器、
网络证据和规则发布工作流仍保留各自独有的检查。

## 本地自定义

这里是 MagicNet 的项目配置，不再是未修改的共享基线。执行 `kam sync workflow`
后需要审查差异，避免重新引入已合并的独立校验或重复的自动 WebUI 工作流。
