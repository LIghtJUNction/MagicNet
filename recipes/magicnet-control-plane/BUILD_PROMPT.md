# 特权控制面

交付单一受控入口 /data/adb/modules/MagicNet/cli，供用户、模块脚本、WebUI 和 MCP 使用。内部语言可变，argv、JSON、数据隐私和退出状态稳定。阅读 CLI_REFERENCE.md、MACHINE_CONTRACT.md、SUBSCRIPTION_INTERFACE.md、MCP_CONTRACT.md、STATE_CONTRACT.md 和 ACCEPTANCE.md。

依赖 runtime 负责实际进程生命周期、订阅与网络策略；必须委托它的事务，不在 MCP 或 WebUI 再建一套特权逻辑。集成验收：人类 CLI、schema-1 和认证工具操作同一设备状态，同一失败不被包装成成功。

control 0.2.3 增加 C-SUB-008：公共 sub.status、私密 sub.inspect、canonical producer 与支持包共用有界来源观测。URL 清单 64 KiB、本地正文 8 MiB；坏编码、NUL、链接、非普通文件和超限明确失败，缺失允许未配置。读取不创建任何目录或文件；canonical 与支持包的未知来源/数量不能伪报为零，service.status 保留独立服务事实。

## 人类入口

保留 CLI_REFERENCE.md 的命令族与参数。help 可读；错误非零退出；日志保留原语种/token。health 与 transparent status 是诊断入口，不存在 cli ebpf status。
Android 模块根必须由可信可执行路径/固定安装位置确定，不能由调用者 MODDIR 重定向特权代码。宿主夹具可显式使用独立 MODDIR；本地 API 仅允许 loopback HTTP 端口，拒绝远端/userinfo/路径混入。
privileged 子进程不能执行任意拼接 shell；文件 payload 有界、私有、校验归属与路径。凭据不放 argv，不在输出预览泄露。

## 机器入口

任意位置出现 --json 都由机器 dispatcher 完整接管；恰好一个 flag，未支持命令给结构化错误，禁止回落成人类写路径。stdout 只有一个 JSON，诊断 stderr；错误保留非零退出。
capabilities 是实际命令/字段能力事实源；status 默认脱敏，inspect 明确私密且用户主动调用。显式设计的 override、module-update、network-access 写例外必须保留各自并发、幂等、确认和回滚。
配置值与运行值用 configured/effective；null/unknown 不等同于 false/stopped/success。状态读取不应偷偷发布 canonical 或更改用户意图。

## 运行资源

命令/proc helper 在 spawn 前占用有界槽，同进程最多 64 个活跃或延迟回收子进程，一条共享 reaper；卡在内核的子进程保留槽，饱和拒绝。取消/超时关闭父端句柄，不生成无限等待线程。stdout/stderr 都公平有界读取，溢出与截断不能当作合法 JSON。
生命周期锁有截止时间，报 busy，不无限等 flock。JSON 配置/selector/Tailscale 读取 4 MiB 边界；Wi-Fi 名单和私密 curl stdin 64 KiB；拒绝 FIFO、symlink、非普通文件。curl 凭据走 stdin，超时、输出截断或输入交付失败明确失败。
资源数值是来源合同，不是推测的总 RSS 或速度保证。选择另一实现时必须通过相同可观察压力与清理验收。

命令预算由当前调用读取一次，创建 shell worker 时移除一次性 `MAGICNET_COMMAND_TIMEOUT` 覆盖。持久核心的启动、就绪交接和失败清理遵循 runtime/LIFECYCLE_CONTRACT.md；内部启动命令不绕过 `--json` 的机器分派。

MCP 与人类 CLI 的日志尾读共享同一快照语义：最多读取快照尾部 1 MiB，按原规则处理截断首行和无效 UTF-8，最多输出 1000 行，保留顺序、CRLF 与空行的处理规则及脱敏行为。定位末尾 N 行只扫描所需后缀，不为整个文件建立行数组；有效 UTF-8 直接复用读取缓冲区。用固定输入比较结果、临时分配和耗时，不把局部日志优化宣传成整机内存或网络吞吐提升。generic `magicnet_cli` 拒绝人类 `hotspot` / `hotspot status`；`file_list` / `file_read` 拒绝 `.state/hotspot` 及其 symlink 别名。接口名、客户端网段和回程对端只留在人类 CLI 与私密 journal，不能经 MCP 自动路径泄漏。`--json hotspot status` 与 named `magicnet_hotspot_status` 仍是脱敏入口。

## 本包补充材料

- [CLI_REFERENCE.md](CLI_REFERENCE.md)
- [MACHINE_CONTRACT.md](MACHINE_CONTRACT.md)
- [MCP_CONTRACT.md](MCP_CONTRACT.md)
- [STATE_CONTRACT.md](STATE_CONTRACT.md)

- [MCP_TOOL_SCHEMAS.md](MCP_TOOL_SCHEMAS.md)：完整已观察的工具目录。
- [SUBSCRIPTION_INTERFACE.md](SUBSCRIPTION_INTERFACE.md)：C-SUB-001–008，完整多源入口、公共/私密读取、逐源批次能力、计数、恢复及共享只读观测；subscription_batch_v1 是重建新增能力，不能假称旧源码已经实现。
