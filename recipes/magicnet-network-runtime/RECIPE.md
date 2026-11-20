# MagicNet Android 网络策略与可恢复运行时

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-network-runtime"
version = "0.1.21"
kind = "software"
description = "MagicNet Android 网络策略与可恢复运行时"
entry = "BUILD_PROMPT.md"

[dependencies.engine]
source = "../magicnet-packet-engine"

[dependencies.policy]
source = "../magicnet-routing-policy"
~~~

0.1.21 增加 LIFE-011–014 / LIFE-A17–A24：路由表的数值身份与旧 prepared 基线迁移、停服前热点周期循环静止和持锁失败恢复、已确认自有运行核心的保守 start/ensure 快路，以及 DNS 私有链的单次 detach 与新空链免 flush。保留原所有权、事务日志、bootstrap、未知回退、幂等维护和失败清理；运行依赖、机器接口与公共状态字段保持。

0.1.20 补齐 CON-A08 的缓存代际投影：未过期 present/missing 必须匹配当前单一已归属 PID/starttime，身份更换/复用/多义/不可读为 unknown，状态读取不改文件、探测或恢复预算；同时修正热点表查询 argv 并保留严格独立夹具。

0.1.19 承接热点配置范围与 FIB 共用观察器：按有效 route_address 减静态排除核验完整 IPv4 覆盖，完整/明确缺失/不确定分别 active/pending/unknown；原 RPDB、FORWARD、内部 peer 回程、只读和脱敏边界继续必需。

0.1.18 补齐 CON-A08/CON-A10 的范围与调度边界：只评估目的前缀与必要范围相交的 FIB 路由，无关条件不能掩盖缺失；人工检查保持仅观测，排队请求不阻止后台停机清理。锁内身份复核、资源归属及恢复预算保持。

0.1.17 补齐 CON-005/CON-A08 的 FIB 条件判定：非零或未知 `tos` / `dsfield` 不作为普通流量的完整 TUN 覆盖；明确零值保留默认匹配。健康、机器状态与 watchdog 共用结果，未知清除连续缺失且不触发恢复，沿用已有接口与依赖。

0.1.16 增加 CON-007–008/CON-A11–A14：经所选出站严格 GET 并校验双站点 204，与 mixed 数据面独立记录；候选最多三个且来自当前组的既有真实代理，配置锁内重查、保存、切换与读回，复验失败补偿旧选择。人工 check 和切换后的即时检查不清空恢复冷却、TUN 次数或用户停止意图。

0.1.15 增加 CON-006/LIFE-010：核心已退出时，既有 watchdog 在配置/生命周期锁内再次确认后复用停止后清理，撤销自有 DNS/热点网络资源。忙锁、活跃或未知核心、停用和取消不清理；失败保留证据并重试，不复活核心。沿用 schema=1、已有状态域与运行依赖。

0.1.14 将 connectivity 与 Wi-Fi watcher 的启停纳入同一有界生命周期锁，区分已退出进程与活进程身份未知；TUN 路由冲突保留未知观察并阻止据此自动恢复。

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

0.1.13 增加 SUB-016/SUB-A23–A26：设备以精确 origin 与本地 CIDR 明确授权订阅来源，使用直连或指定的 loopback SOCKS5。每次解析、重试和同源跳转核对全部地址，公网下载链不取得本地权限。复用受管 curl、配置锁与订阅事务，无新增运行依赖；保留 0.1.12 的 netd 归属验收。

0.1.12 补齐 CON-A09 的 netd 规则归属证据：采集器与独立门禁分别从网络元数据派生全局和逐应用 UID selectors，核对完整字段和重复次数，仅接受已证明归属的 netId 变化。证据 schema 与生产恢复预算保持。

0.1.10 明确 LIFE-008/LIFE-A13：toggle 遇未知进程不启停，透明 effective 与事务 phase 依据实际观测，缺失和歧义不填成已配置或稳定状态。

0.1.9 增加 CON-005/CON-A08–A09：TUN 自动路由有界恢复与真实模拟器故障注入，复用现有 producer 和生命周期。

0.1.8 补齐 #437/#439 的订阅维护进程恢复合同：初始恢复、激活、回滚和中断均在配置锁释放后恢复完整的已配置集合，单独保留 fswatch 原状态。LIFE-007 与 SUB-A22 限定 orphan 候选和订阅重启的热点清理重试；真实归属未知、进程停止失败和 DNS 清理失败继续阻断危险操作。

0.1.7 增加LIFE-006与LIFE-A11：模块控制锁和框架锁使用不同私有对象与固定获取顺序，防止父子调用重复锁定同一文件而自等待。监督器验收必须使用真实固定kamfw，包括重复/并发启动、停止、忙锁预算和锁描述符继承。同版本CON-004与CON-A07要求正式包提供实际可用的HTTPS执行器及CA，在无系统curl的Android上核验版本、TLS正反控制和遵守冷却的真实产品探测；执行器缺失保留本地原因，不增加常驻服务。

0.1.6 增加 CONNECTIVITY_CONTRACT.md：主目标经 mixed 代理每 300 秒检查，失败指数退避到 1800 秒；差异探测、有条件恢复、订阅冷却、停止意图及监督交接均有独立验收。复用既有监督与生命周期锁，没有新增常驻运行库或服务。

0.1.4 增加 #434 的默认 UA 403 单次回退（SUB-003、SUB-A21），并保留 0.1.3 的 IPv4-mapped 地址钉选。

0.1.3 补齐冲突 tag 与实际引用的对应关系、逐来源原生已知数量下界，以及网络策略部分修复和回滚的完整基线。数量下界是有限防丢检查，完整字段语义仍按 SUB-005–007 验证；未知原生格式继续允许经受支持转换器处理。新增 SUB-A19–A20，与 control 的 C-SUB-008 共同定义本轮边界。

0.1.2 增加 LIFECYCLE_CONTRACT.md：分离短命令和持久服务的资源归属，规范就绪前清理、就绪后交接，以及跨 shell 的 PID 边界。engine/policy 依赖关系不变，不新增常驻服务。

0.1.1 基于 `LIghtJUNction/magicnet-android@0dca28dd984d82333707cbf4b222596934b4d847` 的 v1.8.0 快照提取完整订阅合同，并吸收 #426 为多源重建验收。依赖仍为 engine/policy；源码、转换器二进制和测试临时文件不是配方依赖。`SUBSCRIPTION_CONTRACT.md`、入口和验收共同定义本次修订；新接口通过根包协调 control 的 `subscription_batch_v1`，不新增循环依赖。
