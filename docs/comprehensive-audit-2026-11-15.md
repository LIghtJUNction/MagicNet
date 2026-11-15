# MagicNet 全面检查与修复报告

日期：2026 年 11 月 15 日

本轮确认并修复了 **8 类问题**，已通过 **7 个提交**更新源码，包括交叉审阅补充的配置读取大小保护。检查覆盖监督进程启停、Wi-Fi 策略、连通性观察、TUN 路由诊断、配置保存、WebUI 分流编辑，以及组件安装、下载和卸载。每项修复均对应明确触发条件和回归证据；报告不将尚未取得的真机结果计入通过项。

最终源码为 [`b6f3a37f`](https://github.com/LIghtJUNction/magicnet-android/commit/b6f3a37fb5d035105917f844a6a23bb499bc1a61)，Git tree 为 `d76352da5d50870b038da8dd401f45d1fcebeb53`。正式发布版本仍为 **1.8.7 / versionCode 10615**，本轮尚未发布新正式 Release。

## 一、已修复的问题

| 问题 | 影响与修复后的行为 | 提交 |
| --- | --- | --- |
| Wi-Fi watcher 退出识别错误 | 已退出但尚未回收的进程仍保留 `/proc` 目录，旧逻辑可能把它当成未知活跃进程。现在先核对存活状态，读取参数失败后再次确认退出；真正不可读的活进程仍保留未知状态。 | [cc1669d9][c1] |
| Connectivity stop/start 竞态 | 停止和启动未共同持锁，可能交错处理 PID 与新 watcher。现在二者经过同一生命周期锁，停止、清理和启动按顺序执行。 | [e699a227][c3] |
| Wi-Fi watcher 重复启动 | 并发启动可能同时通过旧状态检查。现在启停共用生命周期锁，后台 watcher 不继承控制锁，避免重复进程和后续启停阻塞。 | [e699a227][c3] |
| 切换出口协议带入隐藏凭据 | HTTP/SOCKS 表单留下的用户名、密码可能进入新协议载荷。现在用户名仅用于 SOCKS/HTTP，VLESS 排除隐藏密码，保留其 UUID/encryption。 | [4f675a1c][c2] |
| 编辑测速组重置用户设置 | 只修改 URL-test 成员，也会把自定义测速地址、间隔改为默认值。现在保留已有配置，仅在字段缺失时补默认值。 | [4f675a1c][c2] |
| TUN 路由冲突被报为正常 | 旧逻辑只合并 TUN 前缀，可能忽略竞争路由。现在检查重叠范围和前缀优先级；同等或更具体竞争路由缺少选择证据时报告未知，不再显示绿色就绪。 | [cc40dcdf][c4] |
| 配置与私密元数据部分提交 | 保存失败可能留下新配置与旧备份、标记或密钥的混合状态。现在将配置、备份、standalone 标记和 Tailscale keys 纳入同一受控提交，并检查目标目录身份。 | [76b0b069][c6] |
| 卸载被杀后重试假成功 | 无属主的旧锁目录残留，重试返回 0，却跳过服务清理。现在复用内核文件锁，回收旧空目录，锁异常明确失败，正常重试重新执行清理。 | [8d257266][c5] |

## 二、关键验证证据

**进程生命周期使用真实宿主进程验证。** 新增与扩展回归覆盖 Wi-Fi 僵尸进程、参数读取与退出交错、重复启动、并发启停和控制锁释放。检查同时保留“不杀无归属进程”和“未知状态不推断成功”的既有边界，避免修复恢复路径时扩大进程清理范围。[监督进程修复][c1]、[生命周期串行化][c3]提供对应代码和测试。

**前端复现检查的是实际提交载荷。** 新测试执行真实 `RoutingEditor.vue` 脚本和 Vue 响应式逻辑。修复前，协议切换与测速设置保留两项用例失败；修复后通过，并验证新组默认值、HTTP 凭据及 TLS 设置未回退。浏览器交互用例也已补入仓库，其本地执行状态单独记录。[前端修复与回归][c2]

**配置保存包含失败注入和目录替换对照。** 保存失败保留旧配置、keys 与备份；验证期间目标目录被替换时拒绝提交。提交前核对目录的设备号与 inode，防止验证完成后把内容写入另一个目录。成功对照核验提交结果和备份字节。[配置保存修复][c6]

交叉审阅另发现旧文件备份存在无上限 `read_to_end`。补充修复复用编辑器的 **8 MiB** 上限，以 `take(limit + 1)` 有界读取，验收要求超限时拒绝操作且配置、备份、标记和 keys 均保持原状。旧实现在 8 MiB + 1 字节用例中错误提交，修复后拒绝且四类目标不变；恰好 8 MiB 的原始字节备份仍成功。该项记录代码审阅与边界回归，没有把 OOM 写成已实测发生。[读取上限修复][c7]

**卸载故障已有完整前后对照。** 旧版在 `mcp stop` 阶段被 SIGKILL 后，重试返回 0，追加清理调用为零。修复后，同样中断再重试会执行 `mcp stop`、`supervisor stop all`、`service stop`、`state reconcile`。真实并发调用仍只产生一个清理者；原有失败传播、重复调用和独立 BusyBox httpd 清理回归继续通过。[卸载修复与回归][c5]

## 三、本轮验证结果

| 验证项 | 本轮结果 | 证据 |
| --- | --- | --- |
| Rust 全量测试 | 最终源码 **938 passed / 0 failed / 1 ignored**；870 项单元测试、68 项集成测试 | `rust-config-limit-full.log` |
| Rust 格式与严格 Clippy | 通过 | `rust-config-limit-fmt.log`、`rust-config-limit-clippy.log` |
| WebUI Node 测试 | **392/392 通过**，基线为 388 项 | `webui-final-tests.log` |
| WebUI Playwright 交互 | 源码 `76b0b069` 的完整六 viewport 流程通过，实际运行 453.61 秒 | [WebUI job](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793048/job/132856500047) |
| WebUI 类型检查、生产构建 | `npm run typecheck`、`npm run build` 通过 | 本轮命令结果；未改依赖版本或锁文件 |
| 组件质量闸 | `quality-gate.sh components` 退出码 0；含 Go vet、`go test -race`、打包、安装身份、KernelSU 生命周期及归档检查 | `components-quality-gate.log` |
| 卸载回归 | **18/18 通过**，使用真实 BusyBox 与进程 | `uninstall-tests.log`、`uninstall-killed-retry.log` |
| ShellCheck、工作流检查 | 按项目规则通过 | `shell-lint-final.log`、`source-workflows.log`、`parent-workflows-final.log` |
| 配方与归档验收 | **8 包、62 个 Markdown** 的 check、pack、archive、build 通过 | 主仓库集成 [d02b31a8][integration]，配方 0.3.25 / M70 |
| 发布与配方脚本回归 | **78 项通过**，三组分别为 18、41、19 项 | 本轮主仓库脚本验收结果 |
| 宿主综合回归 | **114 个唯一顶层任务全部取得通过结果**：首跑 104 项，环境修正后补测 10 项；原首跑退出 1 的事实保留 | `host-final.log`、`host-remaining.log` |
| 本轮 GitHub CI | 分别记录最终源码和前一修复提交的结果，见下表；进行中的工作流不计为通过 | 每个运行链接绑定实际 source SHA |

本轮本地日志位于工作区 `audit-logs/`，公开 CI 证据见上表。Rust 计数按顶层测试套件汇总，未重复计算测试内部启动的子进程输出。组件质量闸包含 `test-installer-identity.py` 对安装归档的检查，间接执行 `test-downloader-installer.py` 的验证器。

主机首跑在发行完整性检查处因三个嵌套子模块未初始化而中断；全部递归依赖按固定 gitlink 补齐。第一次续跑误用了不含 PyYAML 的配方虚拟环境，改回已有主 Python 环境后，失败项及后续九项全部通过。两次环境中断日志均保留，没有放宽检查。114 项为去重后的顶层任务覆盖，全部实际执行，无顶层缓存 HIT；不代表原先失败的整条命令退出码被改写为 0。

广泛主机首跑启动于 `76b0b069`；后续 `b6f3a37f` 仅修改配置编辑器的读取上限和回归，已重跑最终源码的完整 Rust 测试。主机补测十项也在最终源码上执行。

### CI 状态快照

以下状态读取于 **2026-11-15 15:34:57 UTC**。工作流会继续运行，表内 pending / in_progress 不计为通过。

**最终源码 `b6f3a37fb5d035105917f844a6a23bb499bc1a61`：**

| 工作流 | 本轮运行 | 状态 |
| --- | --- | --- |
| Rules Release Integration | [43729993381](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43729993381) | success |
| Code Quality | [43729993400](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43729993400) | in_progress |
| Android KernelSU Acceptance | [43729993357](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43729993357) | in_progress |
| Build MagicNet source | [43729993359](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43729993359) | in_progress |
| Network Regression Evidence | [43729993358](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43729993358) | success |

**前一修复提交 `76b0b069e0cf776dc48b00d8a97eeacbdf44c2ef`：**

| 工作流 | 本轮运行 | 状态 |
| --- | --- | --- |
| Network Regression Evidence | [43728793051](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793051) | success |
| Rules Release Integration | [43728793359](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793359) | success |
| Network regression | [43728793045](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793045) | success |
| Uninstall Farewell | [43728793189](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793189) | success |
| Android KernelSU Acceptance | [43728793047](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793047) | cancelled |
| Code Quality | [43728793048](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793048) | success |
| Build MagicNet source | [43728793357](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793357) | success |

前一提交包含八类核心修复；最终提交在其上追加配置读取限额。旧 Android 运行因新提交触发的同组运行而取消，不能记为通过。两次提交的结果保留各自身份，不能把旧提交的成功状态复制给新提交。

主仓库固定最终源码的 `d02b31a8` 已通过 [Recipe checks 43730082227](https://github.com/LIghtJUNction/MagicNet/actions/runs/43730082227)。

## 四、覆盖边界与发布状态

普通宿主回归的计数单位是顶层脚本任务；不包含 `--with-routing-assets` 模式，也不把各脚本依赖特定环境才运行的分支推断为通过。宿主测试、真实核心证据、Android 模拟器与用户物理设备分别记录。

**配置事务的已验证保证是预检、替换错误回滚和目录身份核验。** 跨文件提交没有取得 SIGKILL 或断电后的持久原子性证据；提交后的临时材料清理错误，也不表示已经回滚。调用者应根据明确的提交与清理结果解释状态。[配置事务实现][c6]

**浏览器结果分别记录本地与 CI。** 本地 Chromium 在启动阶段因 `socket() failed: Operation not permitted` 退出，尚未进入应用断言；随后源码 `76b0b069` 的 [WebUI job](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43728793048/job/132856500047) 实际执行完整 Playwright 流程并通过（453.61 秒，六种 viewport）。最终大小保护补丁不修改 WebUI；其 CI 复用情况另按实际结果记录。Rust 的 1 项 ignored 需要单独构建的 AOSP Android-profile mksh 和对应 watcher 夹具，普通宿主 mksh 结果不替代该项。

**卸载中断测试覆盖整个尝试进程组被杀后的恢复。** 第二个并发调用遇活跃锁时返回 0，不再启动清理；它不等待首调用结束，也不替首调用报告最终结果。独立 farewell 服务的宿主生命周期已测，Android ActivityManager 使用模拟接口。[卸载行为][c5]

自动 Android 流程针对 Android 15 / KernelSU / x86_64 模拟器，不包含仅手动启用的公网 benchmark 和 600 秒持续网络观察。本轮尚无物理 Android 设备、真实 NAS、实际用户换网场景的验收结果，也未发布新正式版本。当前交付包括源码修复、回归测试和本报告；后续设备验收应绑定这里列出的精确源码提交，分别核对实际网络路径、启停恢复与管理器安装卸载行为。

[c1]: https://github.com/LIghtJUNction/magicnet-android/commit/cc1669d9a3b09db709b3041b8a31aedca1dea41b
[c2]: https://github.com/LIghtJUNction/magicnet-android/commit/4f675a1c0937275f6275d8246cf33f84d75f999a
[c3]: https://github.com/LIghtJUNction/magicnet-android/commit/e699a227cb7f9ba399cdb1b50bf2fa64b3e9c7e8
[c4]: https://github.com/LIghtJUNction/magicnet-android/commit/cc40dcdfee6c95a17c998ad141b6f7386da25fd6
[c5]: https://github.com/LIghtJUNction/magicnet-android/commit/8d2572666a64312995cef3f687fa74f7afbd97f3
[c6]: https://github.com/LIghtJUNction/magicnet-android/commit/76b0b069e0cf776dc48b00d8a97eeacbdf44c2ef
[integration]: https://github.com/LIghtJUNction/MagicNet/commit/d02b31a8d6322c4c5e19f0aca9b36e3ff120d75b

[c7]: https://github.com/LIghtJUNction/magicnet-android/commit/b6f3a37fb5d035105917f844a6a23bb499bc1a61
