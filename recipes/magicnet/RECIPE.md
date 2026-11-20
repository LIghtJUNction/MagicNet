# MagicNet Android root 透明网络工作台

~~~toml
format = "recipkg/1"

[package]
name = "magicnet"
version = "0.3.38"
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

[BUILD_PROMPT.md](BUILD_PROMPT.md) 定义产品， [ACCEPTANCE.md](ACCEPTANCE.md) 定义 M01–M87。四个直接依赖组成八包 Markdown 闭包，源码和二进制不进入配方。

0.3.38 同步 routing-policy 0.2.7 的固定规则发行资产，以及 Vue、tailwind-merge 和 zeroize 的兼容锁文件更新。M72 验收发布归档与清单、实际模板引用的规则文件及两套 WebUI 锁。

0.3.37 同步 runtime 0.1.21：M85–M87 固化数值路由表身份、停服前热点周期循环静止及运行中 start/ensure 的保守快路；M26 补充 DNS 安装的冗余内核调用验收。沿用配置锁、所有权、恢复日志和原 shell bootstrap，未知条件回原路径。反馈来源、宿主回归、当前设备基线与尚待验收的场景分别记录；不以闭单或调用次数减少代替实机性能结论。

0.3.36 同步 webui 0.2.14：概览使用左对齐状态、56px 起的矩形服务按钮与相邻刷新、平面日常入口和克制的蓝色操作层级，保持五项底栏、左抽屉与原设备流程。M84 增加模态确认期间的快捷键隔离、焦点恢复、滚动锁和零设备写入验收；机器接口、状态面与运行依赖保持。

0.3.35 同步 control 0.2.15 与 webui 0.2.13：按结构识别真实节点并保留合法特殊标签，存在但无成员的选择器保持空，扫描与缓存回退一致；链式代理候选保留方括号前缀，仅过滤明确日志。扩充 M79，并增加 Android awk JSON 编码与 SS 完整回退的 M80、首页及导航结构的 M81；服务操作、模式/延迟/RSS、任务链接与手机 dock/左抽屉共用原操作。M82 将同一任务层级扩展到全部 14 页，以 360/390/430px 手机界面逐页验收，补齐节点与代理组的截图。M83 要求构建依赖准备的失败立即向构建器返回非零，不能被后续成功掩盖。沿用现有接口、依赖和发行身份。

0.3.34 同步 control 0.2.14 与 webui 0.2.12：节点列表以已提交配置为准，旧工作目录和暂存候选不能抢占名额；返回节点页重新获取当前核心快照，晚响应不覆盖新结果。共享界面按统一留白、轻量面板和清楚的控件层次调整，保留全部页面、草稿、主题和操作门控。

0.3.33 同步 runtime 0.1.20：承接配置范围驱动的热点 FIB 判断，恢复规范表查询参数并由严格夹具验证；未过期 TUN 缓存只用于当前核心 PID/starttime，旧代际与不可读身份保持 unknown。状态读取不修改 canonical、探测次数或恢复预算，保留 schema=1、既有状态优先级与界面合同。

0.3.31 同步 runtime 0.1.18：FIB 条件只影响与必要目的范围相交的路由，排除区间和无关目的前缀不干扰完整或缺失判断；手动检查自身仅观测，其待处理请求允许后台继续清理已停止核心的自有网络残留。保留 schema=1、既有锁、恢复预算及 Zashboard 界面合同。

配方版本与 Android 软件版本独立。[DEPENDENCIES.md](DEPENDENCIES.md) 记录当前闭包与源码固定点，根 update.json 记录已发布安装物；实际结果见 [VERIFICATION.md](VERIFICATION.md)，来源与历史见 [PROVENANCE.md](PROVENANCE.md)。配方收录不表示已构建、已安装或已通过设备验收。
