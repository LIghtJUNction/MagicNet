# MagicNet 移动网络控制界面

~~~toml
format = "recipkg/1"

[package]
name = "magicnet-web-console"
version = "0.2.4"
kind = "software"
description = "MagicNet 移动网络控制界面"
entry = "BUILD_PROMPT.md"
~~~

0.2.4 增加概览/诊断页的缓存 Google 连通性、明确警告/退避/恢复结果，以及协商 support.export 能力后的一键单文件导出。界面刷新不增加探测或特权恢复；保留原生桥串行、防重复提交、失败清除旧成功及 zh-CN/en/ru。

配方版本与被观察软件版本分开管理；初始来源为 MagicNet v1.7.2，提交 96993ea5c851b8d51cc562c3ca0766a2ca571210。本次从 magicnet-android 的 v1.8.0 基线 `0dca28dd984d82333707cbf4b222596934b4d847` 提取订阅编辑、私密载荷、后台完成确认及来源用量行为，并加入 #426 的多来源重建验收；详见 SUBSCRIPTION_FLOW.md。后续未发行源码修复提交为 `ed01282e8ee4bcfc27ce5f95f37723c34aebf745`，未做浏览器/设备验收或 Android 发布。实现源码不属于本包。
