# MagicNet 联网恢复、诊断导出与模块验收

日期：2026-11-06（UTC）。当前验收候选为 [magicnet-android@ceb7d54](https://github.com/LIghtJUNction/magicnet-android/commit/ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9)，完整提交 `ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9`，tree `794e53afe208f03429748bdea554a71b792b5f3b`。软件元数据仍为 **v1.8.5 / 10613**；本轮没有新建正式Release或部署用户设备。

本轮实现最终模块排除测试目录、连接后的低频Google探测与有条件自愈，以及一键导出单个综合诊断文件。真实Linux核心已取得空闲内存与回环转发数据，新release CLI已重新测量。独立审计先后发现并修复了诊断状态过度脱敏、错误MCP入口和正式包缺少curl；旧d22/b5候选没有交付。当前版本新增正式curl/TLS/内嵌CA组件和无系统curl的Android执行验证。

> 当前状态：ceb7d54只修正Android验收脚本对ADB合法空白行的兼容，四项精确CI已启动。218的质量、网络、Build均通过，但设备验收在端口映射列表解析处失败，旧失败完整保留；当前没有交付安装包。


## 1. 交付归档排除测试目录

源码测试保留，供开发和 CI 使用。安装归档在组件拆分、manifest 和 SHA256 生成前递归清理测试与开发目录，覆盖配置子模块、框架和嵌套依赖。目录段包括 `test/tests/__tests__`、`fixture/fixtures/__fixtures__`、`__snapshots__`、`bench/benches/benchmark/benchmarks`、`coverage/htmlcov/node_modules`。按目录段判断，正常运行文件 `bin/test`、`rules/test.srs`、`test-support.sh` 保留。

组件打包器与独立发布验证器检查最终 ZIP：含禁止目录就失败，摘要正确也不能放行。新增curl后的宿主合成载荷实际清理并拆出 **10个ZIP、100个成员**，已核对 CRC、目录边界、manifest 与保留文件内容；这只证明转换和门禁。真实 Android 包的结果另列如下，合成载荷不代替安装物。

218e165的真实归档已独立审计通过：14个ZIP、1104个成员、10个组件及168个组件文件，17个资产摘要、12条递归依赖pin、9个ARM64 ELF路径（含CLI别名）均核对。测试/开发目录及开发元数据各0匹配；curl六固定路径、文件大小/摘要/权限、内嵌CA、manifest及full/core/components一致。该轮完整包68,475,870字节，SHA256 `d4ed0da02382d8cbac1239d83b7fcd6297aa9d72d856517c98e932200f444b81`；因为Android验收未完成，仍只作历史证据，不交付。ceb7d54最终归档将重新核验。

上一候选b5fa1cd的归档结构审计通过（因缺curl仍不交付）：13个ZIP（9组件、core/full/两个core别名），1092个成员CRC、安全路径及开发目录检查全部通过，测试/开发目录0匹配；16个清单资产摘要和162个组件文件的摘要/大小/权限核对通过。12条递归依赖pin、8个Android AArch64 ELF及4份内嵌manifest一致；ARM64 CLI摘要已确认区别于旧collector。完整离线包 **65,552,655字节（约62.52MiB）**，SHA256 `5ce7eeb60dfcb2dd6e6ac999c00ac35ebc192ac2886c90868a24163f9d47eec1`。此前d22归档审计虽通过，但其诊断内容缺陷另行保留为历史基线，未交付。

## 2. 连接后的 Google 检查

正式模块由`bin-curl`组件提供curl 8.22.0、静态OpenSSL 3.5.8/zlib 1.3.2与固定内嵌CA（121张），同组件携带构建来源和四份许可记录。生产ARM64与模拟器x86_64共用源码锁和API21构建器；安装器逐文件验证摘要/大小/权限。缺失或坏执行器明确显示本地原因，不冒充上游断网，也不据此更新订阅或重启。调用忽略外部curl配置及继承的代理、CA/TLS覆盖。

主目标为 `https://www.google.com/generate_204`，经当前受控 sing-box 的本机 mixed 入口访问。只有 TLS 验证通过并返回 HTTP 204，才记录 Google 在线。核心 PID 存在、配置校验成功或本地 API 可用，各自只证明对应环节。

正常检查间隔 **300 秒**；失败后的间隔为 **60、120、240、480、960、1800 秒**，之后封顶 30 分钟。截止时间使用包含休眠的单调时钟并原子保存，重启监控进程或调整系统时间不会清空同次开机的退避。复用既有 watchdog 的60秒循环，短命 CLI 到期才发请求；没有新增常驻 Rust 服务。页面刷新、状态读取、health 和诊断导出不增加公网探测。

| 探测证据 | 提示和处理 |
| --- | --- |
| Google 返回204 | 显示在线和延迟，恢复300秒周期 |
| Google失败、独立代理目标成功 | 显示⚠️目标特定失败，继续退避，不盲目重启 |
| 两个代理目标失败、直连成功 | 连续失败及冷却条件满足后，逐级尝试自有路由/DNS修复、事务性订阅更新、当前核心重启 |
| 全部目标失败或已确认缺少默认路由 | 明确显示出口/上游或路由问题，继续有界探测 |
| 服务停止、模块禁用、进程归属未知 | 暂停恢复，不自动启动核心 |

独立代理目标为 `https://cp.cloudflare.com/generate_204`；仅在两个代理目标均失败后，才请求 `https://www.baidu.com/` 作直连对照。正常周期一个请求，故障周期最多三个。HEAD请求不内部重试、不跟随重定向；连接最多4秒、单请求最多8秒、父进程预算9秒，输出最多1KiB。辅助目标成功不冒充 Google 成功。

### 自愈条件和停止优先级

至少连续两次失败，并满足代理双失败、直连成功、无已知缺路由问题等证据，才进入恢复。动作至少间隔 **300秒**；自动订阅更新另有 **3600秒**冷却和300秒动作预算。订阅使用已有候选校验、整批事务与失败回滚。动作返回成功只表示已执行，下一次 Google 检查成功后才清除联网警告。用户模式、节点选择、应用策略和停止意图保留。

显式停止/重启会先停止监控，只取消经完整参数与进程身份确认的本模块维护 worker。既有更新任务最多获得15秒完成 TERM/回滚；回滚和子进程组清理结束前，生命周期锁保持占用。此取消场景最多等锁20秒，其余维持原预算，失败明确报错。取消后不恢复监控、不重放选择、不再启动核心。真实 CLI 并发测试验证了慢刷新取消、回滚顺序、锁持有、无关进程保留和最终停止。

## 3. 一键导出一个诊断文件

在 WebUI 诊断页点击 **一键导出诊断包**。Android 固定输出：

```text
/sdcard/Download/MagicNet/MagicNet-diagnostics.txt
```

命令行等价入口：

```sh
su -c '/data/adb/modules/MagicNet/cli support export'
su -c '/data/adb/modules/MagicNet/cli --json support export'
```

`support bundle` 输出相同的完整脱敏文本，适合终端或 MCP 使用。导出内容按关联故障组织：

| 范围 | 报告中的证据 |
| --- | --- |
| 运行环境 | 模块、CLI、核心与系统版本；内存、FD、线程、I/O等可取得的资源信息 |
| 生命周期 | 启动、事务、监督状态、受控进程身份、停止/恢复结果 |
| 联网 | Google主结果、差异探测、时间戳、退避、下次检查和最近恢复动作 |
| 配置与核心 | 配置结构、规则顺序、稳定匿名引用、核心version/check及失败原因 |
| 网络路径 | IPv4/IPv6路由与策略规则、自有防火墙、DNS、TUN/eBPF和本地API |
| 订阅 | 来源状态、缓存、转换、候选激活、事务与回滚证据 |
| 日志 | 最多8个固定日志尾部，包含supervisors和connectivity-watchdog，保留脱离终端后的启动失败 |

新增`[curl executor]`节提供有界版本查询、HTTPS/TLS/gzip能力、ABI/API、CA和公开构建来源摘要，标明构建记录和实际执行观察各自的范围；诊断本身不做网络请求，也不将未执行的二进制哈希校验写成成功。

缺少工具、权限不足、坏配置、命令失败/超时或截断，均在对应节明确标记。采集只观察，不自动修复、更新订阅、重启、抓取用户流量或新发公网请求。各节依次采集，不能当作同一瞬间的全系统原子快照。

凭据、订阅URL、节点名、SSID/BSSID、原始UID、设备标识与流量目标被遮蔽；配置顺序、计数和匿名引用关系保留。外部命令共用25秒预算，每流32KiB、每节48KiB、全文件512KiB；配置读取上限4MiB，每个日志最多32KiB/120行。完整指相关证据范围完整，超大数据会明确截断，不无界复制隐私或耗尽内存。

服务、TUN/eBPF与DNS机器状态按字段脱敏，保留可解析的JSON、规范状态、数值、布尔及null。私密URL只遮蔽对应叶值，不再吞掉整段状态；固定公共Google目标与11个真实透明事务阶段保留。私密动态键、UID和设备/认证子树同样受保护。MCP使用已有纯只读状态命令，未启用如实显示disabled/stopped。坏、截断、超深和超限机器输出以明确省略原因结束，不回退输出原始秘密。

报告先写同目录独占临时文件，同步后原子替换固定文件。失败保留旧完整文件；并发导出以最后成功完成者为准，不发布半文件。支持Unix权限的文件系统使用0600，Android共享存储访问遵循系统规则。WebUI先协商能力，仅在成功退出且完整JSON、路径和大小合法后显示结果；快速双击只导出一次，失败清除旧成功提示。

一个文件能够集中排查大多数路由、核心和订阅问题。未记录的历史瞬间、特定应用UID或OEM网络栈的实际行为，仍可能需要现场补充证据。

## 4. 实际测量：控制侧开销与核心转发

### 最终 release CLI

测量环境为Linux6.18.57、x86_64、9逻辑CPU、Rust1.87 release；二进制SHA256为`6e989c28d8648d05a385a4237a3273aee67d54a0766fc869dc2d1746a1a34fba`，大小2679640字节。测时为b5工作树加已冻结修改，原始dirty状态保留；六个Rust文件已逐字节匹配fa0与2bb提交；f0的权限与UI小修、218的测试夹具补全及ceb的ADB验收兼容均不改变生产Rust，以此绑定当前候选。隔离模块使用真实CLI，设置未来探测截止时间，衡量正常缓存读取及无需探测的路径。原生fork/exec和wait4计时排除Python驱动继承的内存峰值。旧b5和81a样本保留各自身份。

| 项目 | 样本数 | 耗时中位 | P95耗时 | 单进程峰值RSS中位 | 最大RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| connectivity status | 20 | 1.9237ms | 2.1997ms | 2192KiB | 2512KiB |
| 未到期connectivity tick | 20 | 1.0025ms | 1.3087ms | 1792KiB | 2032KiB |
| 完整诊断导出 | 1 | 130.4854ms（单次） | 不计算 | 不计算 | 77700KiB |

20次未到期tick没有改变状态文件字节。导出 **19917字节**，机器回执与文件一致，CPU时间125.203ms。RSS口径是单进程及已等待后代中的最大高水位，不是并发进程树总RSS，也不是常驻内存。导出运行真实核心version/check，约75.9MiB峰值包含这些子进程成本。单次导出样本没有P95，也不用于推导稳定的版本提速比例。

固定kamfw `a7788737` 的真实60秒循环以空操作回调在首次sleep阶段采样20.000037秒、21次。shell与sleep同轮RSS合计 **1820KiB（约1.78MiB）**，PSS **549KiB**；CPU增量0ticks，100Hz粒度。此记录保留实际81a6010源码及`f22c35f5…`身份辅助CLI，随后watchdog/框架生产路径未变；结束后剩余进程0、临时目录已清理。窗口内9CPU宿主平均忙碌1.1471%，没有与CLI性能工作重叠。RSS合计会重复计入共享页，PSS按共享比例分摊；两者均不含核心、周期CLI或Android管理器，不能当作整模块或手机电池开销。

### 真实生产核心的 Linux 测量

核心固定为 `d850ff0ff68e11a71aa8207627e0a826cb52808f`，Go1.26.7、全部23个生产标签。CI核心二进制与本机相同，SHA256为 `bb4194f38699337ffcda5da788df97d715b10724cec706967811672b6099d407`。下列结果来自精确记录的CI提交及运行环境，不是手机实测：

| 测量 | 实际结果 | 范围 |
| --- | --- | --- |
| 54个本地规则集的核心空闲RSS | 两轮各取稳定段中位74174/74852KiB，约72.44/73.10MiB | 218e165的Linux CI；每轮8点、取末4点；无TUN和活动连接 |
| 简单mixed核心空闲 | RSS58536KiB、PSS58528KiB、最多10线程 | 218e165的Linux CI；20.0255秒、21点 |
| 26字节请求的代理/直连中位耗时差 | **0.3168ms** | 30组成对直连/代理、每次新连接；直连0.4757ms、代理0.7925ms |
| 4MiB响应经代理吞吐中位 | **6937.0659Mbit/s，约6.94Gbit/s** | 8组成对完整字节校验的IPv4回环传输；代理耗时中位4.8371ms |

回环测试主机为Linux7.0.0-1017-azure、x86_64、4CPU。成对顺序交替，所有响应验证实际内容；包括预热共77请求，**全部在本机回环，公网请求0**。直连吞吐中位17893.6617Mbit/s，代理/直连比0.3877。此前027e91f、81a6010、d22b122、b5fa1cd与2bbbf2a对同一二进制的结果分别为代理8.2140/5.5847/5.6049/6.5838/8.3628Gbit/s、中位耗时差0.3233/0.4680/0.4690/0.3024/0.3434ms，所有运行保留原始数据；共享CI主机上的独立运行没有受控A/B条件，不将差异归因于本轮源码修复。这是短时用户态转发能力，不是互联网带宽、远端代理速度或Android TUN/eBPF性能。

20秒空闲CPU增量0ticks，计数粒度10ms，只能说低于该窗口分辨率。短突发核心CPU累计0.07秒、墙钟0.1017秒，窗口太短，不能外推持续CPU或电池功耗。64MiB软内存限制试验的RSS仍可高于64MiB；它不是硬RSS上限，本轮不据此更改产品默认值。

现有证据支持新增控制开销较小、固定核心可真实转发。没有受控旧/新版本全路径A/B、真机和持续负载证据，因此不声称所有设备上内存与性能已达到最优。原始数据见[宿主指标](evidence/connectivity-diagnostics-host-2026-11-06.json)与[CI指标和审计](evidence/connectivity-diagnostics-ci-2026-11-06.json)。

## 5. 验证门禁与本轮发现的真实问题

### 当前提交门禁

| 门禁 | 精确运行 | 当前结论 |
| --- | --- | --- |
| Code Quality | [42173653819](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653819) | 运行中 |
| Build Kam Module | [42173653787](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653787) | 运行中；须独立审计最终归档 |
| Android KernelSU Acceptance | [42173653691](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653691) | 运行中；实际TLS/产品tick/原生init/单文件导出 |
| Network Regression Evidence | [42173653682](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653682) | 运行中 |

### 218历史门禁（非交付）

218e165的[Code Quality42171293268](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42171293268)为7/7 jobs通过，122项实际RUN/PASS、3项Rust精确指纹HIT、0 FAIL；Rust追溯fa0完整实跑，不称作新执行。[Build42171293277](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42171293277)全部构建、安装模拟和组件门禁通过。[Network42171293206](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42171293206)3/3 jobs通过，300项浏览器场景以及真实核心转发；核心与192张截图归档核对官方摘要、大小、CRC和安全路径。

[Android42171293287](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42171293287)在cold-boot阶段报告`curl_reverse_unknown`：前3阶段通过、该阶段失败、后8阶段未运行。首次重启的新boot、root、SELinux Enforcing及三个KernelSU原生init阶段均通过，包内x86_64 curl实际摘要匹配。失败后服务快照仍running/ready，核心RSS81252KiB，联网缓存unknown/not_checked、probe_count=0；这是该快照，不外推后台全程请求总数。显式产品tick和诊断导出尚未到达，不把它写成TLS或Google已通过。

官方ADB的`--list`成功输出总会追加换行，旧验收解析器却拒绝空白行。旧代码对这个合法输入可确定复现同一错误；该次设备产物没有保存原始reverse输出，因此这里只认定已证实的兼容缺陷与失败位置一致。ceb7d54仅忽略空白行，保留退出码、大小、2秒预算、非空三列格式、精确端口和重复映射拒绝；Mock同时模拟官方真实末尾换行。27项proof中26通过、1个原有可选CA样本跳过，设备harness100和public contract32全部通过，独立审查无阻断。来源：[AOSP commandline.cpp](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/client/commandline.cpp)，所查blob `5cd3ab66dd0a7ba0173b01f954fbe76c21269483`。

fa0首次真实ARM64/API21 curl编译、静态ELF及来源核验已通过，正式hook安装成功；后续KAM导出归档中的`licenses/curl/build-provenance.json`权限不符合0644，严格打包门禁拒绝。f0d2407已在拆分和摘要生成前规范固定路径权限，最终模式校验保持严格；其真实CI原始ZIP无需手工修改即通过curl校验。随后安装夹具遗漏帮助脚本由218补全，原失败包不交付。

### b5历史门禁（非交付）

| 门禁 | 精确运行 | 当前结论 |
| --- | --- | --- |
| Code Quality | [42162571569](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42162571569) | 通过，7/7 jobs；123个包装检查均RUN/PASS、0 HIT |
| Build Kam Module | [42162571259](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42162571259) | 通过；实际13 ZIP完整独立审计通过 |
| Android KernelSU Acceptance | [42162571341](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42162571341) | attempt1在disable-reboot失败；attempt2在upgrade-preservation失败，已定位重复安装ksud的ETXTBSY；均保留失败 |
| Network regression（81a；联网与转发路径未变） | [42157478272](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42157478272) | 通过 |
| Network Regression Evidence | [42162571269](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42162571269) | attempt2通过；核心/AVD原执行保留，截图单job重试300项通过 |

上一候选b5fa1cd质量流程7/7 jobs成功：Rust fmt/严格Clippy/workspace测试分别实际RUN1.17/4.27/41.77秒，components10项和shell108项均RUN/PASS。WebUI检查18.99秒、完整不筛选浏览器套件632.32秒通过；全部包装检查123 RUN/PASS、0 HIT。浏览器passed/skipped细分因包装器隐藏成功stdout而保留未知，不用收集数替代通过数。Android的88/32前置测试另属设备流程，均在同一最终SHA实际执行。

d22的shell 108/108 host manifest检查全部实际RUN；components10项全部RUN。WebUI检查与完整浏览器套件分别实际RUN12.25/460.03秒；源码收集到786项，但成功子进程输出被缓存驱动隐藏，不能将收集数直接称为passed数。新增3场景×6项目的18个导出组合纳入完整成功运行。Rust fmt/Clippy/test在这轮为精确指纹HIT，前一轮81a实际执行成功。本地分段完成107个host检查，1个因JRE缺少ct.sym、无法执行javac --release8而阻塞；最终CI用完整JDK实际通过该项，没有降低目标版本。

最终源码之外的已有证据各自保留身份：027e91f的[Code Quality 42154178842](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42154178842)完整通过；aefcbfb的WebUI质量job实际运行完整浏览器用例，新增导出3场景×6视口的18种组合已纳入，不把本地Chromium无法启动写成浏览器成功。

初轮本地通过联网12单元+8真实CLI集成、诊断50单元/回归+3真实CLI集成、机器17、观察状态6、service27（另1个原有Android专用ignored）、process5、module_update29；严格fmt/Clippy及WebUI346测试、类型检查和生产构建通过。最终诊断内容补丁通过15项导出单元测试（比原10项新增5项）及3项增强的真实CLI集成测试、严格fmt/Clippy；Android harness88项与acceptance contract32项通过。修改前真实CLI回归确实失败，修改后成功；独立审查用最终release真实报告联调设备解析器，通过当前三个schema及11个事务阶段的完整性检查。这些是不同阶段的子集，不累加成一个虚构的测试总数。

### 从失败中修复，而非跳过门禁

1. **监督进程启动自锁。** 两轮真实模块构建均在启动supervisor时超时。MagicNet外层检查/启动互斥和kamfw内层flock原来使用同一个文件；父进程持锁等子进程，子进程又等待该锁。外层改为`magicnet-config.controller.lock`，框架继续使用独立`lifecycle.lock`，固定顺序为controller→lifecycle。真实kamfw测试覆盖bash/sh/mksh/BusyBox与两种flock后端的8组合、重复启动、四路并发、stop等待、忙锁超时和FD不继承。没有通过延长180秒超时掩盖死锁。
2. **生成配置触发监控反馈。** 上游批量扫描优化曾不再正确排除`sing-box/config.json`等相对路径。整合上游`ea8758bf`生产修复，另提交`a7788737`测试固定GNU/BusyBox find的字面路径语义，保留扫描优化。默认配置生成文件被排除；不同父目录的同名文件仍可观察。
3. **CI夹具遗漏依赖。** 首轮Rust集成缺kamfw/template初始化，另有升级脚本边界断言过时。027e91f修复依赖初始化、缓存身份和夹具边界；该提交质量门禁实际通过。没有删除失败场景。
4. **Android重启命令超时。** aefcbfb首次Android跑过前10/12阶段，enable-reboot时ADB命令30秒超时，之后设备offline，未取得新内核启动证据；该次保持失败。最终harness仅把ADB的124退出当作结果未知，继续独立核对新boot ID、boot_completed、root、SELinux Enforcing和KernelSU原生初始化；初次bootstrap才late-load，不重复发送reboot，其他退出仍失败，没有新启动证据仍失败。

81a的下一轮CI还暴露了旧测试夹具与重写框架的集成差异：KernelSU夹具将完整框架直接交给split，被严格开发目录门禁正确拒绝；package smoke仍匹配旧私有变量名。d22b122让夹具先运行真实sanitizer再split，增加测试目录canary和全部输出归档/运行文件字节断言；包内检查改为真实执行提取的框架，验证后台回调、HUP、导入缓存重置、PID/锁/临时目录清理。旧源码字面断言已由同期f7188cc改为观察真实sleep60子进程，严格ShellCheck保持开启。KernelSU 11项、archive-safety13项、完整shell lint及对81a实包运行的新worker检查均通过；没有放宽生产拒绝规则。

d22真实Android导出为61,115字节、47节，采集阶段227ms，0截断；18个必需节存在。但service.status的紧凑JSON含URL，被按文本token脱敏整段替换为`<redacted-url>`；`--json mcp status`也不是已注册接口，造成唯一incomplete_command。b5fa1cd已用专用有界结构投影保留机器状态字段、真实阶段及数值/布尔/null，按字段隐藏私密值，并使用有效纯只读MCP入口。设备检查增加结构与内容验证，不再只验证标题。d22候选未作为最终包交付。其联网实际快照为unknown/not_checked、HTTP/checked_at=null、probe_count=0，没有Google204证据；历史失败和实际文件审计保留。

b5fa1cd首次Android运行的前9阶段通过，但disable-reboot在330.077秒内未取得新启动，后两阶段未运行，整轮保留failure。日志确认reboot到达guest init并进入shutdown，之后没有新Linux banner；ADB诊断显示设备不存在，没有可归因的panic/Oops/BUG证据，因此不能直接断言由模块、内核或传输哪一层造成。同一提交、同一时限仅用新runner复测一次，不修改脚本判定。该首次运行中的原生诊断已通过：61911字节、47节、采集305ms、incomplete_commands=0、truncated_sections=0；服务/TUN/DNS JSON及MCP内容完整，Google仍unknown/not_checked。

b5fa1cd同SHA的唯一一次复测在upgrade-preservation失败，前8阶段通过。第二次重启已经核对新boot、root和SELinux Enforcing；serial日志证明原生init执行post-fs-data/services/boot-completed均退出0。随后验收脚本再次late-load，固定KernelSU的install直接复制覆盖已有ksud，logcat明确记录“Text file busy (os error 26)”。修正后仅初次bootstrap执行late-load，后续重启只读核验当前boot的三个原生阶段、内核接口、真实su域和BusyBox，不重放生命周期、不延长重启截止时间。新的实际Android验收仍须通过；旧失败不改写。

网络证据workflow首次在浏览器依赖安装阶段卡于APT字体下载，15分钟到期取消，Playwright未启动。只重跑visual job后，同SHA和原预算下300项通过（2.8分钟），整个attempt2成功；核心及AVD storage复用原成功执行，原始测量与首次取消日志保留。

Android harness在cold-boot阶段先核验安装后的正式curl及本地TLS正反控制，再观察产品联网状态：已有有效结果则复用，仅在允许时最多执行一次遵守正常截止时间的tick，pending只等待，不清空退避或强迫到期。后续`installed_controls`使用原生CLI启动supervisor、验证受控fswatch PID、读取联网状态并执行一次`support export`；这一导出核验步骤自身不调用tick、不更新订阅，并检查前后探测计数不变。online必须有204、时间戳和延迟，真实网络失败按实际原因记录。导出检查固定路径、非符号链接、文件大小与回执一致、上限512KiB及18个基础必要节，并另验curl/DNS/MCP等内容语义、隐私、只读和结束标记。实际拉回的设备文件保存为`diagnostic-export.txt`和`installed-controls.json`。

fa0e1ad首次新curl流程在宿主TLS proof前置失败，Android job未启动。版本解析仅接受三段数字，合法的zlib/1.3会被拒绝；用旧代码同输入复现后，2bbbf2a改为2–4段数字，模块实际版本仍与固定lock精确匹配。宿主proof23项通过、原有可选CA样本1项跳过，完整harness100项通过；未跳过TLS控制或冒充Android执行。fa0的完整Rust workspace测试实际通过，后续新提交的生产Rust代码不变。

2bb的质量门禁已7/7通过（122项实际RUN/PASS、3项Rust精确指纹HIT），网络证据300项浏览器场景与真实核心转发通过，但Android仍因同一KAM权限问题在设备启动前失败。下载fa0真实失败包后确认六个curl成员都为regular0755；f0d2407在拆分与摘要生成前，仅将五个数据文件规范为0644，bin/curl保持0755。实包复制品所有payload与CRC不变，14ZIP/1104成员复验通过；原失败包及其来源记录未改，手工修复品不交付。界面同时明确提示本机执行器不可用，三语文本与现有346项WebUI检查/typecheck/build通过。

f0d2407的真实模块构建和完整包安装模拟通过，但组件验收中的KernelSU临时项目没有复制新增的`android-curl-artifact.py`，真正执行7900清理hook时退出2。同一遗漏也使Android job在设备启动前的内部harness阶段失败。218e165只补上这个实际依赖的复制，11项安装生命周期测试全部通过；没有删场景、放宽归档规则或延长超时。最终CI重新从218e165构建，不交付f0原始包或fa0手工规范化复制品。

## 6. 尚未证明的范围

本地沙箱禁止netlink socket，生产核心run明确返回`operation not permitted`。本地综合性能脚本因此保留`local_acceptance=blocked`，同时最终CLI的`cli.acceptance=passed`；真实转发证据来自具备权限的Linux CI。专门Google尝试实际请求0，回环测试没有公网请求，因此本轮尚未取得Google实网成功、用户真实订阅出口成功的证据。

初始基线曾因宿主缺少`/sys/class/net/lo`而使TUN就绪测试失败。同期主线将该测试改为受控接口探针，同时验证存在与缺失分支，生产仍读取真实接口证据；该修正随主线保留。Chromium本地socket权限不足的失败也保留，远程质量门禁及实际浏览器执行另行记录。

Android模拟器能够验证安装、启动、生命周期、机器接口和文件导出，不能替代物理ARM64手机的OEM行为、真实应用UID、热点、IPv6、TUN/eBPF实际流量、移动网络切换、持续吞吐或电池消耗。完整诊断文件会把无法取得的信息标为缺失，不以空值推断正常。

## 7. 固定身份、复现与同步

| 对象 | 固定身份 |
| --- | --- |
| 当前验收源码 | ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9 |
| 当前Linux CLI SHA256 | 6e989c28d8648d05a385a4237a3273aee67d54a0766fc869dc2d1746a1a34fba |
| 核心源码 | d850ff0ff68e11a71aa8207627e0a826cb52808f |
| Linux核心SHA256 | bb4194f38699337ffcda5da788df97d715b10724cec706967811672b6099d407 |
| 模板 | MagicSingBox@6b5f68a261818a4ffda6eb9a11b21eef9b755650 |
| 框架 | kamfw@a7788737b938a9ed930645befe2526b626999a22，生产代码来自ea8758bf |

在固定源码和具备相应权限的Linux环境中复现：

```sh
cargo build --release --locked -p magicnet-cli
bash scripts/build-sing-box.sh linux amd64 /absolute/output/sing-box
python3 scripts/test-host-connectivity-performance.py \
  --core /absolute/output/sing-box \
  --cli "$PWD/target/release/magicnet-cli" \
  --output /absolute/output/host-evidence.json
bash scripts/test-fswatch-lifecycle.sh
python3 scripts/test-android-device-simulation.py  # 仅宿主harness单元测试
```

真实Android验收需按[固定提交的KernelSU工作流](https://github.com/LIghtJUNction/magicnet-android/blob/ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9/.github/workflows/android-kernelsu-acceptance.yml)准备SDK、AVD、固定KernelSU内核、当前模块与x86_64运行载荷，再调用`android-device-simulation.py`执行12阶段。上面的`test-android-device-simulation.py`只复现宿主单元测试，不能代替这套设备流程。

主机性能脚本默认不请求公网；显式增加`--google-once`才最多请求一次Google，不内部重试。测试代码保留在源码，最终模块不携带这些目录。配方使用根0.3.14、control0.2.6、runtime0.1.7、delivery0.2.6，配方闭包保持8包；正式负载新增curl及静态TLS/压缩库，不增加常驻服务。目录检查、打包、归档检查与完整提示词生成均通过，闭包为8包59份Markdown。

增量推送依次为：[打包e8aad9e](https://github.com/LIghtJUNction/magicnet-android/commit/e8aad9e4b97c2601d029dcfa1f2b56ac90abd106)、[WebUI 9d545e1](https://github.com/LIghtJUNction/magicnet-android/commit/9d545e100080ef454f7bc7c11fb9c2508b639e4e)、[联网和导出aefcbfb](https://github.com/LIghtJUNction/magicnet-android/commit/aefcbfbab80fe14008e4467eb0292251f7ce8f89)、[CI和转发测量027e91f](https://github.com/LIghtJUNction/magicnet-android/commit/027e91f19330404d5a52120c1ed171f203d90175)、[框架路径回归a7788737](https://github.com/MemDeco-WG/kamfw/commit/a7788737b938a9ed930645befe2526b626999a22)、[监督修复与原生导出验收81a6010](https://github.com/LIghtJUNction/magicnet-android/commit/81a60108477d31ca6131f930f955580ad4fa8ba1)。另有[测试和包内行为门禁d22b122](https://github.com/LIghtJUNction/magicnet-android/commit/d22b122624f30757bd9df182656eaed6883a0365)，保留同期f7188cc的PID边界和重写报告。最终再推送[结构化诊断与设备内容验收b5fa1cd](https://github.com/LIghtJUNction/magicnet-android/commit/b5fa1cd64788bdc5d1dbbd6b88d799c25f895944)。随后推送[正式HTTPS执行器与原生验收fa0e1ad](https://github.com/LIghtJUNction/magicnet-android/commit/fa0e1ad0d36dba6136d8d27364aa98dcde3b5e69)和[宿主版本解析兼容2bbbf2a](https://github.com/LIghtJUNction/magicnet-android/commit/2bbbf2aae491ef13e2b6d1963baa2f20eacc64e5)。再推送[归档权限规范化与明确执行器告警f0d2407](https://github.com/LIghtJUNction/magicnet-android/commit/f0d240764870a97a3e54a1317c1a9590166ef44a)。最后推送[安装夹具依赖补全218e165](https://github.com/LIghtJUNction/magicnet-android/commit/218e1653ba67f950aed25318347ea845bf7467e0)，仅修改测试构造。再推送[ADB空列表兼容ceb7d54](https://github.com/LIghtJUNction/magicnet-android/commit/ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9)，仅修改验收脚本和回归夹具。期间主线的生命周期、扫描/打包优化、模板与框架更新均保留，推送采用预期SHA检查，没有覆盖并行工作。

报告同步位置：[Google Drive报告](https://drive.google.com/file/d/1BgTpaxwSDhH1FAeOp-rpX_fzntbBmWK8/view?usp=drivesdk)，[MagicNet文件夹](https://drive.google.com/drive/folders/1l506lcpZnJS-42-bpKHdk4W8yiAZenrc)。最终安装包的文件名、大小、SHA256和下载位置在门禁完成后补齐。
