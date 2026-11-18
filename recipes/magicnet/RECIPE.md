# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.3.29"
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

[BUILD_PROMPT.md](BUILD_PROMPT.md) 定义产品， [ACCEPTANCE.md](ACCEPTANCE.md) 定义 M01–M78。四个直接依赖组成八包 Markdown 闭包，源码和二进制不进入配方。

0.3.29 同步 webui 0.2.11 与 control 0.2.13：显眼的本机 Zashboard 入口，点击时检查新鲜 API/本地资源状态，保留 setup 参数，兼容旧 CLI 并共享忙碌门控。已有严格联网探测、有界恢复、日常导航和退出清理继续按所属合同执行。

配方版本与 Android 软件版本独立。[DEPENDENCIES.md](DEPENDENCIES.md) 记录当前闭包与源码固定点，根 update.json 记录已发布安装物；实际结果见 [VERIFICATION.md](VERIFICATION.md)，来源与历史见 [PROVENANCE.md](PROVENANCE.md)。配方收录不表示已构建、已安装或已通过设备验收。
