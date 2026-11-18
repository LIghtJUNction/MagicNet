# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.3.30"
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

0.3.30 同步 runtime 0.1.17：TUN 的非零或未知 TOS/DS 路由条件保留未知状态，明确零值继续默认匹配；健康、机器状态和恢复逻辑共用观察结果。保留 webui 0.2.11 与 control 0.2.13 的本机 Zashboard 入口、新鲜就绪检查及共享忙碌门控，其余行为按所属合同执行。

配方版本与 Android 软件版本独立。[DEPENDENCIES.md](DEPENDENCIES.md) 记录当前闭包与源码固定点，根 update.json 记录已发布安装物；实际结果见 [VERIFICATION.md](VERIFICATION.md)，来源与历史见 [PROVENANCE.md](PROVENANCE.md)。配方收录不表示已构建、已安装或已通过设备验收。
