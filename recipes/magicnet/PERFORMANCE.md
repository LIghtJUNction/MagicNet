# 原实现性能与观察基线

日期：2026-10-28。只测原实现，未独立重建、未比较新实现，也未确认任何性能预算。以下数值不能充当 Android 代理吞吐、冷启动或真实业务验收。

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

先记录版本、artifact hash、uname、CPU、uptime、RAM/swap、编译 flags。准备相同空模块夹具；按上面命令每条预热1次、成功运行7次，用单调时钟计完整 subprocess 调用，解析每次 stdout。RSS 单独运行并确认 exe 后采样，不混入时间样本。
WebUI 在相同生产构建/浏览器/尺寸下新建context并重复，按上文 visible 条件和计时口径记录每个样本、错误、告警和 native bridge 状态，不能以首页 DOM 或 await 前的时刻代替真正可见。
未来需对合法合成订阅规模、真实 App 请求、UI 带设备数据、冷启动与恢复、热点流量另建 workload；启动/操作/吞吐/全模块RSS/包体预算仍未知。只可提出待确认候选预算，不许把本表直接改成保证或放宽安全以取悦测速。
