# 特权控制面

交付单一受控入口 /data/adb/modules/MagicNet/cli，供用户、模块脚本、WebUI 和 MCP 使用。内部语言可变，argv、JSON、数据隐私和退出状态稳定。阅读 CLI_REFERENCE.md、MACHINE_CONTRACT.md、MCP_CONTRACT.md、STATE_CONTRACT.md 和 ACCEPTANCE.md。

依赖 runtime 负责实际进程生命周期、订阅与网络策略；必须委托它的事务，不在 MCP 或 WebUI 再建一套特权逻辑。集成验收：人类 CLI、schema-1 和认证工具操作同一设备状态，同一失败不被包装成成功。

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

## 本包补充材料

- [CLI_REFERENCE.md](CLI_REFERENCE.md)
- [MACHINE_CONTRACT.md](MACHINE_CONTRACT.md)
- [MCP_CONTRACT.md](MCP_CONTRACT.md)
- [STATE_CONTRACT.md](STATE_CONTRACT.md)

- [MCP_TOOL_SCHEMAS.md](MCP_TOOL_SCHEMAS.md)：完整已观察的工具目录。
