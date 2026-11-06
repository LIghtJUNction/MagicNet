# MagicNet 联网恢复、诊断导出与打包验收

日期：2026-11-06（UTC）。最终实现：[magicnet-android@aefcbfb](https://github.com/LIghtJUNction/magicnet-android/commit/aefcbfbab80fe14008e4467eb0292251f7ce8f89)，tree `772988407d975d6116614a6e8b4c2a8c0b4e76f2`。软件元数据仍为 v1.8.5 / 10613；这是源码功能更新与宿主模拟验收，没有新建正式 Android 发行版。

本轮实现了三项需求：所有最终安装归档排除测试/开发目录；服务启动后低频检查 Google 并按证据自愈；一键生成单个完整脱敏诊断文件。真实 release CLI 的状态读取、节流检查和导出已测量，完整生产标签的 sing-box 已构建并通过配置检查。宿主禁止创建 netlink socket，因此真实代理转发、Google 成功访问和 Android 运行内存没有取得证据。

## 1. 最终模块不携带测试目录

源码测试继续保留，供开发和 CI 使用。打包清理覆盖配置子模块、框架依赖和所有嵌套目录，排除 `test/tests/__tests__`、fixture、快照、benchmark、coverage、htmlcov 与 node_modules。规则按目录段判断，`bin/test`、`rules/test.srs`、`test-support.sh` 等运行文件保留。

清理发生在组件拆分、manifest 与摘要生成之前；组件打包器和发布验证器再次检查最终归档。未清理的核心包、完整包或组件会明确失败，不能仅凭正确 SHA256 放行。

本机用合成载荷实际运行 KAM 清理与组件拆分，生成 **9 个 ZIP、88 个成员**：核心、完整、两个别名和五个组件。逐包检查 CRC、目录边界、组件清单和保留文件字节，通过。该结果证明打包转换和内容门禁；载荷不是可安装的 Android 生产二进制，不将它写成手机安装成功。

## 2. Google 检查与恢复

主目标为 `https://www.google.com/generate_204`，经当前 sing-box 的本机 mixed 入口访问。TLS 验证通过且 HTTP 204 才表示 Google 在线；核心 PID、配置 check 或本地 API 可用不代替这个结果。

正常检查间隔 **300 秒**；失败后为 **60、120、240、480、960、1800 秒**，之后封顶 30 分钟。预算使用包含休眠的单调时钟并原子保存，重启监控进程或调整系统时间不会清空同次开机的退避。既有 watchdog 每60秒启动短命令，到期才访问网络；没有额外常驻 Rust 服务。状态读取、页面刷新、health 和诊断导出不新增公网探测。

| 观察 | 处理 |
| --- | --- |
| Google 成功 | 记录在线和延迟，恢复300秒周期 |
| Google 失败、独立代理目标成功 | 显示⚠️目标特定失败，继续退避，不无依据重启 |
| 两个代理目标失败、直连成功 | 连续失败及冷却条件满足后，逐级尝试自有路由/DNS修复、事务性订阅更新、当前核心重启 |
| 全部失败、确认缺默认路由 | 显示出口/上游问题，继续有界探测，不持续刷新订阅或重启 |
| 服务停止、模块禁用、进程归属未知 | 暂停，不自动复活核心 |

独立代理目标为 `https://cp.cloudflare.com/generate_204`；仅两项代理探测都失败后，才用 `https://www.baidu.com/` 作直连对照。正常周期一个请求，故障周期最多三个。请求使用 HEAD、不开内部重试、不跟随重定向，连接最多4秒、请求最多8秒、父预算9秒、输出最多1KiB。

恢复动作至少间隔 **300秒**；自动订阅更新另有 **3600秒**冷却和300秒动作预算。订阅沿用现有候选校验、整批事务与失败恢复。动作返回成功仅表示修复已执行，必须下一次 Google 检查成功才清除联网警告。用户模式、节点选择、应用策略和停止意图保留。

### 停止操作优先

交叉审查发现，若自动订阅刷新持有生命周期锁，原停止操作可能在10秒后报 busy。本轮已修正：显式停止/重启先停止 producer，只取消经完整 argv 和进程身份确认的本模块维护 worker。子任务最多获得15秒处理原有 TERM/回滚；回滚和子组清理完成前不释放生命周期锁。此取消场景最多等锁20秒；失败仍明确报错。取消后不恢复监控、不重放选择、不再启动核心。

真实 CLI 并发夹具验证了慢刷新取消、回滚顺序、锁持续持有、无关 PID 保留和最终停止；另一个夹具验证订阅激活停止自己的父 watchdog 后，恢复 worker能完成回执且只恢复一个循环，没有锁FD继承。

## 3. 一个诊断文件

在 WebUI 诊断页点击 **一键导出诊断包**。Android 输出固定为：

```text
/sdcard/Download/MagicNet/MagicNet-diagnostics.txt
```

也可运行：

```sh
su -c '/data/adb/modules/MagicNet/cli support export'
su -c '/data/adb/modules/MagicNet/cli --json support export'
```

`support bundle` 输出同一完整脱敏文本，保留终端/MCP 使用。文件包含模块/CLI/核心版本、系统与核心资源、启动/事务/监督状态、Google探测与恢复历史、路由规则及顺序、DNS、配置结构和稳定匿名引用、核心version/check、IPv4/IPv6路由与策略规则、自有防火墙、TUN/eBPF与本地API、订阅/缓存/转换/回滚证据及相关日志。

采集不会主动修复、更新订阅、重启、抓取用户流量或发新公网请求。缺少工具、权限不足、坏配置、命令失败/超时和截断都在相应节明确标记；没有取得的证据不能推断成正常。

凭据、订阅URL、节点名、SSID/BSSID、原始UID、设备标识及流量目标遮蔽；配置顺序、计数和匿名引用关系保留。外部命令共用25秒预算，每流32KiB、每节48KiB、全文件512KiB；配置读取4MiB，最多六个日志尾部，每个32KiB/120行。

报告先写同目录独占临时文件并同步，再原子替换固定文件。失败保留旧完整报告；并发导出按最后成功完成者生效，不留下半文件。支持Unix权限的文件系统使用0600，Android共享存储按系统规则控制访问。界面先协商能力，只有成功退出并校验完整JSON后才显示路径；快速双击去重，失败清除旧成功提示，底层私密错误不进入共享输出。

单个快照能集中大部分相关证据，仍不能保证还原没有记录的历史瞬间或替代真实应用流量测试。

## 4. 本机测量

环境：Linux 6.18.57、x86_64、9个逻辑CPU；Rust 1.87 release CLI；Go1.26.7构建完整生产标签核心。CLI在隔离合成模块中运行，探测截止时间设在未来以测量常见的只读/未到期路径。计时包含原生fork/exec至退出，排除Python驱动。没有把模拟核心/网络响应当作真实代理性能。

| 项目 | 样本 | 耗时中位 | P95耗时 | 单进程峰值RSS中位 | 最大RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| connectivity status | 20 | 2.3055ms | 2.9307ms | 2224KiB | 2348KiB |
| 未到期 connectivity tick | 20 | 1.2938ms | 1.6770ms | 1918KiB | 1964KiB |
| 完整诊断导出 | 1 | 152.3926ms（单次） | 不计算 | 不计算 | 51076KiB |

20次未到期tick后，探测状态文件字节不变。导出文件为 **18188字节**，与机器接口回报一致，CPU时间144.788ms。峰值RSS采用原生wait4口径：包括已等待后代的最大单进程高水位，不是并发进程树总量或后台常驻内存。导出会运行真实核心version/check，约50MiB的单进程峰值包含这些子进程成本。

另对固定kamfw的真实60秒循环，以空操作回调在首次sleep阶段采样15.0124秒、16次。shell+sleep同期RSS合计1832KiB；按共享比例分摊的PSS中位483KiB，范围478–486KiB。CPU增量0ticks，粒度10ms，只表示该空闲窗口低于计数分辨率。此项不含核心、周期CLI工作或Android管理器；采样绑定同一kamfw `bb0dc758`，当时源码HEAD为`9d545e1`，PID校验使用当时的CLI，不能挪称最终CLI或全模块常驻数据。

数据支持“新增控制侧开销较小”，尚不支持“整机内存与代理吞吐均已最优”的结论。原始数据、测量范围、样本和哈希见 [host evidence](evidence/connectivity-diagnostics-host-2026-11-06.json)。

## 5. 验证结果

| 范围 | 结果 |
| --- | --- |
| Connectivity | 12单元+8真实CLI集成通过；含2小时故障时钟模拟、共8轮探测 |
| 诊断 | 50单元/回归+3真实CLI集成通过；含脱敏、截断、预算、失败发布、完整JSON、只读状态 |
| 机器/状态 | machine dispatcher17、observation_state6通过 |
| 生命周期 | service27通过，1个原有Android专用测试ignored；process_lifecycle5通过 |
| 模块更新回归 | 29通过；保留跨平台libc数值转换语义 |
| Shell | watchdog、supervisor-start-policy、subscription-lifecycle通过；新基线config-lock-ownership和fswatch-lifecycle在bash/sh/mksh/BusyBox通过 |
| Rust静态检查 | fmt以及workspace/all-targets/all-features的严格Clippy通过 |
| WebUI | 346测试、vue-tsc、Vite生产构建通过；包含实际Vue导出函数的能力协商/双击/失败/坏响应夹具 |
| 打包 | 53个unittest方法通过；另外实际9ZIP/88成员清理拆包检查通过 |
| 配方 | 根0.3.12，check/pack/归档check/完整提示词通过，8包58个Markdown，无源码或测试产物进入配方归档 |

### 保留的失败和未覆盖范围

完整生产标签的sing-box `d850ff0ff68e11a71aa8207627e0a826cb52808f` 已构建，版本/pin/tags核对和配置check通过。实际启动时报：

```text
start service: initialize network: create netlink socket: operation not permitted
```

因此回环代理吞吐、核心空闲RSS和Google实网成功均未取得。专门的单次Google测试记录请求数 **0**；最终CLI测量没有另发公网请求。综合测试脚本保留 `local_acceptance=blocked`，同时 `cli.acceptance=passed`，没有吞掉失败退出码。

宿主缺少`/sys/class/net/lo`，使既有`tun_never_reports_ebpf_plane_readiness`主机假设测试失败；没有修改生产就绪逻辑使它假通过。Chromium无法创建所需socket，新增6个Playwright浏览器场景未执行完成；界面函数模拟、类型检查和构建不能替代浏览器/WebView视觉结果。Vite保留现有大于500kB主chunk提示，未将它隐藏。

当前环境缺少Android NDK、cargo-ndk/cross、Android Rust目标、javac/d8、adb/sdkmanager。没有在本轮生成可验证的新Android安装包、安装真机或运行真实应用/TUN/eBPF流量。GitHub插件完成源码提交；本地gh未登录且当前插件无workflow dispatch入口，没有把既有其他提交的远程CI结果移用到本轮。

## 6. 固定版本与复现

| 对象 | 固定身份 |
| --- | --- |
| 最终源码 | aefcbfbab80fe14008e4467eb0292251f7ce8f89 |
| CLI二进制SHA256 | 1a25a998ef7c1a078597172a8a960350672c8a37369bfb40d0c6fdde64e00e8b |
| 核心源码 | d850ff0ff68e11a71aa8207627e0a826cb52808f |
| 核心二进制SHA256 | bb4194f38699337ffcda5da788df97d715b10724cec706967811672b6099d407 |
| 模板 | MagicSingBox@6b5f68a261818a4ffda6eb9a11b21eef9b755650 |
| 框架 | kamfw@bb0dc7582ee2c27e31e49d2d3b714b97528defef |

在固定源码和具备相应权限的Linux环境中：

```sh
cargo build --release --locked -p magicnet-cli
bash scripts/build-sing-box.sh linux amd64 /absolute/output/sing-box
python3 scripts/test-host-connectivity-performance.py \
  --core /absolute/output/sing-box \
  --cli "$PWD/target/release/magicnet-cli" \
  --output /absolute/output/host-evidence.json
```

默认不请求公网；只有显式增加`--google-once`才最多请求一次Google，不内部重试。网络/内核权限不足保留阻断，不通过修改生产tags或权限配置掩盖。

本轮增量提交为：[打包排除 e8aad9e](https://github.com/LIghtJUNction/magicnet-android/commit/e8aad9e4b97c2601d029dcfa1f2b56ac90abd106)、[界面 9d545e1](https://github.com/LIghtJUNction/magicnet-android/commit/9d545e100080ef454f7bc7c11fb9c2508b639e4e)、[运行时与诊断 aefcbfb](https://github.com/LIghtJUNction/magicnet-android/commit/aefcbfbab80fe14008e4467eb0292251f7ce8f89)。期间到达的Voice清理、目录/锁/原生TUN、共用launcher和教育分流修改均通过三路合并保留；最终源树干净。
