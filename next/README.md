# MagicNet 重写候选代码

**此目录不是已完成的替代版本，不是安装包。旧版生产入口、打包路径和测试仍保留。**

这是 PR #355 中独立的重写工作区。当前完成了新的 kamfw 基础运行时、配置/订阅/启停事务引擎、机器接口、四页 WebUI 和宿主机验证。尚未完成的内容列在 `docs/cutover.json`；这些内容未通过之前不得替换生产模块或宣称全面重写完成。

## 结构

- `crates/kamfw`：文件描述符固定的私有目录、原子文件、原生 flock、可恢复多文件事务、进程身份、受限工具执行。
- `crates/magicnet-core`：业务意图和配置版本、订阅整份替换、节点导入、取消、启停和回滚。通过 `Platform` 分离系统调用与业务测试。
- `crates/magicnet-cli`：有界 JSON/base64 stdin 接口和原生工具适配器。没有调用旧 shell 命令的隐藏降级路径。
- `webui`：概览、订阅、网络、维护。浏览器没有 KernelSU 接口时不模拟联网状态。
- `tests`、`webui/tests`：故障注入、真实 host CLI 集成、协议和布局验证。
- `docs/issues.json`：已检索到的 94 个 issue 的迁移要求。不是“已解决清单”。

数据分开存放：`.config` 是意图，`.state/generations` 是候选配置，`.state/transactions` 和 `.state/switch.json` 保留恢复证据。状态接口同时报告保存版本和运行版本，不假装跨文件读取是原子快照。

## 本地验证

使用 Rust 1.98.1、Node 24 和 Python 3：

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo build --workspace --locked
python3 -m unittest discover -s tests -p '*_test.py' -v
python3 tools/verify_scope.py
cd webui
npm ci
npm run check
npx playwright install chromium
npm run test:ui
```

布局测试离线加载生产 bundle，使用测试专用 KernelSU JS 适配器把真实 SDK 的 stdin 请求交给编译后的 Rust CLI。它验证的是宿主机上的页面、协议和业务状态，不验证 Android WebView/CSP、iptables、KernelSU 安装或真实应用联网。测试适配器不会打入生产 bundle。

## 独立试用目录

```sh
candidate="$(mktemp -d)"
cargo run -p magicnet-cli -- --root "$candidate" --initialize-candidate
cargo run -p magicnet-cli -- --root "$candidate" status --json
```

初始化拒绝非空目录。写操作要求有效候选标记；不会猜测或覆盖 `/data/adb/modules/MagicNet`。`--experimental-runtime` 是开发者显式启用的未验收适配器，不是验收凭证。默认 WebUI 不开放启用按钮。

原生工具仅从候选目录的 `bin/` 读取：`sing-box`、`curl`、Mike Farah `yq`。本目录不捆绑这些第三方二进制。订阅请求禁止继承 HTTP 代理、限制重定向/时间/体积，URL 走 stdin 而非 argv；这不证明绕过了设备内核的透明路由。

## 归档与撤回

原 MagicNet 提交 `1fff02713d1afe63bd57f67158dbc278817c9b75` 已保留在 `archive/pre-rewrite-20260926`。旧 kamfw 固定提交和递归子模块清单见 `docs/archive.json`。向 `MemDeco-WG/kamfw` 创建归档分支返回 403，本 PR 没有冒充已推送或合并上游。

目前撤回仅需移除此独立目录及对应候选 CI；生产数据和旧模块不需要迁移回去。未来真正切换前，必须有经过测试的数据迁移、反向回滚、完整功能移植和 Android 证据。
