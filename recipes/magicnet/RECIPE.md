# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.1.0"
kind = "software"
description = "MagicNet Android root 透明网络工作台"
entry = "BUILD_PROMPT.md"

[dependencies.control]
source = "../magicnet-control-plane"

[dependencies.webui]
source = "../magicnet-web-console"

[dependencies.delivery]
source = "../magicnet-module-delivery"

[dependencies.quality]
source = "../software-quality"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。
