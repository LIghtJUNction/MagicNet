# 联网恢复、诊断与模块验收 · 2026-11-06

最终源码 [ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9](https://github.com/LIghtJUNction/magicnet-android/commit/ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9)，tree `794e53afe208f03429748bdea554a71b792b5f3b`，元数据 v1.8.5/10613。四条CI通过，Android15模拟器完成12/12阶段、5/5重启与单文件导出；一次正常Google检查得到TLS失败，警告和60秒退避生效。当次未创建正式Release或部署用户手机。

本页保留行为、最终测量和复现入口。[固定完整记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/docs/connectivity-diagnostics-2026-11-06.md)、[host原始数据](evidence/connectivity-diagnostics-host-2026-11-06.json)和[CI审计](evidence/connectivity-diagnostics-ci-2026-11-06.json)保存各候选身份、旧失败和全部测量。

## 最终安装包

归档在组件拆分、manifest和摘要生成前递归去除test/tests、fixture、snapshot、bench、coverage及node_modules等开发目录。按目录段匹配，保留`bin/test`、`rules/test.srs`、`test-support.sh`等运行文件；组件打包器和独立验证器均检查最终ZIP。

实际核验14个ZIP/1,104成员、10组件/168文件、17资产摘要、12依赖pin、9个ARM64 ELF路径；CRC、安全路径、类型、摘要/大小/权限与full/core/components一致，开发目录和元数据均零匹配。新增`bin-curl`的六固定路径、实际ELF、来源锁、ABI/API、NDK、许可及188,900字节/121证书内嵌CA通过。

| 交付物 | 字节数 | SHA-256 | 下载 |
| --- | ---: | --- | --- |
| 完整ARM64模块 | 68,476,029 | `8dc73eb02ed508b772ed55618fa835ef869906ec8f3ae326e594fc94a0fd4d63` | [MagicNet-full-v1.8.5-ceb7d54.zip](https://drive.google.com/file/d/1b0qGXu15kLS01dFjhhF74_tqphRmYaAt/view?usp=drivesdk) |
| Android实际诊断样本 | 64,649 | `145b8cda596cd8348cdfd805f39580b6d31bc0f05e79f29f0522dfd75559175f` | [MagicNet-diagnostics-Android15-ceb7d54.txt](https://drive.google.com/file/d/1e_Cj7QrqJmOCjXNzWdDhxRrKH5bsdaoJ/view?usp=drivesdk) |

两文件来自实际CI/模拟器，未人工改写；Drive回读核对名称、大小和文件夹，未提供云端SHA-256。旧d22/b5/218候选未作为最终包交付。

## 低频检查与恢复

模块提供curl8.22.0、OpenSSL3.5.8、zlib1.3.2、固定CA及许可/来源。ARM64和模拟器x86_64共用API21构建锁；缺失/坏执行器报告本地原因，不触发订阅刷新或重启。请求忽略外部curl配置、继承代理及CA覆盖。

| 条件/预算 | 行为 |
| --- | --- |
| 主目标 | 经当前受控sing-box的本机mixed入口访问`https://www.google.com/generate_204`；TLS验证与HTTP204均成功才在线 |
| 间隔 | 正常300秒；失败60/120/240/480/960/1800秒，封顶30分钟；包含休眠的单调截止时间原子保存，监控重启不清空同次开机退避 |
| 辅助对照 | 主失败再探Cloudflare generate_204；两代理目标均失败后才直连Baidu。正常1请求、故障最多3；HEAD、无内部重试/重定向 |
| 单请求限制 | connect4秒、请求8秒、父预算9秒、输出1KiB |
| 恢复门槛 | 至少连续2次失败、代理双失败、直连成功、无已知缺路由；依次尝试自有路由/DNS、事务性订阅更新、当前核心重启 |
| 冷却 | 恢复动作300秒；订阅刷新3600秒及300秒动作预算；动作执行后仍需下次Google成功才清警告 |
| 停止优先 | 服务停止/禁用/进程归属未知时暂停恢复；只取消确认身份的维护worker。TERM/回滚最多15秒，取消场景等锁20秒，锁保持至回滚及子进程清理结束 |

复用既有60秒watchdog，短命CLI仅到期探测；界面、health、状态读取和诊断导出不新增公网请求。目标特定失败保持警告和退避，不盲目重启；模式、节点、应用策略及停止意图保留。

## 一键导出

WebUI诊断页“一键导出诊断包”写入`/sdcard/Download/MagicNet/MagicNet-diagnostics.txt`：

```sh
su -c '/data/adb/modules/MagicNet/cli support export'
su -c '/data/adb/modules/MagicNet/cli --json support export'
```

`support bundle`输出同样的脱敏文本。报告包含版本/资源、生命周期、缓存联网结果、配置结构和匿名引用、核心check、IPv4/IPv6路由/策略、防火墙/DNS/TUN/eBPF、本地API、订阅事务与回滚、最多8份固定日志尾部及curl能力/来源。各节依次只读采集，不执行恢复、订阅更新、重启、抓包或公网探测。

外部命令共用25秒预算，每流32KiB、每节48KiB、总文件512KiB；配置最多4MiB，日志各32KiB/120行。失败、权限不足、超时和截断明确标记。凭据、订阅URL、SSID/BSSID、节点、UID、设备/流量标识按字段遮蔽；保留JSON、数值/布尔/null、规则顺序、匿名关联与11个真实事务阶段。无效或超限机器输出明确省略，MCP采用已有只读入口。

导出用同目录独占临时文件、sync及原子替换，失败保留旧完整文件；并发最后成功者生效。支持Unix权限时0600，共享存储遵守Android规则。WebUI协商能力并校验退出码、JSON、路径和大小，防双击，失败清旧成功提示。

## 已测资源

Linux6.18.57/x86_64/9CPU，Rust1.87 release CLI `6e989c28d8648d05a385a4237a3273aee67d54a0766fc869dc2d1746a1a34fba`；采用原生fork/exec/wait4，生产Rust逐字节对应最终交付。隔离模块的探测截止时间设在未来。

| CLI路径 | 样本 | 耗时中位 / P95 | RSS |
| --- | ---: | --- | --- |
| connectivity status | 20 | 1.9237 / 2.1997ms | 峰值中位2192KiB，最大2512KiB |
| 未到期tick | 20 | 1.0025 / 1.3087ms | 峰值中位1792KiB，最大2032KiB；状态字节不变 |
| 诊断导出 | 1 | 130.4854ms；无P95 | 最大77700KiB，包含真实core version/check后代；文件19917字节 |

RSS口径为单进程及已等待后代中的最大高水位，不是并发进程树或常驻内存。固定kamfw的60秒空循环采样20秒/21次：shell+sleep RSS1820KiB、PSS549KiB，CPU增量0 ticks（100Hz）；不含核心、周期CLI和Android管理器。

核心`d850ff0ff68e11a71aa8207627e0a826cb52808f`、Go1.26.7、23生产tags，Linux二进制`bb4194f38699337ffcda5da788df97d715b10724cec706967811672b6099d407`。ceb7d54 CI的54规则集空闲RSS两轮稳定中位74476/73688KiB；简单mixed为59180KiB。Linux7.0.0-1017-azure/x86_64/4CPU的回环30组成对26字节请求：代理额外中位0.4556ms；8组4MiB完整字节校验：代理中位5593.3372Mbit/s、直连25462.6838Mbit/s。含预热77请求全部回环、公网0请求。共享CI运行之间缺受控A/B条件，短时结果不外推互联网/Android吞吐或电池开销；64MiB软限额也不是硬RSS上限。

## 最终验证

| 门禁 | 精确运行 | 结果 |
| --- | --- | --- |
| Quality | [42173653819](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653819) | 7/7 jobs；122脚本RUN/PASS、3 Rust精确指纹HIT、0 FAIL，WebUI完整执行498.75秒 |
| Build | [42173653787](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653787) | 真实构建、安装模拟与上述最终归档审计通过 |
| Android | [42173653691](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653691) | attempt1，12/12阶段、5/5重启、0 JUnit失败 |
| Network | [42173653682](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42173653682) | 3/3 jobs，300浏览器场景、192 PNG及核心证据归档核验 |

Android15/API35/x86_64使用direct出口和仅含`magicnet.test`的hosts DNS，未配置真实远端订阅。新boot、root、SELinux Enforcing及三个原生init阶段均核验；包内curl完成版本、gzip、本地TLS正控制、错误主机名与默认信任下自签名拒绝。正控制显式提供测试CA。

正常tick只执行一次：`offline/upstream_unavailable`、`primary_reason=tls_failure`、HTTP null、warning true、probe_count1、退避60秒；辅助代理/直连均failed，last_action none。记录未保留确切curl失败码/握手stderr，唯一原因未知。诊断采集764ms，48节/18基础必需节，0 incomplete/0 truncated；前后18个非倒计时字段和探测数不变。核心瞬时RSS75900KiB、11线程、51FD，VmHWM83324KiB为该进程高水位。

Android证据artifact `13483710663`，509,375字节，SHA-256 `501e231e8f0abd4270e31984a9ab9df74c1a6970abfa351151dc1c5a4c59755f`；28内部文件CRC/路径/类型通过。本地核心运行受netlink权限阻断，真实转发由Linux CI提供。物理ARM64手机、真实订阅/公网204、OEM、热点/IPv6/eBPF、网络切换、持续负载和续航仍未验证。

## 复现与来源

在固定源码和具备所需权限的Linux环境执行：

```sh
cargo build --release --locked -p magicnet-cli
bash scripts/build-sing-box.sh linux amd64 /absolute/output/sing-box
python3 scripts/test-host-connectivity-performance.py \
  --core /absolute/output/sing-box \
  --cli "$PWD/target/release/magicnet-cli" \
  --output /absolute/output/host-evidence.json
bash scripts/test-fswatch-lifecycle.sh
python3 scripts/test-android-device-simulation.py
```

最后一条仅宿主harness单元测试；真实12阶段按[固定KernelSU工作流](https://github.com/LIghtJUNction/magicnet-android/blob/ceb7d54daf0a010bebdcb82b79349f96ac7e0bd9/.github/workflows/android-kernelsu-acceptance.yml)准备SDK、AVD、固定内核、模块与x86_64载荷后执行`android-device-simulation.py`。性能脚本默认无公网请求；`--google-once`最多一次Google尝试。

模板`6b5f68a261818a4ffda6eb9a11b21eef9b755650`，kamfw`a7788737b938a9ed930645befe2526b626999a22`（生产源自ea8758bf）。当次配方8包/59 Markdown通过check/pack/archive/build。完整[Drive报告](https://drive.google.com/file/d/1BgTpaxwSDhH1FAeOp-rpX_fzntbBmWK8/view?usp=drivesdk)与[项目文件夹](https://drive.google.com/drive/folders/1l506lcpZnJS-42-bpKHdk4W8yiAZenrc)保留。
