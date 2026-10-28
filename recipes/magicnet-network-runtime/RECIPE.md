# MagicNet Android 网络策略与可恢复运行时

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-network-runtime"
version = "0.1.0"
kind = "software"
description = "MagicNet Android 网络策略与可恢复运行时"
entry = "BUILD_PROMPT.md"

[dependencies.engine]
source = "../magicnet-packet-engine"

[dependencies.policy]
source = "../magicnet-routing-policy"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。
