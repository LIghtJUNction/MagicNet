# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.3.34"
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

[BUILD_PROMPT.md](BUILD_PROMPT.md) 定义产品， [ACCEPTANCE.md](ACCEPTANCE.md) 定义 M01–M79。四个直接依赖组成八包 Markdown 闭包，源码和二进制不进入配方。

0.3.34 同步 control 0.2.14 与 webui 0.2.12：节点列表以已提交配置为准，旧工作目录和暂存候选不能抢占名额；返回节点页重新获取当前核心快照，晚响应不覆盖新结果。共享界面按统一留白、轻量面板和清楚的控件层次调整，保留全部页面、草稿、主题和操作门控。

0.3.33 同步 runtime 0.1.20：承接配置范围驱动的热点 FIB 判断，恢复规范表查询参数并由严格夹具验证；未过期 TUN 缓存只用于当前核心 PID/starttime，旧代际与不可读身份保持 unknown。状态读取不修改 canonical、探测次数或恢复预算，保留 schema=1、既有状态优先级与界面合同。

0.3.31 同步 runtime 0.1.18：FIB 条件只影响与必要目的范围相交的路由，排除区间和无关目的前缀不干扰完整或缺失判断；手动检查自身仅观测，其待处理请求允许后台继续清理已停止核心的自有网络残留。保留 schema=1、既有锁、恢复预算及 Zashboard 界面合同。

配方版本与 Android 软件版本独立。[DEPENDENCIES.md](DEPENDENCIES.md) 记录当前闭包与源码固定点，根 update.json 记录已发布安装物；实际结果见 [VERIFICATION.md](VERIFICATION.md)，来源与历史见 [PROVENANCE.md](PROVENANCE.md)。配方收录不表示已构建、已安装或已通过设备验收。
