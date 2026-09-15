# Agent Instructions

本仓库根目录下的 `.env` 是本机私密环境文件。后续 agent 需要订阅信息、设备侧配置默认值或构建时私有变量时，先读取 `.env`。

`.env` 禁止提交、禁止写入补丁、禁止复制到文档、日志、issue、PR 描述或最终回复。回复用户时只能说明“已写入本地 `.env`”或引用变量名，不要回显订阅 URL、token、secret、password 等敏感值。

当前约定的订阅变量名：

- `MAGICNET_SINGBOX_SUBSCRIPTION_URL`：sing-box 订阅。

如果需要把订阅应用到真机运行配置，读取 `.env` 后写入设备上的：

- `/data/adb/modules/MagicNet/.config/sing-box/subscription.url`

通过 adb 给真机写入临时文件或中转补丁时，不要使用 `/data/local/tmp`。本设备该路径可能不可写。统一使用 `/sdcard/Download/MagicNet/` 作为中转目录，写入前 `mkdir -p /sdcard/Download/MagicNet`，任务结束后清理本次创建的临时文件，方便用户手动检查和清理。

修改代码或文档时遵守以下透明代理约束：主线显式支持 sing-box `tun`（`magicnet0`）和 `ebpf`（`type: "ebpf"` inbound）两种模式，默认仍为 `tun`，只允许 `tun|ebpf`，不新增 `auto`，不恢复 TProxy、Redirect 或 netd `ALLOW_MULTI` 路径。模式切换必须显式、原子且可回滚。`tun` 模式以 `magicnet0` 为准；`ebpf` 模式以 capability、cgroup 和 TC attachment 状态为准，不得错误要求 `magicnet0` 存在。统一通过 `cli transparent status` 和 `cli health` 报告状态，不假定存在 `cli ebpf status`。

## File-backed state contract

设备运行状态遵守“文件即状态”的统一状态面，详细设计见 `docs/state-plane.md`。

- `.config` 保存持久化用户意图；`.state/machines/*.state` 保存规范化的运行观测/恢复状态。不要把用户选择继续藏进 `.state`。
- canonical 状态固定放在 `.state/machines/*.state`，一个状态域只有一个 public canonical 文件；不要新增需要消费者组合多个 marker/PID/error 文件才能判断的 public 状态。
- 状态文件使用 `schema=1` 的有界 `key=value` token，不存自由文本。配置意图、运行观测、事务 phase、资源 ownership 必须使用不同字段，不得混成一个模糊的 `running`。
- 每个 canonical 文件必须通过原子替换发布。多个状态域同时变化时使用现有可恢复多文件事务：先完整计算、stage/sync，再提交；后续替换失败时回滚已经替换的文件。不要声称多个 rename 对无锁读者“同时原子可见”；需要跨域 point-in-time 视图的消费者使用机器接口。
- `.state/transparent-transaction/`、subscription journal、PID/owner 文件、缓存与 probe report 在迁移期可以继续作为恢复/观测输入，但新消费者不得把它们当成第二套 public 状态接口；优先消费 `.state/machines/*.state` 或机器接口。
- 外部事实（进程、接口、cgroup、TC、内核规则）必须 reconcile 后再写状态。证据不足写 `unknown`/`pending`/`stale`，禁止猜成成功。
- 长驻 producer 在内部观测状态发生变化后必须主动 publish canonical 状态，不能只依赖进程退出时的最终 reconcile。普通 shell 生命周期直接修改完状态后调用 `cli state reconcile`。
- canonical 状态禁止包含订阅 URL、SSID/BSSID、selector/node 名、原始 UID 列表、token、secret、password、auth key、原始错误 reason、命令输出或完整配置；使用布尔值、计数和规范化 token。
- WebUI 的按钮、弹窗、未保存编辑器等可安全随刷新丢失的展示状态仍留在内存；任何会跨 WebUI 生命周期继续存在的后台操作必须有设备侧文件证据，并投影到 canonical 状态。
- 迁移一个旧状态路径时，先让 producer/consumer 走 canonical 状态并补回归测试，确认无恢复依赖后删除旧路径，不长期维护两个事实源。

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
