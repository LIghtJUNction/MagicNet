# setup-kam — GitHub Action

- [![Release](https://img.shields.io/github/v/tag/MemDeco-WG/setup-kam?label=release)](https://github.com/MemDeco-WG/setup-kam/releases)

- [![License](https://img.shields.io/github/license/MemDeco-WG/setup-kam.svg)](LICENSE)

简介
---
`setup-kam` 是一个 GitHub Action，用于在 CI 环境中安装 `kam`（Rust CLI 工具），并支持可选模板导入与缓存加速。仓库自带两个工作流示例：`exec.yml`（运行任意 `kam` 命令）与 `init.yml`（用于初始化项目并可导入模板）。下面说明如何填写参数与触发这些工作流。

kam 简要说明
---
kam — Kam is a lightweight module management tool providing dependency resolution, build, and module management.

Usage: `kam <COMMAND>`

Commands:
- `init`      Initialize a new Kam project
- `build`     Build the module
- `version`   Manage module version
- `cache`     Manage local cache
- `tmpl`      Manage templates (import/export)
- `validate`  Validate kam.toml configuration
- `help`      Print this message or the help of the given subcommand(s)

Workflow: exec.yml（运行任意命令）
---
该工作流的触发配置（workflow_dispatch）包含一个可选输入 `build-command`，默认值为 `kam build -r`。`exec.yml` 流程会：
1. checkout 仓库
2. 使用 `MemDeco-WG/setup-kam` 安装 `kam`（`with.github-token` 与 `with.enable-cache` 可以配置）
3. 打印 `kam --version`
4. 在 shell 中执行 `github.event.inputs.build-command`

关键字段（简要）：
- workflow_dispatch -> inputs -> `build-command`：要执行的完整命令（字符串），例如 `kam build -r`、`kam build --release` 或 `kam validate`。

如何填写 `build-command`
- 通过 GitHub UI 手动运行：在 "Run workflow" 弹窗中填写 `build-command`（例如 `kam build -r`）
- 也可以在 `gh` CLI 或 API 中指定参数：
  - Example: `gh workflow run exec.yml -f build-command="kam build -r"`

Workflow: init.yml（初始化项目 / 导入模板）
---
`init.yml` 的 workflow_dispatch 有三个可配置输入：
- `template-url`：可选，默认指向仓库 release 上的模板 zip；若为空则跳过模板导入。
- `init-command`：要执行的初始化命令，默认 `kam init . -t kam_template -f`。
- `enable-cache`：是否启用缓存（`true` 或 `false`），默认 `true`。

该流程会在 checkout 后执行 `setup-kam`（传入 `template-url` 与 `enable-cache`），然后运行 `init-command`。


如何填写 `template-url` 与 `init-command`
- `template-url`：
  - 可以是 ZIP/TGZ 等压缩包（例如 `https://example.com/template.zip` 或 release 的下载地址），也可以是一个已解压的目录路径（如 `./template-folder`）。
  - 若传 `URL`，请保留文件名与扩展名（如 `.zip` / `.tgz`），否则 `kam tmpl import` 可能无法识别而拒绝导入。
- `init-command`：
  - 输入完整的命令行字符串，Action 会在 shell 中执行。例如默认 `kam init . -t kam_template -f`。
  - 注意：`-t`（或 `--template`）支持短 id（例如 `-t kam`、`-t meta`、`-t ak3`），会自动解析为 `<id>_template`（例如 `-t kam` -> `kam_template`）。如果传入的是完整模板 id（例如 `kam_template`）或路径/归档（例如 `./template-folder` 或 `https://.../template.zip`），将按原样使用。
  - 使用 `--tmpl`（无短名）可创建模板项目（`tmpl_template`）。你仍然可以使用 `kam init .` 或添加其他参数。

setup-kam Action inputs（说明）
---
这两个工作流中均调用 `MemDeco-WG/setup-kam` Action，常用 `with` 参数如下：
- `github-token`：默认 `${{ github.token }}`。用于访问私有 release/资产或进行需要鉴权的下载/操作。
- `enable-cache`：字符串 `"true"`/`"false"`，默认 `"true"`。启用后会对 `kam` 与 `cargo` 的安装进行版本感知缓存以加速后续流水线。
- `template-url`：用于初始化流程，指向模板压缩包或本地目录（参见上文）。


建议与注意事项
---
- 建议使用 `uses: MemDeco-WG/setup-kam@v1`（使用大版本别名），避免锁到某个补丁版本。
- 如果 `template-url` 指向压缩包，请一定保留文件名与扩展名（如 `.zip`/`.tgz`），否则 `kam tmpl import` 可能会拒绝导入。
- `GH_TOKEN` 当HOOKS 中调用gh命令时，需要此环境变量.

触发工作流（快速说明）
---
- 在 GitHub 仓库界面：Actions -> 选择 `exec.yml` 或 `init.yml` -> Run workflow 按钮 -> 填入对应参数并触发。

许可证
---
MIT
