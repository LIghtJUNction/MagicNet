# MagicNet Android 网络策略与可恢复运行时

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-network-runtime"
version = "0.1.10"
kind = "software"
description = "MagicNet Android 网络策略与可恢复运行时"
entry = "BUILD_PROMPT.md"

[dependencies.engine]
source = "../magicnet-packet-engine"

[dependencies.policy]
source = "../magicnet-routing-policy"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

0.1.10 明确 LIFE-008/LIFE-A13：toggle 遇未知进程不启停，透明 effective 与事务 phase 依据实际观测，缺失和歧义不填成已配置或稳定状态。

0.1.9 增加 CON-005/CON-A08–A09：TUN 自动路由有界恢复与真实模拟器故障注入，复用现有 producer 和生命周期。

0.1.8 补齐 #437/#439 的订阅维护进程恢复合同：初始恢复、激活、回滚和中断均在配置锁释放后恢复完整的已配置集合，单独保留 fswatch 原状态。LIFE-007 与 SUB-A22 限定 orphan 候选和订阅重启的热点清理重试；真实归属未知、进程停止失败和 DNS 清理失败继续阻断危险操作。

0.1.7 增加LIFE-006与LIFE-A11：模块控制锁和框架锁使用不同私有对象与固定获取顺序，防止父子调用重复锁定同一文件而自等待。监督器验收必须使用真实固定kamfw，包括重复/并发启动、停止、忙锁预算和锁描述符继承。同版本CON-004与CON-A07要求正式包提供实际可用的HTTPS执行器及CA，在无系统curl的Android上核验版本、TLS正反控制和遵守冷却的真实产品探测；执行器缺失保留本地原因，不增加常驻服务。

0.1.6 增加 CONNECTIVITY_CONTRACT.md：主目标经 mixed 代理每 300 秒检查，失败指数退避到 1800 秒；差异探测、有条件恢复、订阅冷却、停止意图及监督交接均有独立验收。复用既有监督与生命周期锁，没有新增常驻运行库或服务。

0.1.4 增加 #434 的默认 UA 403 单次回退（SUB-003、SUB-A21），并保留 0.1.3 的 IPv4-mapped 地址钉选。

0.1.3 补齐冲突 tag 与实际引用的对应关系、逐来源原生已知数量下界，以及网络策略部分修复和回滚的完整基线。数量下界是有限防丢检查，完整字段语义仍按 SUB-005–007 验证；未知原生格式继续允许经受支持转换器处理。新增 SUB-A19–A20，与 control 的 C-SUB-008 共同定义本轮边界。

0.1.2 增加 LIFECYCLE_CONTRACT.md：分离短命令和持久服务的资源归属，规范就绪前清理、就绪后交接，以及跨 shell 的 PID 边界。engine/policy 依赖关系不变，不新增常驻服务。

0.1.1 基于 `LIghtJUNction/magicnet-android@0dca28dd984d82333707cbf4b222596934b4d847` 的 v1.8.0 快照提取完整订阅合同，并吸收 #426 为多源重建验收。依赖仍为 engine/policy；源码、转换器二进制和测试临时文件不是配方依赖。`SUBSCRIPTION_CONTRACT.md`、入口和验收共同定义本次修订；新接口通过根包协调 control 的 `subscription_batch_v1`，不新增循环依赖。
