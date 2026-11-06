# MagicNet 默认路由、DNS 与规则数据合同

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-routing-policy"
version = "0.2.5"
kind = "software"
description = "MagicNet 默认路由、DNS 与规则数据合同"
entry = "BUILD_PROMPT.md"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

0.2.5 增加 POLICY-A21–A25：托管默认 DNS 对未知域名使用经 `proxy` 的 `doh-cloudflare`，代理不可用时失败；保留 `bootstrap-local-dns` 引导解析、显式国内/Direct/LAN 规则及已验证独立配置的 DNS 图。诊断检查实际默认引用与 detour，精确旧官方模板 pin 随升级迁移，自定义 pin 保留。无新增运行时依赖，源码仍为 1.8.5，本轮不新建发行；证据见根配方 DNS_REPAIR_2026-11-06.md。

0.2.4 在 v1.8.5 候选中增加 16 个大陆教育服务域名后缀的业务分流合同，复用默认直连的 `cn-direct` 和现有本地加密 DNS。模式、LAN、用户与应用分流、广告和 DNS 防护继续优先；新增 POLICY-A16–A20，官方域名来源见 POLICY_INVENTORY.md。保持既有 selector 与规则数据依赖，实际验证见根配方 VERIFICATION.md。

0.2.3 移除专用 ChatGPT Voice 更新入口、上游来源、JSON 资产和 IP/端口路由；保留 `meta-openai`、`ai-chatgpt` 与 ChatGPT 域名、应用包名及 DNS 分流。POLICY-A13–A15 验收清理范围、普通 ChatGPT 分流及构建/刷新后的规则库存。

0.2.2 对应 v1.8.5 的指定域名拒绝合同：四个精确域名不限目标端口，`dm.wo.com.cn` 仅拒绝 TCP/UDP 目标端口 18080；保留前置 DNS/协议处理，拒绝先于模式、应用与业务分流。新增 POLICY-A08–A12 的匹配、优先级、DNS 和分发验收，实际实现与验证结果见根配方 VERIFICATION.md。

2026-10-29 本轮读取固定 v1.8.0 源码 0dca28dd984d82333707cbf4b222596934b4d847 并补齐重建合同；来源与实际验证见根 SOURCE_AUDIT.md、PROVENANCE.md、VERIFICATION.md。本次配方升级不表示 Android 实现已修复或已发布。
