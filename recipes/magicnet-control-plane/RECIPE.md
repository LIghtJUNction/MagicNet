# MagicNet 版本化 CLI、机器接口与认证 MCP

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-control-plane"
version = "0.2.1"
kind = "software"
description = "MagicNet 版本化 CLI、机器接口与认证 MCP"
entry = "BUILD_PROMPT.md"

[dependencies.runtime]
source = "../magicnet-network-runtime"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

2026-10-29 本轮读取固定 v1.8.0 源码 0dca28dd984d82333707cbf4b222596934b4d847 并补齐重建合同；来源与实际验证见根 SOURCE_AUDIT.md、PROVENANCE.md、VERIFICATION.md。本次配方升级不表示 Android 实现已修复或已发布。
