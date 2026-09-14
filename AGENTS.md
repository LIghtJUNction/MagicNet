# Agent Instructions

本仓库根目录下的 `.env` 是本机私密环境文件。后续 agent 需要订阅信息、设备侧配置默认值或构建时私有变量时，先读取 `.env`。

`.env` 禁止提交、禁止写入补丁、禁止复制到文档、日志、issue、PR 描述或最终回复。回复用户时只能说明“已写入本地 `.env`”或引用变量名，不要回显订阅 URL、token、secret、password 等敏感值。

当前约定的订阅变量名：

- `MAGICNET_SINGBOX_SUBSCRIPTION_URL`：sing-box 订阅。

如果需要把订阅应用到真机运行配置，读取 `.env` 后写入设备上的：

- `/data/adb/modules/MagicNet/.config/sing-box/subscription.url`

通过 adb 给真机写入临时文件或中转补丁时，不要使用 `/data/local/tmp`。本设备该路径可能不可写。统一使用 `/sdcard/Download/MagicNet/` 作为中转目录，写入前 `mkdir -p /sdcard/Download/MagicNet`，任务结束后清理本次创建的临时文件，方便用户手动检查和清理。

修改代码或文档时遵守以下透明代理约束：主线显式支持 sing-box `tun`（`magicnet0`）和 `ebpf`（`type: "ebpf"` inbound）两种模式，默认仍为 `tun`，只允许 `tun|ebpf`，不新增 `auto`，不恢复 TProxy、Redirect 或 netd `ALLOW_MULTI` 路径。模式切换必须显式、原子且可回滚。`tun` 模式以 `magicnet0` 为准；`ebpf` 模式以 capability、cgroup 和 TC attachment 状态为准，不得错误要求 `magicnet0` 存在。统一通过 `cli transparent status` 和 `cli health` 报告状态，不假定存在 `cli ebpf status`。

## Machine interface contract

`magicnet-cli` 的机器接口是 WebUI、MCP 和未来 Android 管理器之间的稳定控制面，不得退回解析面向人的 CLI 文本。

- 机器接口固定使用 `schema=1` JSON envelope；成功响应至少包含 `schema`、`ok=true`、`command`、`data`，失败响应至少包含 `schema`、`ok=false`、`command`、`error.code`、`error.message`。
- 机器模式必须显式使用 `--json`。`--json` 一旦出现，请求必须由机器 dispatcher 完整接管；未支持的机器命令返回结构化错误，严禁落回普通 dispatcher 执行写操作。
- `--json` 当前只允许只读状态接口。新增机器写接口前必须单独设计幂等、错误码、并发和回滚语义，不能简单给现有写命令套 JSON。
- stdout 在机器模式下只能包含一个结果 JSON；日志、调试信息和可操作诊断写 stderr。不得在 JSON 前后添加 banner、进度文本或 shell 提示。
- `cli --json capabilities` 是客户端能力协商事实源。增加、删除、重命名机器命令或改变字段语义时，必须同步 capabilities、测试、MCP/WebUI 消费者和 `docs/machine-interface.md`。
- 机器状态默认最小披露：不得返回订阅 URL、token、secret、password、失败 reason 原文、SSID/BSSID 原文或其他不必要的设备标识。只返回业务需要的类型、布尔值、计数或规范化状态。
- 配置值与实际运行值不能混为一谈；存在差异的状态必须使用 `configured` / `effective` 或同等明确的字段分层。
- 不能把未知状态伪装为成功状态。例如 PID 枚举失败必须报告 `unknown`，不能当作 `running`；无证据时使用 `null`/`unknown`，不要猜测。
- 人类文本 CLI 为兼容层，可以继续存在；新消费者应优先使用机器接口，并在确有旧版本兼容需求时做显式、可测试的回退。
