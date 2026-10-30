# 重建 MagicNet（配方 0.3.1）

为 Android root 用户重建 MagicNet：从首次安装与订阅导入，到按应用、Wi-Fi、热点分流，再到节点、故障诊断和自动化控制。保留来源版本的完整用户行为，不能交付只有静态页面或包装命令的演示。

## 用户已确认的选择

- 语言由重建 Agent 根据 Android、特权边界、协议兼容与维护成本选择；没有必须保留 Rust、Shell、Go 或 Vue 的要求。可复用合规第三方实现，不要求重新发明加密协议。
- 保留全部功能及现有目标平台：生产设备为 Android root / arm64，支持 Magisk、KernelSU、APatch；WebUI 由模块管理器提供的 WebView/浏览器桥接运行。Linux 宿主与 x86_64 模拟器是开发环境，不是新的生产平台。
- 保留操作流程，视觉沿用矿白、石墨与玉绿身份，增加留白、减少重复边框，用排版和背景层次组织内容；空间与控件规则见 webui 的 DESIGN.md。保留诊断、文件草稿、失败恢复和无障碍状态。
- 沿用现有语种：WebUI zh-CN/en/ru；安装向导和操作菜单保留已有中、英、俄、日、韩语言能力及各自回退。机器 token、命令参数、配置内容、日志不翻译。
- 测量并记录现有性能基线；性能预算未知，不能把基线直接宣布为承诺。见 PERFORMANCE.md。
- 项目和主仓库名称保持 MagicNet，不加 recipkg 后缀。配方为本体；generated/ 只作容器，实现放在独立的小写连字符源码仓库，以固定提交子模块接入 generated/<source-repository-name>/，仓库名与子目录名相同。当前源码固定为 LIghtJUNction/magicnet-android@b113f5128549172da6cb1f6e62f0b42d31adb956；其基线 `0dca28dd984d82333707cbf4b222596934b4d847` 的完整 tree 与原仓库 v1.8.0 相同。后续提交包含订阅修复、跨仓库构建发布兼容、服务交接与 PID 校验修复、日志内存优化及前端留白与边框调整，正式构建发布的状态与证据见 VERIFICATION.md，尚未部署设备。main 跟踪 gitlink 和 .gitmodules；源码与观察 checkout 均不是 Recipkg 依赖，不进入配方负载。原仓库历史标签保留发行来源。
- 用户反馈与 Issue 转录见 FEEDBACK.md；M18–M29 保留原需求，M30–M39 新增多订阅、Encryption、可观测状态和重建交付验收。SOURCE_AUDIT.md 分开记录基线缺陷、当前源码修复和仍未知事项；配方合同或源码 main 更新都不等于 Android 版本已发布/部署或 #426 根因已确认。

Android 全产品最低版本及 WebView 最低版本仍未知。Java 网络策略桥以 API 26 为最低目标不等于整个产品保证支持 Android 8。不得从一台 Android 14 设备推导全版本兼容。

## 阅读范围

完整阅读本文件、BEHAVIOR.md、ACCEPTANCE.md、FEEDBACK.md、SOURCE_AUDIT.md、PERFORMANCE.md、PROVENANCE.md、DEPENDENCIES.md、LICENSE.md，以及四个依赖和所有递归依赖的全部 Markdown。归档内的依赖按 alias 展开，不能只读根入口。

本轮增加的具体合同为 control/SUBSCRIPTION_INTERFACE.md、runtime/SUBSCRIPTION_CONTRACT.md、webui/SUBSCRIPTION_FLOW.md、engine/VLESS_ENCRYPTION.md；这里的前缀是依赖职责简称，包名及实际位置由 RECIPE/LOCK 决定。依赖完整闭包仍是八包，不因补充合同新增常驻服务。

0.3.1 增加 runtime/LIFECYCLE_CONTRACT.md，并补齐 control 的命令预算和日志内存要求：一次启动操作的超时不能被长期守护继承；核心就绪前由启动方负责回收，就绪后不受旧命令进程组的超时清理影响；PID 校验在 Android mksh 的 32 位算术下也必须准确。日志读取只为请求的尾部行分配索引，避免短行文件放大临时内存。根验收 M41–M43 与对应组件验收共同约束这些行为。

## 独立重建边界

新构建上下文只接收完整递归 Markdown 配方和明确允许的通用工具/外部资源。先在空实现目录构建，不读取、复制、调用旧 MagicNet 实现、历史源码或原测试实现作为产品基线；源码路径与提交只是证据索引，不能要求构建者再去原仓库补需求。已明确允许的固定 sing-box 内核/密码学实现、规则数据和第三方工具可按许可证复用，并在交付中分别说明，不能把复用部分宣称成独立重写成果。

原已发布实现的编译路径与从配方独立生成新实现分别记录。仅 check/pack/build 配方不需要初始化 generated/magicnet-android 或任何旧产品源码子模块。验证新实现后再按既有仓库布局集成并固定提交，不覆盖未保存的用户工作。

## 依赖使用合同

| 别名 | 职责 | 交付与集成验收 |
| --- | --- | --- |
| control | 特权 CLI、schema-1 JSON、MCP；递归包含 runtime | 三种入口改变同一份意图、同一运行时，错误和版本协商一致 |
| webui | 14 页 WebUI、编辑器、原生桥并发与国际化 | 只消费已协商控制面；不重复实现特权状态机；在成功、失败、未知和退出重进后准确显示 |
| delivery | Android 模块入口、组件安装、可信分发与更新 | 生成可安装 ZIP；升级保留配置，失败可恢复；staged 与 effective 版本区分 |
| quality | 设计、代码质量、性能证据的通用合同 | 作用于整个产品；是工程标准，不是运行库或额外业务功能；按其验收给出实际证据 |

这些组件最终组成一个 MagicNet 产品，不是要求六个常驻服务或六个可安装应用。跨组件接口可用进程、文件或库实现，但必须保留已经定义的外部行为。

## 必须成立的边界

只支持显式 tun|ebpf，默认 tun；不增加 auto，不恢复 TProxy、Redirect、netd ALLOW_MULTI、CA 注入或已删除 MITM/capture 路径。TUN 用 magicnet0，eBPF 用 capability/cgroup/TC 证据，禁止用 magicnet0 作为 eBPF 成功条件。配置意图、运行证据、事务阶段、资源所有权分开。

进程活着、API 返回成功、配置校验通过分别只能证明对应层，不能代替真实流量。支持包默认脱敏。用户订阅、SSID/BSSID、节点名、密钥和设备标识不得进入公共状态、MCP 自动资源或发布物。

## 实施与交付

先建立公开接口和验收夹具，再重建各依赖，最后集成为完整模块。实现写入 generated/ 的独立源码子模块；保留旧存储的兼容导入边界，不并行维护两个公共状态源。先推送已授权源码提交，再更新主仓库的固定 gitlink，不能把普通源码直接写入 generated/ 容器或只留下本地未发布的指针。
执行合适的本地检查，不为日常迭代触发远程 CI。正式构建、签名、制品发布及设备验收另行报告。未获授权不重启用户设备、不更改其运行订阅、不启用 MCP 或发起抓包。
正式构建从主仓库的固定源码 gitlink 取实现，发行物仍交付到 MagicNet；完整接口、权限、资产和失败语义见 delivery 的 RELEASE_CONTRACT.md。工作流配置完成不等于 Android 构建或公开发行完成。
最终交付实际实现、安装物与检查证据；只生成本配方或 build 提示词不算完成独立重建。

## 本包补充材料

- [BEHAVIOR.md](BEHAVIOR.md)
- [DEPENDENCIES.md](DEPENDENCIES.md)
- [LICENSE.md](LICENSE.md)
- [PERFORMANCE.md](PERFORMANCE.md)
- [PROVENANCE.md](PROVENANCE.md)
- [SOURCE_AUDIT.md](SOURCE_AUDIT.md)：本轮固定源码调用链、全产品保留覆盖、具体修正、证据层次和重建顺序。

- [VERIFICATION.md](VERIFICATION.md)：配方、实现与发行的实际检查结果。
- [FEEDBACK.md](FEEDBACK.md)：走查限制、Issue 来源与吸收的验收要求。
