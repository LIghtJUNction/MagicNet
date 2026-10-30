# 实现与发行验证

## 2026-10-30 / 配方 0.3.2：分支需求整合与订阅维护

本轮先更新配方，再进行源码修复。规格基于主仓库 `a7a05308aadbbf4d8362780d2773bf963437b1a5`，并同步保留 `d2a6c6ffa57bf39ae01cebee9defc852c8e685c0` 的 README 更新、最新 WebUI 设计、M41–M43 和源码 gitlink `b113f5128549172da6cb1f6e62f0b42d31adb956`；根包升为 0.3.2，control 为 0.2.3，runtime 为 0.1.3。来源为重建候选中的可复用需求及当前订阅合并、只读状态与模块目录问题；候选实现未替换主线源码。

新增 M44–M47、SUB-A19–A20、C-SUB-008，要求实际冲突引用才阻断同名节点、逐来源独立检查已知原生数量下界、URL/本地来源共享有界零写入观测，以及主仓库保留 module.yaml 和引用资源。支持包与 canonical 读取失败保持 unknown，service.status 保留独立服务事实。目录晋升、旧成功回执、网络策略完整恢复基线及 B/C 草稿反例并入原有验收。数量下界只补有限的丢节点检查，完整语义保真仍需独立证据。

**规格落盘时未验证：** 当前 main 的源码修复、对应主机回归和集成结果均待本轮实际执行后补记。独立候选的历史结果不能移作本轮结果；真实转换器、Android/manager、OEM 网络、真实多源订阅与 #426 现场根因继续按已有边界记录。产品构建与验收使用本地检查；未发布新安装包或部署设备。

**本地材料检查：** 使用 Recipkg CLI 0.1.1 执行 `python3 scripts/check-recipes.py`，目录 check、临时 pack、归档 check 和中文完整 build 提示词通过。归档含 8 包、55 个普通 UTF-8 Markdown，逐项检查无重复/危险路径、链接或 NUL，全部非 LOCK 正文完整进入提示词；临时归档与提示词已清理。`git diff --check` 通过。这只验证配方材料，不代表新增产品验收通过。

**主仓库修复与维护准备：** 根 `module.yaml` 从当前源码恢复，模块身份、官方地址、arm64-v8a、完整包名及 README/icon 的普通文件引用检查通过；`scripts/test-release.py` 的 16 项本地回归通过。一次性分支维护清单包含 62 个已证实为主线祖先的分支，以及本次内容整合后才成为祖先的配方候选分支。任务重新检查当前 main、每个分支 SHA、祖先关系及开放 PR，再用带精确 lease 的一次原子推送删除；两项隔离 Git 实验确认任何过期 lease 都使整批零删除、匹配 lease 只删除指定分支。清理的远端结果另记，完成后移除一次性入口；独立源码候选保留。

## 2026-10-29 / 独立重建候选：历史输入与证据

本节吸收配方候选 [`8acb763ff50f3626213c94165f4f3e3ae35ef247`](https://github.com/LIghtJUNction/MagicNet/blob/8acb763ff50f3626213c94165f4f3e3ae35ef247/recipes/magicnet/VERIFICATION.md) 的历史记录，保留候选来源和未完成边界。本轮未重新执行这些测试。它描述 Go 控制器、原生 ES modules WebUI、Android Java bridge 与组件安装器组成的独立候选，软件标识 v1.8.1 / versionCode 10609 / channel candidate；其代码与下文已正式发行的 Rust/Vue v1.8.1 是不同实现，不能互换验证证据。

候选记录称从空目录和新上下文，使用完整冻结配方生成，未读取旧 MagicNet 实现、二进制或测试；共享文件系统与读取约束不等于 OS 级隔离。实际输入为 335,805 bytes、8 包、53 个 Markdown，SHA-256 `502e160a363ffdc6e60477261ac15b74884b07f37de78af69558b0806f8e717a`。原始提示词随候选源码保存于 `recipe/BUILD_PROMPT.md`，不以本轮新配方替换或追认新增要求已经输入。

功能提交为 `280f044a0dc63f49965a910efd9509abd13a316b`，本地最终交付为 `532d51e71bf1d91017409bfe16b6601a2bfbee75`；公开候选为 [`b22f9f280ddaf729da47078c13838a73e6d89294`](https://github.com/LIghtJUNction/magicnet-android/tree/b22f9f280ddaf729da47078c13838a73e6d89294)，记录中的完整 tree 同为 `f45d5e0b5bee6245d8968ed35d6e4aa23a57c54b`。复用核心固定 `871b7a3440cd9c850f1b09ef3b4ada9babb4384b`、规则固定 `f3335f9420d07b8c50b26488df2a9492da6bbb44`；依赖、许可证、具体产物摘要和完整报告见[候选源码 VERIFICATION](https://github.com/LIghtJUNction/magicnet-android/blob/b22f9f280ddaf729da47078c13838a73e6d89294/VERIFICATION.md)。

| 历史记录中的检查 | 记录结果 | 范围 |
| --- | --- | --- |
| 真实 CLI 与固定核心 check 订阅回归 | 204 断言通过 | 合成格式、身份、同名节点、payload、长字段、批次和隐私 |
| 受控 HTTPS 来源夹具 | 10 个叶场景通过 | 五源、缓存、回滚与获取边界；不是公网服务商成功 |
| 公共 batch schema / 机器接口 | 18 份结果 / 10 项通过 | 实际输出的类型、计数、代次、严格 envelope 与拒绝行为 |
| MCP daemon | 29 项通过 | 回环认证、85 工具 schema、私密边界、7 资源与 notification 零写入 |
| 独立恢复 / 关键 UI 流程 | 13 项 / 10 项通过 | 晋升、回执、部分恢复、B/C 草稿和本地导入 |
| 包与真实目录 rename | 16 项通过 | 7 组件、别名、权限、离线安装与目录晋升；宿主替换为对应 host 二进制后验证，不等于真实 manager 安装 |
| 最终 Go race / vet | 56 个顶层、72 个含子用例通过；vet 通过 | 只属于该候选的固定提交，不与其他断言数量相加 |

候选的四个反例形成了本轮保留的要求：staging 绝对路径晋升后失效；旧成功回执绕过当前锁与恢复检查；部分 repair 缩减原完整回滚基线；零来源曾取消编辑后导入 B，导致新草稿 C 被隐藏。它们分别进入 M12、M13、M11 和 UI-SUB-CASE-07。候选记录还保留首版失败、修复后复验与夹具修正，不能将公开反例改称未见测试，也不能据此推断当前 Rust/Vue main 存在相同缺陷。

M40/RELEASE_CONTRACT 在候选 53 文件输入冻结之后新增，正式发布适配及同提交 Android/KernelSU 门槛未完成；M41–M43 和最新 UI 合同同样不能追认已被旧输入覆盖。候选没有外部 converter 实现/交付，不是单纯测试环境缺工具。实际 Android manager 安装重启、SELinux/binder/OEM、TUN/eBPF/TC 数据面、热点/IPv6、真实应用 DNS、真实多服务商导入、VLESS 加密服务器互通及长期运行仍未验收。该候选当时没有创建官方 Release 或部署设备，#426 的现场根因仍未证实。

## 2026-10-30 / 配方 0.3.1：#429、#430 与日志资源开销

本轮在既有实现上修复，源码提交为 [`72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae`](https://github.com/LIghtJUNction/magicnet-android/commit/72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae)，tree `1976d9f38b6a2e0520535c7256130ebe1cff114b`，父提交为 v1.8.1 源码 `a5617d6371fe17494fb4b4a6f655a0c8a0f7461e`。源码先推送到已授权的 `main`，主仓库再固定同一 gitlink；不是从零独立重建。配方根包为 0.3.1，control 为 0.2.2，runtime 为 0.1.2。

### 修复与实测

- **#429：预算与服务交接。** 当前 CLI 消费命令预算后，从运行时 shell 子环境移除一次性覆盖。普通核心启动和订阅激活共用交接流程：启动前持有原配置 guard，临时 worker 作为核心的直接父进程，核心建立独立 session。就绪前的中断保留清理责任和互斥；就绪后临时进程退出，核心不再受旧控制组的超时清理影响。
- **真实进程故障测试。** 新增 `service_launch` 的 9 项测试覆盖控制超时、SIGKILL、launcher 死亡、EOF/错误确认、长期守护后续命令预算、订阅入口和两项独立复现的竞态。第二配置 writer 在旧核心清理中被拒绝，清理结束后可正常取得锁；核心主进程先退出、后代忽略 TERM 时，后代仍被终止。正常交接后核心存活、两个临时 CLI 退出，原 guard 可重新取得；核心不继承 fd8、额外注入的 fd9 或短预算，`GOMEMLIMIT` 保留。
- **#430：无溢出的 PID 校验。** 四处入口共用 shell 内建校验，接受规范十进制 `1..2147483647`，避免让越界输入先参与 32 位算术。真实 mksh 复现旧上界 `4294967295` 变为 `-1`、正常 owner 被拒；仅替换上界仍会漏过 `4294967297`。修复通过 Bash、POSIX sh、mksh R59、固定 KernelSU BusyBox 的边界、锁回收、unknown 和禁止错误发信号用例；独立整数参照比较每 shell 6,063 个样本，共 24,252 个判断一致。新矩阵接入日常 `test-host.sh`，mksh 为必需项。
- **日志内存与复用。** CLI/MCP 共用有界快照读取，按请求行数定位尾部，有效 UTF-8 复用读取缓冲区。233,280 组旧/新输出对照一致；局部峰值堆和耗时测量见 PERFORMANCE.md。该测量不包括文件系统、脱敏、网络或整机 RSS。

### 最终本地门槛

| 门槛 | 实际结果 |
| --- | --- |
| Rust workspace / all-targets / all-features，locked、offline、2 test threads | **820 通过、0 失败、1 既有忽略**，10 个顶层 suite；不重复计入隔离子测试 |
| Rust fmt 与严格 Clippy | 通过，包含 warnings、dbg_macro、todo、unimplemented 拒绝 |
| 主机回归入口 | **106 个检查条目分批通过**；先完成 35 条，补齐 JDK 17 后从原失败入口继续完成其余 71 条 |
| 最终启动接线后的专项 | 配置锁安全/预算、核心 ownership/三态、15 项启停回滚、订阅生命周期/停止全部通过；另有 graceful-stop 18 项、订阅信号 12 项及获取策略通过 |
| ShellCheck、源码文本与策略失败检查 | 全仓 ShellCheck 通过；765 个受跟踪文本文件 sanity、6 项 lint 回归、12 项策略失败回归通过 |
| 订阅与宿主前提 | Clash/协议 28 项中 24 通过、4 因缺少真实转换器跳过；Java 请求引擎 7 项与固定 BusyBox UTF-8 专项通过 |
| 配方与主仓库发布边界 | recipkg check、pack、归档 check、完整提示词通过，8 包、55 个 Markdown；发布边界 16 项通过 |
| 改动检查 | 两仓库 `git diff --check` 通过；未改变源码依赖锁或嵌套依赖固定点 |

Rust 的一项既有忽略需要单独构建的 AOSP Android-profile mksh 和 watcher fixture；不能把普通 Linux mksh 的 PID 专项记作该 watcher 已验收。宿主网络/进程测试在可正确读取 `/proc`、使用进程组和回环 socket 的环境执行；受限执行环境里的 EPERM 和 PID 视图不一致不作为产品结论。

验证中修正了测试夹具：订阅入口先声明 API 替身再加载配置函数，成功路径给真实一秒轮询留出三秒测试预算，故障路径仍为一秒；慢 HTTP 用例保留服务端句柄至响应读取完成，避免仍有请求字节时关闭 socket 导致 RST 截断。完整 408 响应与原 1.5 秒处理门槛均保留，并为 handler 等待保留三秒测试上限。一次共享构建目录并行编译期间的自执行 ENOENT 在独占执行后消失；最终完整 Rust 结果来自上述固定代码的一次成功执行。

固定 KernelSU BusyBox 只作为 PID/UTF-8 专项工具。曾把它加入所有宿主检查的 PATH，发现其 `%s` printf 在本宿主写出内容后仍返回 1，原基线和候选的安装夹具均受影响；未修改安装逻辑或放宽断言来掩盖该试跑。106 条主机检查使用正常宿主工具路径。

本轮未运行远程 Actions、完整 Android/前端构建、模拟器、arm64 真机、热点客户端或真实订阅网络验收，也未创建新版本或安装包。当前公开版仍为 v1.8.1。新交接 worker 自身被外部单独 SIGKILL 的清理兜底未覆盖；内核阻塞使核心尚未退出时，worker 继续保留 guard，控制调用报告清理未完成。#426 缺少现场失败事务证据，仍保持开放。

## 2026-10-29 / v1.8.1 已公开

[稳定版 v1.8.1](https://github.com/LIghtJUNction/MagicNet/releases/tag/v1.8.1)，versionCode=10609，于 2026-10-29 14:21:41 UTC 公开，包含 19 个附件。标签与构建来源固定配方提交 `b762b8c54b99c7561914d3a02c3a635636ae6837`，源码提交 `a5617d6371fe17494fb4b4a6f655a0c8a0f7461e`。

[构建运行 40866529603](https://github.com/LIghtJUNction/MagicNet/actions/runs/40866529603) 的构建、完整质量门槛和全部 Android job 成功；原 publish job 因草稿标签查询 HTTP 404 失败。[独立恢复运行 40890649318](https://github.com/LIghtJUNction/MagicNet/actions/runs/40890649318) 全部成功：重新核对原 run、各门槛及不可变 artifact 的身份和归档摘要，检出原配方与源码，再执行原完整资产验证器，核对 19 个最终文件的摘要、ZIP CRC/metadata、来源记录和服务端附件后，按原 release ID 427831362 公开。公开前后的附件 ID、名称、大小、状态及摘要完全一致，没有重建、换附件或重写标签。正常发布流程的草稿查询已改为唯一数字 ID，16 项边界回归通过。

公开 API 已确认稳定标记、19 个附件及相同目标提交；匿名下载的安装器和 6 个元数据附件均与服务端 SHA-256、SHA256SUMS 一致，公开 update.json 与本仓库相同。所有附件的完整字节检查由上述 GitHub 恢复运行执行；本机没有重新下载完整离线包。下方保留各轮失败与当时 pending 的准备记录，不将原发布工作流写成全绿。

本节正式发行版来自既有实现迭代，没有执行从空目录独立重建；独立 Go 候选另按上节记录。尚未执行该正式版的 arm64 真机安装、真实订阅/网络互通或长期运行验收。Android 15 / KernelSU / x86_64 模拟器结果不能代替这些验证。

## 2026-10-29 / v1.8.1 发行准备

用户已授权发布新版本。软件版本为 v1.8.1，versionCode=10609；初始发行准备固定 `68ad77453d752845eedb5dd8ca56110c18de4b26`，保留已有六个嵌套依赖 gitlink。源码和主仓库的 update.json、模块 metadata 与发行说明同步，配方版本仍为 0.3.0。

本地 WebUI 338 项测试、TypeScript 类型检查和生产构建通过；发行准备 42 项、发行门槛 5 项、主仓库发布边界 13 项回归通过。Clash/协议订阅 28 项中 24 通过、4 项因缺少真实转换器明确跳过；订阅用量与 5 个订阅事务/恢复场景通过。源码文本 sanity 和 git diff --check 通过。配方 check/pack/归档 check/完整 build 提示词检查通过，8 个包、54 个普通 UTF-8 Markdown 文件。

正式发行通过主仓库 release.yml 的 mode=publish 发起；发行准备时，完整 Android 模块、完整质量门槛、Android/KernelSU 模拟器及上传发布均为 pending，最终结果见上方公开发行记录。没有执行 arm64 真机安装或真实网络验收，旧 dist/MagicNet.zip 不作为本版本证据。


首次正式运行 [40845027142](https://github.com/LIghtJUNction/MagicNet/actions/runs/40845027142) 的配方预检通过，Android 前置 UTF-8 测试在 Ubuntu dash 下失败，发布被拦截。失败原因为原生计数/构建中的单节点解析返回非零，在 dash 的 set -e 继承下提前退出，误报 native_count_failed；不是固定 BusyBox 二进制下载或摘要错误。修正为显式捕获节点解析失败，再由整体完整性门槛拒绝部分转换。

修复提交 `8a2e14609ffaa802ca6ac7dc844017637749430d` 已推送源码 main。本地以从 Ubuntu 官方包提取的 dash 0.5.12、Bash 和 SHA-256 固定的 KernelSU BusyBox 运行同一 UTF-8/不完整转换测试通过；生产 shell 语法、ShellCheck warning 级检查和 761 个文本 sanity 通过。运行时 BUILD_PROMPT、订阅接口合同与验收同步；修复后的正式完整运行仍为 pending。


第一轮后续完整 Rust 门槛另有 1 项夹具竞态失败：764 通过、1 失败、1 忽略；模拟退出线程逐文件删除 proc 目录，检查者可能看到 stat 消失而父目录尚在，生产检查因此保守拒绝所有权，行为符合安全边界。源码 `9770f8f29db8e240eff24f774fb32807f2f3e005` 将这个测试场景改为原子 rename 模拟 /proc 消失，未修改生产进程保护逻辑。第二轮 [40847078954](https://github.com/LIghtJUNction/MagicNet/actions/runs/40847078954) 的 Android 前置检查已成功，为绑定最终源码主动取消后续构建/模拟器任务。

候选 `9770f8f29db8e240eff24f774fb32807f2f3e005` 的本地 cargo fmt、严格 workspace/all-targets/all-features Clippy 通过；9 个顶层 Rust suite 共 808 通过、0 失败、1 显式忽略。资源受限的本机使用 CARGO_BUILD_JOBS=1 和 test-threads=2。

第三轮 [40849211338](https://github.com/LIghtJUNction/MagicNet/actions/runs/40849211338) 完成模块构建、包内容/安装迁移、核心/组件/完整离线包、增量安装器检查及 Android 15/KernelSU/x86_64 模拟器门槛；Rust fmt/Clippy/完整测试在 CI 通过。完整质量门槛随后因 ShellCheck SC2094 提示失败，publish 被跳过，没有创建发行版。修正为退出 URL 读取循环后统一清理本次临时清单，写入错误仍中止整批；同时补齐根发布工作流的 mksh 主机依赖。

本地收集全部 105 个主机检查条目，首次 100 通过、5 失败。旧三参数生成器夹具/调用、按 tag 丢节点的旧断言、非法 URL 成功夹具及发行缓存测试缺少显式仓库身份已同步；保留原安全断言，按不同端点核对同名节点完整保留。五个失败条目逐项复验通过，服务选择器使用从固定 sing-box `871b7a3440cd9c850f1b09ef3b4ada9babb4384b` 构建的主机核心，模式用例使用实际 mksh；没有将系统原版 sing-box 的字段不兼容当成项目失败。完整 ShellCheck、761 文件 sanity 与 git diff --check 通过。

第四轮候选固定 `8f6ddbc362bb7059be91b7734061b2c1e5381e56`。本地浏览器单进程运行因 18 分钟全局上限结束，482 项通过、268 未执行，没有用例失败；随后独立补跑 phone-430、landscape、desktop，372 通过、3 跳过。结合首次完整通过的 narrow-320、phone-360、phone-390，分批覆盖六个项目的 750 个用例，747 通过、3 按视口条件跳过；不把分批覆盖写成一次完整执行成功。

第四轮 [40858578985](https://github.com/LIghtJUNction/MagicNet/actions/runs/40858578985) 的模块、安装/迁移、组件及 Android 15/KernelSU/x86_64 门槛通过；Rust 全套及 ShellCheck 也通过。主机 AI 分流用例在 Ubuntu 的 jq 1.7.1 下报语义聚合程序解析错误，publish 被跳过。本地原 jq 为 1.8.2；从 jqlang 官方发行获取并核对 SHA-256 的 jq 1.7.1 稳定复现同一错误。给两个 reduce 结果绑定加上完整表达式括号后，原失败用例在两个版本均通过；无新增依赖或机器接口变化。

当前源码 `a5617d6371fe17494fb4b4a6f655a0c8a0f7461e` 的完整 shell 检查以 jq 1.7.1、Ubuntu dash、mksh 及固定项目核心一次通过，105 个主机检查条目全部成功。额外执行真实 Linux 网络命名空间路由用例，内核删除歧义、资源归属、UID 0 排除、TUN 地址更换和热点回程清理通过，测试命名空间已回收；这仍不是 Android netd、OEM 内核、TUN TCP 握手或物理热点客户端验收。

第五轮 [40866529603](https://github.com/LIghtJUNction/MagicNet/actions/runs/40866529603) 的 plan、完整 build/质量门槛及三个 Android job 全部通过，配方提交为 `b762b8c54b99c7561914d3a02c3a635636ae6837`。发布 job 已成功验证构建字节并创建稳定版草稿、上传 19 个附件；随后按尚未公开的 tag 查询草稿返回 HTTP 404，尚未调用公开操作。原 artifact 为 12895739203，归档 SHA-256 为 `f41661742019a3a7be0ccea62ea152a75302ea6364a41083b8e3c32b2279621c`。

正常发布步骤改为通过唯一草稿数字 ID 读回与公开，已有 16 项发布测试通过，覆盖无公开 tag 的成功路径、缺失/歧义/非法 ID 及错误服务端摘要的拒绝。现有草稿 ID 427831362 的版本、目标配方提交、稳定标记和 19 个附件身份已定位；本地大文件下载遇到反复 TLS/超时，独立恢复改由一次性工作流在 GitHub 内重新验证原 run 的全部门槛和同一不可变 artifact，然后核对原草稿字节。随后恢复成功，见上方公开发行记录；完成后移除本次专用恢复工作流，保留永久发布修复和回归测试，不把原失败的 publish job 记成成功。

## 2026-10-29 / 跨仓库 CI 与发行入口修复

修复前，MagicNet main 没有根 `.github/workflows/`；旧工作流位于实现子模块，不能替主仓库运行。正式发行仍使用 LIghtJUNction/MagicNet，源码仓库固定为 magicnet-android。当前源码提交为 `b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7`，已先推送源码 main 并回读核对。软件版本仍为 v1.8.0，未创建新标签、草稿或发行版。

- 新增主仓库手动 release.yml、PR/手动轻量 recipes.yml；默认 build 只产出 artifact，publish 必须通过同一 gitlink 的构建、完整质量门槛和 Android/KernelSU 验收。只发布 job 申请 contents:write。
- 恢复版本固定的官方 installer URL；记录配方/源码两个提交。最终资产检查包括完整文件清单、组件/内嵌 manifest、大小和 SHA-256、三个核心别名、模块身份与版本。上传草稿后再次检查 GitHub 的资产清单、大小及摘要，失败不公开。
- 源码接受显式 source_sha，并在两个 Android job 检出后核对完整 SHA；模拟器 fixture 正确记录实现提交。旧源码发行脚本拒绝从源码仓库创建发行请求。源码仓库的七个修改文件已提交并推送，未触发远程 Actions。
- 本地 155 项相关回归通过：主仓库发布边界 13、源码发行准备 42、发行门槛 5、Android 模拟器主机回归 69、模拟器工作流/夹具回归 26。它们是主机与合成测试，不是已经运行 Android 模拟器。
- actionlint v1.7.12 检查两个主仓库工作流及修改的 Android 工作流通过；26 个主仓库 Actions/composite shell 步骤语法通过，非 Python heredoc 步骤同时通过 ShellCheck。源码 760 个受跟踪文本文件的 sanity 检查通过。
- 本地 recipkg check、pack、归档 check、完整 build 提示词检查通过：8 个包、54 个普通 UTF-8 Markdown 文件，依赖包身份完整，无链接、unsafe path、NUL 或非 Markdown；所有非 LOCK 正文完整进入提示词。临时归档与提示词随检查自动删除。

本轮未执行完整 Android/WebUI 构建、远程 Actions、真实上传发布、签名或设备/真实网络验收。已有 dist/MagicNet.zip 保留，未作为本次源码构建通过的证据。工作流静态与回归检查通过不等于 CI 端到端已经跑通。工具下载曾遇到 TLS 错误，改用同版本 actionlint 固定源码本地编译；临时工具及编译目录在任务结束清理。

## 2026-10-29 / 配方0.3.0：#426源码提取与重建准备

本节只记录本轮事实；下方源码迁移、v1.8.0开发和初次迁移记录保持其原提交归属。当前产品源码固定0dca28dd984d82333707cbf4b222596934b4d847、tree bcb709f66bc2eb6a19021bd2f969f7cf2fa2198a，没有修改产品文件或gitlink。配方从0.2.1升至0.3.0；没有构建、发布或声称新Android版本。

### 材料和结构

- 使用实际Recipkg CLI 0.1.1（源码d0879adba69989cfe3edc7cf0d069a7b139f6410），运行extract生成提取任务，并实际按固定源码阅读；extract本身只渲染文字，不冒充自动读源。
- `recipkg check recipes/magicnet`通过；临时pack生成magicnet-0.3.0.recipe.tar.gz，归档再次check通过；`recipkg build <archive> --lang zh-CN --output <temporary-prompt.md>`通过。
- 归档包含8个包、53个普通UTF-8 Markdown文件（含LOCK），无链接、NUL、源码/二进制、Git元数据或私密文件。逐份比对所有非LOCK Markdown正文均完整进入build提示词，5份新增详细合同/源码审查材料均存在，没有只给根文件或摘要。
- 根集成验收M01–M39连续且唯一，原M01–M29未删除；新SUB/C-SUB/UI-SUB/VE/POLICY合同接入入口和验收。版本与DEPENDENCIES表一致。临时归档/提示词按仓库约定在检查后清理，不将生成物提交Git。
- `git diff --check`通过。旧源码工作区干净，.gitmodules、源码gitlink和共享技能gitlink保持不变；GitHub回读topics为recipkg，无需修改。独立重建不再要求先初始化旧产品源码。

### 真实执行的旧源码检查与探针

环境为隔离Linux宿主：GNU Bash 5.2.21、jq 1.7、Python 3.12.14、Node v24.22.1。全部使用合成数据；没有真实订阅、设备或流量。

| 命令/场景 | 实际结果 | 证据层次及限制 |
| --- | --- | --- |
| 在固定源码根运行 `python3 -I scripts/test-clash-subscriptions.py` | 28项：24通过、4跳过，退出0 | 原源码解析/合成测试；4项因未提供真实转换器跳过，不算通过 |
| `bash scripts/test-subscription-usage.sh` | 通过，退出0 | 合成响应头/用量行为，不是服务商现场 |
| `bash scripts/test-subscription-transaction-atomicity.sh` | 5项恢复场景通过，退出0 | 原测试使用模拟核心validator，只证明对应文件恢复机制 |
| 同名节点聚合探针 | 单独A/B成功；同名不同端点组合返回1；仅改B名称组合返回0，探针整体退出0 | 真实旧提取/计数/聚合函数，转换器输出为合成stub；退出0表示旧缺陷成功复现，不是已修复 |
| VLESS原生解析探针 | YAML完整性/输出返回0却缺encryption；带encryption=none分享链接完整性返回1；探针退出0 | 原函数+框架bootstrap替身；不是完整导入、核心check或协议互通 |
| 在固定源码webui目录运行 `node --experimental-strip-types --test subscription-user-agent.test.mjs` | 1通过、0失败，退出0 | 无需安装依赖的原前端helper测试；不是Vue页面/原生桥/E2E |

探针的合成输入、关键原始输出和具体源码位置已固化在SOURCE_AUDIT.md及runtime合同。复现脚本SHA-256：同名聚合e9eb6a902385b9b4b65e2aaee7ee9d84ec67c367cda5617297be62d376184f1d；VLESS探针源与输出在本轮临时观察材料，原产品文件指纹见PROVENANCE.md。临时脚本不作为配方执行依赖或新实现测试成果。

### 未执行及结论

本轮未运行真实转换器完整兼容、Rust整套/新Android编译、浏览器E2E、Android原生桥、真实多来源订阅、加密服务器互通、设备安装升级、多OEM/热点IPv6/实际应用及长期网络测试，也未进行从空上下文独立重建。缺少Vue/TypeScript依赖，因此没有把单个Node helper测试扩大为前端全套通过；没有为此下载大依赖。

#426的附件只证明单源成功记录，本轮发现的聚合缺陷可解释同类症状，但尚不能确定其现场根因。Issue保持待实现/待验证；配方更新不等于旧实现修复。新增subscription_batch_v1、URL统一身份、同名节点保留、VLESS管理链路保真均是未来实现验收目标。


## 2026-10-29 源码子模块迁移

根配方版本为 0.2.1，Android 软件仍为 v1.8.0。独立源码提交 `0dca28dd984d82333707cbf4b222596934b4d847` 与原已发布提交 `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf` 的完整 tree 均为 `bcb709f66bc2eb6a19021bd2f969f7cf2fa2198a`，含六个固定嵌套子模块。当前目录无源码修改，原分支与历史保留；根私密 `.env` 未追踪，未复制到实现或配方。

11 个共享技能逐个核对 origin、完整提交、干净状态、SKILL.md 和 Markdown 资源；原项目自定义技能保留。源码仓库仅发布当前 tree，不带入原历史已删除的本地工具数据库。

- `recipkg check recipes/magicnet`、临时 pack、归档 check 与完整 build 提示词生成通过。遍历归档确认 8 个包、48 个普通 UTF-8 Markdown 文件，无链接、NUL、源码、Git 元数据或私密路径；每份非 LOCK Markdown 的完整正文均出现在提示词中。临时归档和提示词已删除。
- 主仓库 index 的源码条目为 mode `160000`，固定上述源码提交；`.gitmodules` 指向独立源码 URL，入口未被忽略。源码 `.git` 由标准 `git submodule absorbgitdirs` 接管，递归检查既有嵌套子模块状态均干净；原自定义技能无差异。
- 独立源码仓库已公开，远端 main 与本地提交一致。禁用凭据 helper 后从公开 URL 做全新浅检出，核对完整 commit/tree、单提交历史及私密路径排除，再从各公开上游初始化全部六个直接子模块，固定点全部匹配。临时检出已清理。
- 原 MagicNet 仓库已有 topics 为 `recipkg`；幂等添加后回读仍为 `recipkg`，没有删改其他 topic。`git diff --check` 与 staged diff 检查通过。
- 主仓库布局提交 `18165e1ce100fb359dfead5322d9dafd794098ea` 已推送至 main；GitHub API 回读 generated 入口确实链接到独立源码仓库的上述固定提交。禁用全局/系统 Git 配置与凭据 helper，按 README 路径做全新公开递归浅检出，24 个子模块（含 11 个共享技能及全部嵌套源码）均匹配 gitlink，工作区干净，源码 tree 正确，主仓库与源码均无 `.env`，重新运行配方 check 通过。临时完整检出已清理。

这些检查只验证迁移结构、配方材料和公开源码可获取性。没有重新构建 Android、发布新版本或执行真机/网络验收；下述 v1.8.0 记录是同一源码 tree 的历史验证证据。

## v1.8.0 本轮开发

2026-10-28，按照当前递归配方继续开发既有 Rust、Shell、Vue 实现。源码固定 `f13ca61b9c3477aee3b1380d71815c84b3a2a6bf`，软件版本 v1.8.0 / versionCode 10608，配方版本 0.2.0。当时源码位于本地忽略的 `generated/magicnet-android/`，通过原仓库软件标签提供；现已改为上节的独立源码子模块。`android-reference` 已按要求移入回收站。

- Rust：完整本地测试 808 passed、1 ignored；fmt 和严格 workspace/all-target/all-feature Clippy 通过。
- WebUI：338 项本地测试、类型检查、生产构建通过；新增分流、凭据编辑、冲突与撤销等 36 项浏览器任务通过。完整 750 项浏览器任务完成：747 passed、3 skipped、0 failed（6 种视口，中英俄与浅深主题、配置、订阅、导航、后台进度与恢复等）。
- 真实锁定内核：Linux amd64 和 Android arm64 均从固定 fork 源码构建，保留全部 release tags（含 eBPF、Tailscale、WireGuard 等）。用 Linux release CLI + 真正内核在隔离目录运行结构化分流 preview、save、materialize、重复生成、订阅新增项重叠、reset 检查通过；没有启动代理或修改宿主网络。一次最初夹具缺少 default_domain_resolver 被真实内核拒绝，补齐合法夹具后通过，没有关闭验证。
- 回归修正：先从当前配置和 checkpoint.effective 同时剥离自己的增量项，再执行旧 Merge Patch 的逆向合并，避免“同域名原规则还在”被误报外部冲突；应用/DNS/域名的真实归属与订阅新增项均有覆盖。
- MCP：隔离宿主 initialize 与认证 tools/list 成功，85 项 Schema 完整保存；未认证请求被拒绝；generic app inspect 被拒绝；临时凭据与监听进程已清理。
- 性能：对新 release CLI 的三个空模块读接口分别预热 1 次、测 7 次，均校验有效 envelope；全部样本与并行负载限制见 PERFORMANCE。本轮不宣称改善，未测 Android 吞吐、全模块 RSS、冷启动或公网 soak。
- Android 完整模块构建与 post-build 包检查通过，包含真实内核配置、订阅协议、TUN/eBPF 编排夹具及 78 项默认路由/DNS 检查。当前代码的安装升级夹具（含 21 项模板与配置迁移检查）、模拟 Magisk 完整生命周期、拆分后的完整包、最终轻量安装器检查通过；组件质量 gate、source/shell/host 全套回归通过。9 个组件的大小/摘要已与清单核对，最终 zip 的 CLI、桥接 jar 与生产 index 内容均与构建输入匹配。

## 保留的失败、未知与边界

本地 Go 原配置为 GOPROXY=direct，初次无法获取五个上游旧提交；公共模块缓存仍保留固定版本，使用默认 https://proxy.golang.org,direct 与 go.sum 重建通过，未改依赖版本。主机 shell 测试初次经 mise 的 Python shim 以 decoy argv0 启动失败；后续用真实系统解释器所在 PATH 复跑，不修改进程所有权逻辑。

最后统一字体后，布局/导航/分流相关浏览器复查 244 passed、2 skipped、0 failed。重新打包后只有 webui 组件摘要变化，其余 8 个组件及全部非 WebUI payload 与此前功能验收的内容一致；最终安装器身份/CRC/ELF/别名检查通过。远程发布/下载状态另行记录。

本轮 ADB 检查没有已连接设备，未把 Android 构建当成实际安装。应用名称 Java bridge 仅完成编译与打包，真实设备标签读取、WebView 触屏、多厂商 Play/GMS、热点 IPv4/IPv6、Tailnet 数据连通性和长期网络 soak 都没有当前版本的设备证据。所有 M01–M29 的完整设备业务验收不能写成已通过。

仍保留 mixed TUN stack；真实内核检查发出 stack 将在将来版本移除的 deprecation 告警。依 M29，没有受控设备 A/B 结果前不擅自切换默认。

## 迁移阶段历史记录

以下记录描述配方迁移当时的状态；其中“未重建/未发布”不代表随后 v1.8.0 开发的当前状态。

# 迁移交付检查

本轮交付为软件配方与仓库布局迁移，没有独立重建或发布新的 Android 实现。

## 已执行

- 原源码固定在 96993ea5c851b8d51cc562c3ca0766a2ca571210；原工作区干净后才迁移。历史提交、6个 stash、其他 worktree 均保留。
- 读取 Recipkg 仓库当前更新的英文迁移技能及旧安装版的差异；按用户更正保留 MagicNet 原项目名，删除误建的本地平行项目，没有新建远程。
- 本地原实现转移至 ignored generated/android-reference/；六个原源码子模块 revision 与干净状态逐个核对，私密 .env 仍留根目录且未追踪。
- 八个完整本地配方，递归图闭合；software-quality 来自固定有效配方。
- recipkg check recipes/magicnet 通过。
- recipkg pack 生成校验归档；recipkg check <archive> 通过。
- 遍历归档：48个普通 UTF-8 .md 文件（含 LOCK），无文件系统链接、NUL、源码/二进制/安装钩子/私密文件路径。八个包名均存在且无重复。
- recipkg build <archive> --lang zh-CN 成功，检查每份非 LOCK Markdown 原文完整出现在提示词，没有只放摘要或依赖链接。
- git diff --check 通过；本轮检查在本地执行。代码 PR 合并会触发仓库已有自动工作流；未手动调度或等待远程 CI。
- 本轮 Test Feedback 只读走查受设备版本断层与断连限制；19 条打开 Issue 的产品反馈已转录为 M18–M29 并纳入 FEEDBACK.md、所属子配方和性能基线来源说明。关闭 Issue 仅表示需求转入配方；不代表旧实现或新实现已通过。
- 原实现 release CLI 的3种空模块读接口各预热1次、报告7次；生产 WebUI 窄屏/桌面各7次；认证 MCP initialize/tools/list 成功，共84个完整工具 Schema，未认证请求被拒绝。具体方法/限制见 PERFORMANCE/PROVENANCE。
- 代码 PR #420–#423 的组合源码通过 Rust 808 项（1 项显式忽略）、fmt、严格 Clippy、前端 check、18 项代理组浏览器用例、安装迁移及模式安全脚本；环境缺子模块的初次失败和补齐后结果见 PROVENANCE。主机检查不替代新实现或真机验收。

## 保留的失败与限制

- 真机安装 metadata 为旧版，CLI 的机器接口调用失败，未当成当前源码或网络成功；未更改设备配置、安装、抓包、重启或测速。
- 生产浏览器预览已有 CSP frame-ancestors meta 告警仍存在，不以零 JS 异常掩盖它。
- 本地 RSS 的初次 wait4 高水位受继承污染，排除；改用验证 exe 后的存活采样，并注明不是精确全进程峰值。
- 无真实网络吞吐/核心启动/设备WebView/多厂商基线；性能预算未知。
- 旧实现留在历史/临时参考，不代表已经按配方独立重建；全部重建业务验收仍未运行。

## 版本与发布边界

2026-10-28 已先将代码 PR #420–#423 和 README PR #416 合并到远程 main；源码集成固定点为 ae4de1ce4d77f1a2a4c8d9656da8101c472fa3a0。用户已解除合并限制并授权直接合并；PR #424 承载最终配方结构与反馈，完整包含 #425 的共享技能提交。来源代码保留在上述 Git 历史和已更新的本地忽略参考中，重建要求保留新增行为。18 个产品 Issue 已按需求转入配方关闭；仓库治理 Issue #281 保持打开，不属于产品验收。未发布新 Android 版本。
最终迁移 PR #424 已合并为 084a189be2a07575441c7a627dbef5eff18cf98f；GitHub 将已被完整包含的 #425 也标记为 merged，打开 PR 数为 0。核对本批 7 个 PR 分支 tip 都是 main 祖先后，已删除这些远程分支及对应存在的本地已合并分支。本地 main 已快进到远程合并结果，其他工作区和未纳入本批的分支不受影响。
11 个共享 Recipkg 技能以各自上游仓库的固定提交接入为子模块；MagicNet 原有 Android、kamfw、设备调试和 Perfetto 项目技能仍保留在 `.agents/skills/`。技能代码不属于运行时依赖或配方归档。
根 update.json 与公开品牌/校验文件保留；配方迁移没有发布可安装的新实现。旧构建/发行代码留在本地忽略的观察参考目录和 Git 历史中；正式生成新实现前，仍须确定对应的构建、签名与发行入口。
GitHub 配方仓库继续使用原 MagicNet 仓库并带有 `recipkg` topic；该 topic 只用于发现，不代表配方有效或软件已重建。

## 2026-10-29 订阅源码修复（未发行）

源码提交 `ed01282e8ee4bcfc27ce5f95f37723c34aebf745` 已推送至 `LIghtJUNction/magicnet-android` 的 `main`，远端回读一致。源码 `cargo check --offline -p magicnet-cli` 通过（34 个 crate）；六个修改过的 shell 文件 `sh -n` 与 ShellCheck 通过；修改的 Rust 文件 `rustfmt --check` 通过；订阅预览 TypeScript 语法检查与本次 jq filter 语法检查通过；源码 `git diff --check` 通过。未运行测试套件、完整 Android/WebUI 构建或真实转换器。

配方与源码 pin 同步后，`recipkg check recipes/magicnet`、临时归档 `recipkg pack`、归档 `recipkg check` 和 `recipkg build --lang zh-CN` 均通过。归档有 8 个包、53 个 Markdown 文件，没有 `.env`、Git 元数据、源码或生成目录；build prompt 包含新固定提交及批次合同。临时归档和提示词在检查后清理。

未进行 Android 打包、签名、发布、安装、设备写入或真实多源网络验收。#426 仍只有单源成功附件，现场根因未确定；`subscription_batch_v1`、逐来源真实转换完整性、跨 tag 的来源归属、浏览器/真机验收仍未完成。源码 push 与本地/远端配方 gitlink push 分别记录，不把源码 `main` 更新称为产品发布。

## 2026-10-30 前端留白与边框调整

源码 `b113f5128549172da6cb1f6e62f0b42d31adb956` 已同步到 `LIghtJUNction/magicnet-android` 的 `main`。该提交基于同时到达的服务生命周期修复 `72b6e8fca99b2bff54e7f59cb4b2b5a28dd111ae`，保留其全部改动；整合后重新运行前端检查，结果如下。

本轮沿用矿白、石墨与玉绿配色，统一页面边距、分区间距和字体层级，移除普通卡片、统计项及桌面侧栏的重复外框。表单、错误提示与键盘焦点保留必要边界；设计要求已同步到 WebUI 配方及实现仓库的 DESIGN.md。

### 已完成的检查

| 检查范围 | 实际结果 |
| --- | --- |
| 前端 `npm run check` | 338 项测试全部通过 |
| 类型与生产构建 | `vue-tsc` 检查及 Vite 生产构建成功 |
| 中文浅色，14 个页面 | 320px 与 1280px 宽度下，可见元素均未造成页面横向溢出 |
| 俄文深色，概览与订阅 | 320、360、390、430、640、844（横屏）、900、1180、1280px 九种宽度下，均未出现页面横向溢出 |
| 英文深色，订阅 | 320px 与 1280px 宽度下均未出现页面横向溢出 |
| 快捷导航与焦点恢复 | 英文搜索 Terminal 后按 Enter 成功跳转；中文概览按 Escape 关闭快捷导航后，焦点回到 `.mn-palette-trigger`（aria-label 为“快速跳转”）；系统工具菜单按 Escape 关闭后也恢复触发按钮焦点 |
| 订阅编辑连续性 | 两行临时草稿在主题、语言及路由切换后保留 |
| 浅色辅助文字 | `#5B6F6D` 在四种浅色背景上的最低对比度为 4.61:1 |
| 配方归档与完整提示词 | 使用 CI 固定的 Recipkg CLI 0.1.1，运行 `python3 scripts/check-recipes.py`，目录 check、pack、归档 check 及中文 build 提示词均通过；递归包含 8 个包、55 个 UTF-8 Markdown 文件，所有非 LOCK 正文完整进入提示词 |

桌面刷新后，预览应用来源 `terminal.local` 未出现 error 级日志。检查完成后已清空临时订阅草稿。

以上界面结果来自浏览器预览。本轮未执行 Android 真机安装、WebView 触屏或真实网络链路测试。
