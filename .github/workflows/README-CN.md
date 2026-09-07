# Kam Workflows

这里是 Kam 模块仓库共用的 GitHub Actions 基线。

## init.yml

`init.yml` 用于验证仓库。触发方式包括 `push`、`pull_request` 和手动
`workflow_dispatch`。

它会递归 checkout 子模块，使用 `MemDeco-WG/setup-kam@v3` 安装 Kam，然后运行：

```bash
kam validate
kam check
```

同时会对 `hooks/`、`src/` 和顶层 `kam.sh` 中存在的 shell 文件运行
`shellcheck`。

## exec.yml

`exec.yml` 用于构建模块，支持 `push`、`pull_request` 和手动 `workflow_dispatch`。

在 `main` 上手动运行时，通过 `bump` 选择版本升级方式：

| 输入 | 行为 |
| --- | --- |
| `none` | 构建当前已提交版本；勾选 `release` 可发布该版本 |
| `patch` | 补丁号加一，例如 `v1.3.9` → `v1.3.10` |
| `minor` | 次版本号加一并清零补丁号，例如 `v1.3.9` → `v1.4.0` |
| `major` | 主版本号加一并清零其余两位，例如 `v1.3.9` → `v2.0.0` |

选择升级后，同步更新 `kam.toml`、`src/MagicNet/module.prop` 和 `update.json`，
将 `versionCode` 加一，直接 commit 并推送到 `main`，随后在同一个 job 构建
该提交。不创建版本分支，不创建版本 PR。

勾选 `release` 后，本次运行通过签名、产物与安装检查即可发布；`prerelease`
要求同时勾选 `release`。不勾选发布时，只升级版本并构建。若提交后构建失败，
已提交的版本不会回滚；修复后选择 `bump=none` 可重试尚未发布的版本，避免再次加号。

### 直推权限

bump 步骤优先使用 `RELEASE_TOKEN`，未配置时使用 `GITHUB_TOKEN`。
MagicNet 当前主线规则要求 PR，只有仓库管理员可绕过；普通 `GITHUB_TOKEN`
无法绕过该规则。因此，当前规则下需配置 Actions secret `RELEASE_TOKEN`：
使用有绕过权限的管理员账号创建、仅授权本仓库且具备 Contents 读写权限的 token。
不要将 token 写入源码。工作流不会修改或削弱分支保护规则。

推送仅允许快进。旧 checkout、主线并发更新或权限拒绝会在编译前报错；
不强推、不自动 rebase，也不回退创建 PR。版本 commit 带 `[skip ci]`，防止
使用 `RELEASE_TOKEN` 时再触发一轮重复构建；当前手动运行仍继续构建新提交。
版本检查与 Release tag 均使用新的 `RELEASE_COMMIT_SHA`，避免引用运行开始时的
旧 SHA。已有 tag 或 Release 会被拒绝，不覆盖发布资产。
发布需要 `KAM_PRIVATE_KEY`；同时请求 bump 和发布时，会在修改元数据前检查该密钥。

保留 `.github/release-request` 的兼容发布入口：当该文件在 main push 范围内
发生变化时，首行必须等于已提交的精确版本号，可增加第二行 `prerelease=true`。
未变化的标记不会再次发布。直提交请求发布时仍同步该标记，但发布过程已不依赖
另一次 push 工作流或 PR 合并。

普通 push 和 pull request 只构建并上传 artifact；存在 `KAM_PRIVATE_KEY` 时，
上传内容包含模块签名旁路文件。

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
刚安装的 Rust 工具链。正常安装 Android 标准库，不再先删除工具链目录；
仅安装模块需要的 `aarch64-linux-android` Rust target。
新缓存命名空间需要首轮填充，实际加速幅度取决于后续命中情况。

## quality.yml

`quality.yml` 将代码质量检查与打包流程分离：

- Rust：格式检查、警告即错误的 Clippy、完整 workspace 测试；使用锁定依赖并覆盖所有 targets/features。
- Shell：通过 `bash scripts/lint-shell.sh` 检查主机工具和一方设备脚本，包括被 source 的运行时片段；通过 `bash scripts/test-host.sh` 执行 fixture 回归测试。
- WebUI：通过 `npm ci` 安装锁定依赖，再执行测试、`vue-tsc` 组件类型检查和构建；安装 Chromium 后，通过 `npm run test:ui` 检查手机、横屏和桌面布局，以及弹层焦点、键盘避让和草稿保留。浏览器测试使用 fixture，不访问真机。

本地 `scripts/pre-commit.sh` 复用这些入口，并用 `--with-routing-assets` 加跑需要
宿主机 sing-box 和预备规则集的路由/DNS 集成测试。CI 的 fixture 套件不包含这两项；
真机、打包和安装验证仍需单独执行。

## 本地自定义

共享基线只放通用逻辑。项目自己的 workflow 放到额外文件里；
`kam sync workflow` 会保留这些额外文件。
