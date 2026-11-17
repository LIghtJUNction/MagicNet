# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.3.27"
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

本包描述完整 Android root 网络工作台；行为与 M01–M74 验收分别见 [BUILD_PROMPT.md](BUILD_PROMPT.md) 和 [ACCEPTANCE.md](ACCEPTANCE.md)。四个直接依赖递归组成八包，源码和二进制不进入 Markdown 配方负载。

配方版本与 Android 软件版本独立。当前依赖、源码固定点见 [DEPENDENCIES.md](DEPENDENCIES.md)；已发布安装物以根 `update.json` 为准，实际验证与未完成范围见 [VERIFICATION.md](VERIFICATION.md)。runtime 0.1.15、control 0.2.11、webui 0.2.10 与 delivery 0.2.12 共同定义日常操作恢复、未知状态、TUN 有界恢复和模拟器证据门禁。

0.3.27 增加 M73–M74：四项日常直达与更多导航、默认折叠的概览技术信息，以及核心退出后在既有锁内清理自有网络资源。保留全部页面、三语、配置意图、schema=1 和运行依赖；候选实现与正式发行的实际结果分别记录。

0.3.26 增加 M72：同步固定 fork、规则与兼容依赖，修复草稿定位和 HTTPS 输入下载，保留文本诊断行为；实际测试和正式发行身份按 VERIFICATION 记录。

0.3.25 增加 M70：watcher 并发启停、退出状态、TUN 冲突观察、配置事务、协议编辑保真与卸载重试。复用现有锁、状态和事务，保持运行依赖与正式发行版本边界。

0.3.24 同步可信本地订阅授权、分流规则稳定插入、链路本地 mDNS 与固定规则资产，并保留简约 WebUI 和窄屏翻译边界。继续遵守 M66 和 runtime CON-A09 的网络重编号验证、完整 selectors 与重复次数核对。

初始观察来源为 MagicNet v1.7.2（`96993ea5c851b8d51cc562c3ca0766a2ca571210`）。来源归属和迭代历史保留于 [PROVENANCE.md](PROVENANCE.md)；旧版本说明可查[精简前的固定记录](https://github.com/LIghtJUNction/MagicNet/blob/26c8d0374ce3eecfdf457eee9f3ba14ed744242a/recipes/magicnet/RECIPE.md)。
