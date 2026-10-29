# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.3.0"
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

2026-10-29 配方 0.3.0 基于固定 v1.8.0 源码 `0dca28dd984d82333707cbf4b222596934b4d847` 补齐重建合同。后续未发行源码修复已推送到 `magicnet-android@ed01282e8ee4bcfc27ce5f95f37723c34aebf745` 并由本仓库固定 gitlink 接入；尚未发布 Android 版本或部署设备。来源与验证见根 SOURCE_AUDIT.md、PROVENANCE.md、VERIFICATION.md。

2026-10-29 构建发布工作流修复后，当前实现 gitlink 固定为 `magicnet-android@b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7`。保留前述订阅修复，增加同提交跨仓库 Android 验收和源码仓库发行拦截；正式发布入口恢复在 MagicNet 主仓库，默认只构建。Android 软件版本仍为 v1.8.0，没有创建新发行版。

2026-10-29 v1.8.1 发行准备：软件版本 v1.8.1 / versionCode 10609，当前源码 gitlink 为 `68ad77453d752845eedb5dd8ca56110c18de4b26`。发行说明与官方更新地址同步；最终构建、Android 验收和公开发布结果另记 VERIFICATION.md。
