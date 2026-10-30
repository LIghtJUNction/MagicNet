# MagicNet 版本化 CLI、机器接口与认证 MCP

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-control-plane"
version = "0.2.3"
kind = "software"
description = "MagicNet 版本化 CLI、机器接口与认证 MCP"
entry = "BUILD_PROMPT.md"

[dependencies.runtime]
source = "../magicnet-network-runtime"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

0.2.3 增加 C-SUB-008：公共状态与私密检查使用相同有界来源读取，区分缺失与坏数据，读取不创建目录，错误保持结构化和脱敏；canonical 读取失败标 unknown。现有 schema-1、命令目录与私密授权边界保持。

0.2.2 补齐一次性命令预算的消费边界和日志尾读内存要求，依赖 runtime 的服务交接合同；机器命令、schema-1 envelope 和 MCP 工具目录保持原公开接口。

2026-10-29 本合同由固定 v1.8.0 基线 `0dca28dd984d82333707cbf4b222596934b4d847` 提取。未发行源码后续修复位于 `magicnet-android@ed01282e8ee4bcfc27ce5f95f37723c34aebf745`；机器命令与 envelope 未增加，私密订阅来源身份已统一到规范请求 URL。此源码提交尚未成为 Android 发行版或设备部署。来源与实际验证见根 SOURCE_AUDIT.md、PROVENANCE.md、VERIFICATION.md。
