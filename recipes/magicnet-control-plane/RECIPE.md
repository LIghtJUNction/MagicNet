# MagicNet 版本化 CLI、机器接口与认证 MCP

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-control-plane"
version = "0.2.10"
kind = "software"
description = "MagicNet 版本化 CLI、机器接口与认证 MCP"
entry = "BUILD_PROMPT.md"

[dependencies.runtime]
source = "../magicnet-network-runtime"
~~~

配方版本与被观察软件版本分开管理；来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。实现源码不属于本包。

0.2.9 明确缺参错误、未知进程的 toggle 拒绝，以及透明配置和事务 phase 的 unknown 语义。机器快照与 canonical 使用同一判断，保留原 schema 和命令集合。

0.2.8 在 connectivity.status 增加独立、只读的 tun_auto_route 观察与恢复预算；保留 Google/mixed_proxy 字段语义，诊断导出按字段脱敏。

0.2.7 要求 TUN 数据面判断包含有效配置对应的实时策略路由与转发表证据，区分规则缺失和无法观测；只读、有界且不主动修复。现有 schema-1 字段、configured/effective、未知值与隐私边界保持，实际源码和覆盖范围见根 ISSUE_TRIAGE_2026-11-06.md。

0.2.6 将后台监督器和connectivity watchdog的启动日志及HTTPS执行器能力、固定构建来源纳入诊断，避免遗漏启动失败或工具缺失。固定日志清单上限为八个，单日志尾读、全文件大小、命令期限与脱敏合同保持；Android验收实际核对导出文件、机器回执和拉取文件的字节、完整性及状态内容语义。机器状态按字段脱敏，保留可解析结构和真实事务阶段；只调用已支持的只读采集入口，工具版本查询不发网络请求。DIAG-A07–A08分别验收结构保真和HTTPS执行器证据。

0.2.5 增加缓存只读 connectivity.status、service.status 的 connectivity 字段和显式 support.export 机器写例外。DIAGNOSTIC_CONTRACT.md 规定内容、资源上限、脱敏和单文件原子发布；MCP 增加只读缓存资源，不把诊断变为自动修复。

0.2.3 增加 C-SUB-008：公共状态与私密检查使用相同有界来源读取，区分缺失与坏数据，读取不创建目录，错误保持结构化和脱敏；canonical 读取失败标 unknown。现有 schema-1、命令目录与私密授权边界保持。

0.2.2 补齐一次性命令预算的消费边界和日志尾读内存要求，依赖 runtime 的服务交接合同；机器命令、schema-1 envelope 和 MCP 工具目录保持原公开接口。

2026-10-29 本合同由固定 v1.8.0 基线 `0dca28dd984d82333707cbf4b222596934b4d847` 提取。未发行源码后续修复位于 `magicnet-android@ed01282e8ee4bcfc27ce5f95f37723c34aebf745`；机器命令与 envelope 未增加，私密订阅来源身份已统一到规范请求 URL。此源码提交尚未成为 Android 发行版或设备部署。来源与实际验证见根 SOURCE_AUDIT.md、PROVENANCE.md、VERIFICATION.md。

0.2.10 增加 C-SUB-009：设备 CLI 管理私密订阅信任清单，authority-only 检查/解析入口共用后端策略；现有公网 resolve-host、schema-1 envelope 和公共状态披露范围保持。
