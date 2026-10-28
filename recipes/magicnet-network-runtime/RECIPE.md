# MagicNet Android 网络策略与可恢复运行时

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-network-runtime"
version = "0.1.1"
kind = "software"
description = "MagicNet Android 网络策略与可恢复运行时"
entry = "BUILD_PROMPT.md"

[dependencies.engine]
source = "../magicnet-packet-engine"

[dependencies.policy]
source = "../magicnet-routing-policy"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

0.1.1 基于 `LIghtJUNction/magicnet-android@0dca28dd984d82333707cbf4b222596934b4d847` 的 v1.8.0 快照提取完整订阅合同，并吸收 #426 为多源重建验收。依赖仍为 engine/policy；源码、转换器二进制和测试临时文件不是配方依赖。`SUBSCRIPTION_CONTRACT.md`、入口和验收共同定义本次修订；新接口通过根包协调 control 的 `subscription_batch_v1`，不新增循环依赖。
