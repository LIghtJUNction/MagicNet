# MagicNet 模块安装、组件分发与安全更新

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-module-delivery"
version = "0.2.7"
kind = "software"
description = "MagicNet 模块安装、组件分发与安全更新"
entry = "BUILD_PROMPT.md"
~~~

0.2.7 要求新装和升级从本次安装包补入缺失的网页探测目标清单，保留用户已有目录内容及订阅更新历史，不新增运行锁迁移项，当前 subscription-update.lock 不随历史恢复。Android 临时 TLS 证书采用有限时钟容差，失败也保留脱敏证据；就绪等待超时复用既有有界脱敏支持包，采集失败不覆盖原错误；产品信任根与正式发行门槛不变。

0.2.6 将可信curl作为正式运行组件，生产ARM64与模拟器x86_64使用相同锁源及TLS/压缩/CA构建流程，携带许可与构建证明，并进入既有manifest、摘要、安装与复用事务。实际无系统curl环境验证执行器和证书边界；测试专用注入不作为生产供应证据。

0.2.5 要求所有最终模块和组件 ZIP 递归排除测试、fixture、快照、基准、覆盖率及 node_modules 目录；源码测试和运行同名文件保留。清理、拆包与发布内容验证形成独立门禁，实际归档证据见 ACCEPTANCE.md。

0.2.4 统一安装引导与卸载告别页的启动器来源：直接维护固定 `kamfw` 子模块，保留当前用户浏览器回退、失败传播和既有调用接口。

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

2026-10-29 本轮读取固定 v1.8.0 源码 0dca28dd984d82333707cbf4b222596934b4d847 并补齐重建合同；来源与实际验证见根 SOURCE_AUDIT.md、PROVENANCE.md、VERIFICATION.md。本次配方升级不表示 Android 实现已修复或已发布。
