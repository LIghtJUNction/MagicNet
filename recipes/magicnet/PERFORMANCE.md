# 性能与观察基线

## 2026-11-06：跨层重写的宿主 A/B

对照原版 `magicnet-android@aefcbfb` 与生产实现 `d58dbdc`，框架由 `bb0dc758` 更新至 `ea8758bf`。以下为相同输入的中位数，所有输入均为合成夹具；测量对象、样本和保留统计见[重写报告](https://github.com/LIghtJUNction/magicnet-android/blob/f7188cc1f1184e5b5ac8da2d24b2dabeb42503ea/docs/rewrite-verification-2026-11-06.md)及随附 JSON，不引用历史设备测量作为本轮结果。

| 工作负载 | 原版 | 候选 | 资源与取舍 |
| --- | ---: | ---: | --- |
| CLI 设置 5,000 个应用 | 274.576 ms | 179.752 ms | 耗时约减 34.5%；RSS 3,880 → 3,216 KiB |
| 原生 HTTP 模块读取 8 MiB 回环响应 | 16.794 ms | 12.733 ms | RSS 17,436 → 9,244 KiB，约减 47.0%；仅实际模块路径 |
| WebUI 6,000 行 / 4,800 唯一连接解析 | 29.633 ms | 11.982 ms | 耗时约减 59.6%；Node RSS 差值不作内存改善结论 |
| sh 生成 128 selector 标签，连续 5 次 | 852.842 ms | 14.549 ms | 批处理减少逐项子进程 |
| sh 生成 128 域名规则，连续 5 次 | 1,043.333 ms | 36.316 ms | RSS 1,536 → 2,176 KiB，增加 640 KiB |
| 48 MiB 源包拆分 | 290.363 ms | 308.171 ms | RSS 79,288 → 16,736 KiB，约减 78.9%；耗时增约 17.8 ms |

CLI 交替运行 25 对，打包交替运行 3 组；kamfw 预热后按原版→候选成对运行 5 组。WebUI 预热 3 次，然后分别取原版与候选各 11 次；Shell 先取原版 3 组，再取候选 3 组，每组生成 5 次。CLI/WebUI JSON 只保留汇总统计；Shell/kamfw/打包另保存逐次样本。RSS 为独立进程或命令树中单进程峰值，不是所有并发进程总和。CLI/Shell 的原生 wait4 驱动排除 Python 高水位继承污染。

kamfw 的 39 个运行时文件从 6,614 行 / 202,859 字节降至 3,349 行 / 123,852 字节，分别减少 49.4% / 38.9%，排除测试；不能换算为同比内存改善。CLI 宿主 release 二进制缩小 16 KiB。普通查询变化约零点几毫秒，未宣称普遍提速；Android 核心 RSS、吞吐、续航与长时稳定性仍未测量。

## 2026-11-06：联网与诊断新增控制侧成本

最终源码aefcbfbab80fe14008e4467eb0292251f7ce8f89，Linux6.18.57/x86_64，release CLI SHA256为1a25a998ef7c1a078597172a8a960350672c8a37369bfb40d0c6fdde64e00e8b。在隔离合成模块中测正常缓存/未来截止时间，不把网络替身当成实际代理性能。

| 项目 | 样本 | 中位耗时 | P95 | 峰值RSS中位 |
| --- | ---: | ---: | ---: | ---: |
| 状态查询 | 20 | 2.3055ms | 2.9307ms | 2224KiB |
| 未到期tick | 20 | 1.2938ms | 1.6770ms | 1918KiB |
| 完整导出 | 1 | 152.3926ms（单次） | 不计算 | 不计算；单次最大51076KiB |

导出18188字节，包含真实核心version/check成本；20次节流tick后状态字节不变。测量由原生小驱动fork/exec+wait4，排除Python驱动继承峰值；RSS是包含已等待后代的最大单进程值，不是并发总RSS或常驻。固定kamfw shell+sleep空闲15秒的PSS中位483KiB、同期RSS1832KiB，只代表该监督夹具且原始SHA单独记录。

完整生产标签核心d850ff0编译、版本/来源/tags与config check通过；真实run被netlink socket权限阻断，所以核心空闲内存、吞吐、公网和Android预算仍未知。不能将小型控制侧开销称为全模块“内存/性能最优”。[报告与复现](../../docs/connectivity-diagnostics-2026-11-06.md)、[原始指标](../../docs/evidence/connectivity-diagnostics-host-2026-11-06.json)保留样本、单位、哈希和未覆盖范围。无需新增运行依赖或放宽生产内核功能来取得数字。

本文件保留各次测量的具体对象和时间口径。以下继续保留 2026-10-30 的 sing-tun 连接表生命周期 A/B、日志路径局部 A/B 和历史基线。各条记录绑定自身源码、输入与环境；Android 代理吞吐、冷启动和整模块内存预算单独测量。

## 2026-10-30：sing-tun 连接表生命周期 A/B

本次优化让已经结束用途的流记录及时退出表，减少等待超时期间仍被引用的对象。测试比较固定的 `sing-tun@v0.9.7-0.20261002083955-3f8acd9da65b` 与 `sing-tun@v0.9.7-0.20261028024126-5b0a1a7a394e`，使用同一测试源码、Go `1.26.10 linux/amd64`、默认 build tags、`GOMAXPROCS=1`、`GOTOOLCHAIN=local`、`GOWORK=off`、`-p=1 -mod=readonly`，每个版本执行三次。两版 go.mod 逐字相同，SHA-256 为 `0dde4758a9da6cfd3e570c73d62390d49dbe24b7bed4c8960c98150916d3a2c6`。

### SYN 接受判定表

先用生产 `installAccept` 安装相同数量的 SYN 接受判定，再将同一组 IPv4/TCP ACK 报文送入生产 `Dispatch`。统计 ACK 后表项，以及 `runtime.GC()` 后相对空 stage 基线的 `HeapAlloc` 增量；保留 stage 存活，避免测到整个测试对象被回收的假改善。

| 流数量 | 旧版 ACK 后表项 | 新版 ACK 后表项 | 旧版 GC 后堆增量中位数 | 新版 GC 后堆增量中位数 |
| --- | ---: | ---: | ---: | ---: |
| 1,000 | 1,000 | 0 | 290,448 B | 178,432 B |
| 10,000 | 10,000 | 0 | 2,561,072 B | 1,441,072 B |

10,000 条时三次读数完全一致，减少 1,120,000 B，约 1.07 MiB。1,000 条的旧版三次为 291,648、290,448、290,432 B，新版为 179,648、178,432、178,432 B。删除表项后 Go map 仍保留容量，因此新版表项归零时堆增量仍为正。

该测试直接覆盖接受判定的安装与 ACK 处理，未纳入前面的策略求值或真实网络 I/O；表中的堆数是这条路径的存活堆增量，不能换算成整核心或 Android RSS 的下降比例。

### FIN/RST 后的 NAT 会话

使用真实 `NewNat`、`Lookup`、`LookupBack` 和后台清扫循环。两版都设置相同的已建立连接超时（2 小时 4 分钟）；`testing/synctest` 只提供虚拟时间，不手动删表或调用清扫函数。新版 API 接收 TCP flags，旧版 API 不接收，测试适配仅处理这一签名差异。

| 10,000 个会话，推进 31 秒虚拟时间 | 旧版地址索引 / 会话索引 | 新版地址索引 / 会话索引 |
| --- | ---: | ---: |
| 双向 FIN | 10,000 / 10,000 | 0 / 0 |
| RST | 10,000 / 10,000 | 0 / 0 |
| 无关闭标志，控制组 | 10,000 / 10,000 | 10,000 / 10,000 |
| 只有单侧 FIN，控制组 | 10,000 / 10,000 | 10,000 / 10,000 |

1,000 与 10,000 两种规模均重复三次，结果一致。新版的 10 秒关闭等待期与 30 秒清扫周期回收已结束会话，同时保留活动及半关闭会话。31 秒是虚拟时钟推进量，不是测试的实际墙钟耗时。

### 复现与范围

本轮共同测试为 `lifecycle_ab_test.go.txt`，复跑入口为 `run_lifecycle_ab.py`：它复制两个固定模块后注入共同测试，不修改模块缓存；逐条核对三次、两种规模、五个场景的 60 条观测。原始结果 JSON 的 SHA-256 为 `d302960d97ee5a185755b6e12c95130d73fbd2a5bb3146ffdf52d95d7c0c9b81`。复现源码、原始 JSON/日志与命令已固定在 [sing-box@ff669d45e6562a790a49ef066340dbed5df46363 的 validation 目录](https://github.com/LIghtJUNction/sing-box/tree/ff669d45e6562a790a49ef066340dbed5df46363/SPECS/TASKS/051-UPSTREAM_MERGE_235/validation)。该目录的 README 记录完整 runner 的独立复跑，10,000 条场景结果一致；原始记录仍保留本表的三次读数，不用复跑覆盖历史样本。

本轮证据为受控宿主路径测量。整核心 RSS、Android 实机内存、真实 TUN 吞吐、CPU/延迟和电池开销仍待测量；产品 GOMEMLIMIT 分档、默认 stack 与 build tags 保持原合同。

## 2026-10-30：日志尾读的局部 A/B

只取末尾 120 行时，原实现仍为整份 1 MiB 日志建立行索引。新版从尾部找到所需起点，并让有效 UTF-8 直接复用读取缓冲区。CLI 和 MCP 共用读取函数；原字节预算、行数预算、截断首行、坏字符替换和脱敏语义保留。

基线为 `magicnet-android@a5617d6371fe17494fb4b4a6f655a0c8a0f7461e`。复现工具在源码的 `scripts/benchmark-log-tail.rs`，用 `rustc --edition=2021 -O` 编译；测试使用 Linux x86_64、rustc 1.99.1，同一进程内比较旧/新算法，输入已在内存中。每项计时为五批、每批 50 次的每次均值，再取五批中位数。运行前比较 233,280 组 CR/LF、中文、无效 UTF-8、短尾与空尾输入，输出全部一致。

| 约 1 MiB 输入，取 120 行 | 原临时峰值堆 | 新临时峰值堆 | 原耗时 µs/次 | 新耗时 µs/次 |
| --- | ---: | ---: | ---: | ---: |
| 常规约 80 字节日志行 | 2,097,068 B | 1,060,421 B | 1,051 | 69 |
| 密集空行 | 17,825,911 B | 1,050,743 B | 8,399 | 64 |

临时堆统计为 allocator 请求字节相对既有输入夹具的峰值，包含读取、行索引和结果缓冲区；不是进程 RSS。前一轮相同输入得到相同峰值字节，耗时分别为常规行 1,472→52 µs、空行 9,614→66 µs，说明共享机器负载会影响计时。新版常规输入约减少 49% 临时堆，密集空行约减少 94%；这些比例只适用于表中路径和输入。

该基准不包含文件系统访问、路径校验、脱敏、stdout、网络或 daemon 驻留。输出语义另由日志/MCP 回归测试验证；整机常驻内存、CPU、电池、启动耗时和代理吞吐没有本轮 A/B 数据。

复现：从源码根执行 `rustc --edition=2021 -O scripts/benchmark-log-tail.rs -o /tmp/magicnet-log-bench`，再执行 `/tmp/magicnet-log-bench`。工具按函数名核对当前生产 `read_log_snapshot` 与 `tail_lines` 的函数体；这两个函数变更后，会拒绝继续测量未同步的候选算法。

## 2026-10-28：历史基线

以下为原实现基线，文末另附 v1.8.0 的宿主复测；当时没有独立从零重建、受控版本 A/B 比较或确认的性能预算。

## 当前源码的宿主 release CLI

源码：96993ea5c851b8d51cc562c3ca0766a2ca571210。Linux x86_64 7.2.11-arch1-1、24 logical CPU，rustc 1.99.0；非独占桌面，测前 load 2.98/3.27/4.54、约 12/15 GiB RAM 使用、约 22 GiB swap 使用。噪声存在，不能把亚毫秒差异当作优化结论。
构建命令：
~~~sh
CARGO_BUILD_JOBS=2 CARGO_TARGET_DIR=<isolated-cache>/target cargo build --release --locked -p magicnet-cli
~~~
使用来源 workspace 的 release 配置（LTO、strip、单 codegen unit、panic abort）。构建一次40.31秒，不是重复性能基线。
每条命令先一次预热，再连续7次。Python perf_counter_ns 包住实际 subprocess.run，包含启动、等待退出和完整 stdout 收集。逐次校验 exit=0、schema=1、ok=true、正确 command 和 data 对象。每次子进程确实运行，没有只计排队/拒绝/未消费惰性对象。
MODDIR 是独立空目录，MAGICNET_API=http://127.0.0.1:9（拒绝连接的 loopback），无真实核心、订阅、规则或设备；结果是“空模块的状态查询”，不是已联网服务。命令读取期间建立了两个空 .config 目录，没有写入普通配置/状态文件。

| 命令 | 成功/样本 | median ms | range ms | 逐次 ms |
| --- | --- | --- | --- | --- |
| --json capabilities | 7/7 | 0.914 | 0.837–1.049 | 1.049, 1.024, 0.983, 0.837, 0.866, 0.914, 0.909 |
| --json service status | 7/7 | 24.083 | 13.561–29.866 | 24.083, 23.128, 13.561, 22.876, 26.11, 29.866, 27.939 |
| --json sub status | 7/7 | 0.876 | 0.823–0.958 | 0.958, 0.876, 0.843, 0.835, 0.823, 0.901, 0.927 |

可执行文件 2219160 bytes，SHA-256 90c575cb55e0e2b388c50cbc549d78ff46cc18d5a8c3173323e53e82aea711ad。

service status 另外7次采样 /proc/<pid>/status，并先验证 /proc/<pid>/exe 为目标 release CLI；每次约64–73次观察，最大观察 RSS 为 3620, 3688, 3992, 3512, 3676, 3828, 3500 KiB，median 3676 KiB。这是存活期间的采样最大值，可能漏掉退出前峰值；不包含所有子进程、sing-box 或整模块内存。

最初 wait4 ru_maxrss 对全部命令给出同一个接近 Python 父进程的高水位，疑受 fork 前继承污染，已经排除，不能作为 CLI RSS 发布。
另一次 strace -c 的 profile 不计入上述时间；service status 的系统调用时间主要在 helper wait4（该 profile 94.42%），支持“观测 helper/等待是重要开销”的推断，不证明所有真实设备都受此瓶颈限制。capabilities/sub status 的启动和 JSON 开销没有单独 profiling，不能承诺具体优化空间。

## 生产 WebUI 预览

构建：Node v26.12.1、Vite 8.3.5，从同一源码运行 npm run build -- --outDir <isolated-cache>/web-dist。一次构建1.67秒，不算重复预算。通过 Python http.server 仅监听127.0.0.1，实际浏览器载入生产资产；无网络/CPU 限速，OS/浏览器进程已热，每次使用新的浏览器 context、zh-CN、reduced-motion、跳过已知引导。
浏览器版本：156.0.8078.47。每个尺寸一次预热、7个报告样本。goto 等 load，再等待 .mn-control 真实 visible，读取 performance.now。此“观察到概览可见”时间包括自动化等待/通信开销，不等于纯 FCP/LCP。
preview 没有 native bridge，也不执行真实设备命令；无真实节点/应用数据。只说明前端壳和概览在该夹具上加载。

| 尺寸 | 样本 | median 可见 ms | range ms | JS异常 / HTTP失败 / 主布局溢出 |
| --- | --- | --- | --- | --- |
| phone-390 | 7 | 228.1 | 179.9–257.4 | 0 / 0 / 0 |
| desktop | 7 | 196.1 | 166.5–209.2 | 0 / 0 / 0 |

逐次观察 ms：
- phone-390：229.8, 223.8, 228.1, 256.3, 257.4, 192.7, 179.9。
- desktop：167.8, 208.3, 196.1, 166.5, 209.2, 193.2, 202。

完整构建目录 66 个普通文件、1451376 bytes；按每文件 gzip 累加 628566 bytes。是整个分块构建和资产大小，不是首次传输量；本地 server 无 gzip，资源计数不能当公网下载性能。

14个报告样本每个都收到一条已存在的 CSP console error：frame-ancestors 通过 meta 提供时被浏览器忽略。没有把它计成 JS 异常或 HTTP 失败，也没有隐去告警；本次迁移没有修复该产品问题。
未报告 p95：只有7个样本，不制造稳定尾延迟结论。新设计的速度、全页交互和 native bridge 操作仍未验证。

## 真机观察的版本断层

设备为 LG LM-G820、Android14/API34、arm64-v8a、8 CPU、内核4.14.348-openela-perf+，root 可用；不是性能独占环境。安装 module.prop 报 v1.1.21，不能等同当前源码 v1.7.2。安装 CLI SHA-256 edb9851d8ad7f09c5a63245de07f489b7d2c2d1db346ff0397a561792021a6ee；安装 sing-box SHA-256 697e9229129c23d8730a17173b8cd0c1a65737055c15984ed96279a095aa2a11。
通过 cli 兼容入口与 bin/magicnet-cli 直接调用 --json capabilities 均非零且无可用 schema-1。未发布原 stderr 或设备序列号。失败原因未排查，不从失败耗时推导性能。
没有安装、替换、切换数据面、重启、测速或修改该设备配置；未读取本地 .env。真实 core 启动、订阅转换、吞吐、CPU/电池、sing-box RSS 和设备 WebView 延迟均未验证。

## 复测方法与未知预算

## 用户报告中的待复测性能问题

以下是 Issue 中的来源报告，不是本轮测量，也不应与上面的宿主基线合并：[#396](https://github.com/LIghtJUNction/MagicNet/issues/396) 报告 v1.6.2 冷启动约 35–37 秒、约 2473 个 `sched_process_exec` 事件（其中约 400 个观察器 PID 命令）；同 Issue 的 v1.7.2 样本约 42.481、46.565、47.229 秒，但带本地修改且约 30 秒未归因，不能作版本对比。 [#398](https://github.com/LIghtJUNction/MagicNet/issues/398) 报告修改过的 v1.6.2 在 25 秒空闲窗口有 251 次 cksum 和 204 次 sed；环境不同，需按固定 workload 重测。 [#377](https://github.com/LIghtJUNction/MagicNet/issues/377) 明确公网稳定性 soak 尚未完成。重建验收见主配方 M26；目前没有确认的性能预算。

先记录版本、artifact hash、uname、CPU、uptime、RAM/swap、编译 flags。准备相同空模块夹具；按上面命令每条预热1次、成功运行7次，用单调时钟计完整 subprocess 调用，解析每次 stdout。RSS 单独运行并确认 exe 后采样，不混入时间样本。
WebUI 在相同生产构建/浏览器/尺寸下新建context并重复，按上文 visible 条件和计时口径记录每个样本、错误、告警和 native bridge 状态，不能以首页 DOM 或 await 前的时刻代替真正可见。
未来需对合法合成订阅规模、真实 App 请求、UI 带设备数据、冷启动与恢复、热点流量另建 workload；启动/操作/吞吐/全模块RSS/包体预算仍未知。只可提出待确认候选预算，不许把本表直接改成保证或放宽安全以取悦测速。

## v1.8.0 开发后的宿主复测

使用上文同样的空模块、拒绝连接的 loopback API、完整 subprocess 计时与 envelope 校验，每条预热 1 次并报告 7 次。release CLI 使用相同 Rust 优化配置。宿主仍有并行构建/浏览器工作，不能与原记录作受控 A/B 比较；不测 Android 网络，不宣称提速或稳定尾延迟。

| 命令 | median ms | range ms | 逐次 ms |
| --- | --- | --- | --- |
| --json capabilities | 2.675 | 2.026–5.251 | 2.9, 2.65, 2.214, 2.026, 2.675, 3.421, 5.251 |
| --json service status | 65.889 | 54.034–73.355 | 72.063, 65.889, 66.414, 60.169, 61.293, 73.355, 54.034 |
| --json sub status | 2.774 | 2.119–6.142 | 2.119, 2.749, 6.142, 2.487, 2.774, 5.796, 2.824 |

可执行文件 2272280 bytes，SHA-256 `4192ef4ec3dcce006f0cb113f3c6bd9d0cab69fc5bfb9f931a4907079730d24f`。负载观察为 18.74/21.08/15.79。本轮未重复 RSS 测量；旧 RSS 不能挪作新版本结果。
