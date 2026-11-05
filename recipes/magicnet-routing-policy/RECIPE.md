# MagicNet 默认路由、DNS 与规则数据合同

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-routing-policy"
version = "0.2.2"
kind = "software"
description = "MagicNet 默认路由、DNS 与规则数据合同"
entry = "BUILD_PROMPT.md"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

0.2.2 对应 v1.8.5 的指定域名拒绝合同：四个精确域名不限目标端口，`dm.wo.com.cn` 仅拒绝 TCP/UDP 目标端口 18080；保留前置 DNS/协议处理，拒绝先于模式、应用与业务分流。新增 POLICY-A08–A12 的匹配、优先级、DNS 和分发验收，实际实现与验证结果见根配方 VERIFICATION.md。

2026-10-29 本轮读取固定 v1.8.0 源码 0dca28dd984d82333707cbf4b222596934b4d847 并补齐重建合同；来源与实际验证见根 SOURCE_AUDIT.md、PROVENANCE.md、VERIFICATION.md。本次配方升级不表示 Android 实现已修复或已发布。
