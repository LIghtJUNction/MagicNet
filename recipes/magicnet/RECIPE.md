# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.3.3"
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

配方版本与被观察软件版本分开管理；初始来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210，后续 v1.8.0 迭代与证据见 PROVENANCE.md 和 VERIFICATION.md。0.2.1 修正源码子模块布局与获取方法，没有改变 Android 软件版本。实现源码不属于本包。

0.3.3 在保留订阅配方 0.3.2 的基础上，通过 packet-engine 0.2.1 增加固定上游同步、握手失败清理与流关闭并发合同，核心验收为 M48。已有八包依赖图、Android 产品版本和前端合同继续保留。内核的已采用提交及实际检查见 PROVENANCE.md 与 VERIFICATION.md。

0.3.2 整合独立候选发现的目录晋升、更新回执重放、网络策略恢复和订阅草稿验收，并补齐冲突引用、逐来源数量下界、共享只读来源检查与模块目录元数据。control 为 0.2.3，runtime 为 0.1.3；保留 M41–M43 和最新 WebUI 视觉合同。规格先于本轮源码修复，实施与测试结果见 VERIFICATION.md；候选源码仍作为独立历史证据，不替换现行 gitlink。

0.3.1 将 #429、#430 的超时继承、持久核心交接与 32 位 PID 校验问题纳入实现和重建合同，同时约束日志尾读的临时内存。依赖闭包仍为八包；本次配方版本变更不改变已公开 Android 安装包的版本，实际源码和验证结果见 VERIFICATION.md。

2026-10-29 配方 0.3.0 基于固定 v1.8.0 源码 `0dca28dd984d82333707cbf4b222596934b4d847` 补齐重建合同。后续未发行源码修复已推送到 `magicnet-android@ed01282e8ee4bcfc27ce5f95f37723c34aebf745` 并由本仓库固定 gitlink 接入；尚未发布 Android 版本或部署设备。来源与验证见根 SOURCE_AUDIT.md、PROVENANCE.md、VERIFICATION.md。

2026-10-29 构建发布工作流修复后，当前实现 gitlink 固定为 `magicnet-android@b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7`。保留前述订阅修复，增加同提交跨仓库 Android 验收和源码仓库发行拦截；正式发布入口恢复在 MagicNet 主仓库，默认只构建。Android 软件版本仍为 v1.8.0，没有创建新发行版。

2026-10-29 v1.8.1 发行准备：软件版本 v1.8.1 / versionCode 10609，当前源码 gitlink 为 `68ad77453d752845eedb5dd8ca56110c18de4b26`。发行说明与官方更新地址同步；最终构建、Android 验收和公开发布结果另记 VERIFICATION.md。

同日正式验收发现并修正 POSIX shell 的单节点失败传播差异，当前发行候选源码固定 `8a2e14609ffaa802ca6ac7dc844017637749430d`；完整验收与公开发行状态以 VERIFICATION.md 为准。

发行门槛中的模拟进程退出夹具改为原子移走目录，避免把普通目录逐文件删除当成 /proc 的退出可见性；仅修改测试，不放宽生产进程身份校验。最终发行候选源码为 `9770f8f29db8e240eff24f774fb32807f2f3e005`。

第三轮发行的 ShellCheck 门槛拦截后，统一清理临时清单的位置，保留写入失败时的整批中止；同步旧测试的生成器调用、语义去重和合法 URL 合同，补齐发布主机的 mksh。当前发行候选固定 `8f6ddbc362bb7059be91b7734061b2c1e5381e56`，完整公开发行结果仍以 VERIFICATION.md 为准。

第四轮发现 jq 版本语法兼容问题，语义聚合改用 jq 1.7.1 与 1.8.2 均可解析的完整表达式绑定，不改变节点身份、去重或冲突拒绝规则。当前发行候选为 `a5617d6371fe17494fb4b4a6f655a0c8a0f7461e`；基线解释器下完整 105 项主机检查通过，正式发行结果见 VERIFICATION.md。

v1.8.1 / versionCode 10609 已公开，配方/标签提交 `b762b8c54b99c7561914d3a02c3a635636ae6837`、源码 `a5617d6371fe17494fb4b4a6f655a0c8a0f7461e`。第五轮构建、完整质量与 Android 模拟器门槛通过；发布控制的草稿查询 404 已修复，并由独立恢复重新核对同一不可变产物和原 19 个附件后公开。详细 run 与实际验证边界见 VERIFICATION.md；未部署真机。
