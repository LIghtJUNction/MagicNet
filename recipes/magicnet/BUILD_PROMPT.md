# 重建 MagicNet（配方 0.3.1）

为 Android root 用户重建 MagicNet：从首次安装与订阅导入，到按应用、Wi-Fi、热点分流，再到节点、故障诊断和自动化控制。保留来源版本的完整用户行为，不能交付只有静态页面或包装命令的演示。

## 用户已确认的选择

- 语言由重建 Agent 根据 Android、特权边界、协议兼容与维护成本选择；没有必须保留 Rust、Shell、Go 或 Vue 的要求。可复用合规第三方实现，不要求重新发明加密协议。
- 保留全部功能及现有目标平台：生产设备为 Android root / arm64，支持 Magisk、KernelSU、APatch；WebUI 由模块管理器提供的 WebView/浏览器桥接运行。Linux 宿主与 x86_64 模拟器是开发环境，不是新的生产平台。
- 保留操作流程，重新设计视觉，避免通用 AI dashboard。不能因改版删除诊断、文件草稿、失败恢复或无障碍状态。
- 沿用现有语种：WebUI zh-CN/en/ru；安装向导和操作菜单保留已有中、英、俄、日、韩语言能力及各自回退。机器 token、命令参数、配置内容、日志不翻译。
- 测量并记录现有性能基线；性能预算未知，不能把基线直接宣布为承诺。见 PERFORMANCE.md。
- 项目和主仓库名称保持 MagicNet，不加 recipkg 后缀。配方为本体；generated/ 只作容器，实现放在独立的小写连字符源码仓库，以固定提交子模块接入 generated/<source-repository-name>/，仓库名与子目录名相同。本候选分支源码固定为 LIghtJUNction/magicnet-android@b22f9f280ddaf729da47078c13838a73e6d89294，实际重建输入、测试和产品版本见 VERIFICATION.md。main 的既有实现为 `b0bfe8b9f2fccdc4cbb46f5f0091a2d94694afc7`；历史基线 `0dca28dd984d82333707cbf4b222596934b4d847` 的完整 tree 与原仓库 v1.8.0 相同，后续包含订阅修复和跨仓库构建发布兼容。各分支跟踪自己的固定 gitlink 与 .gitmodules；源码与观察 checkout 均不是 Recipkg 依赖，不进入配方负载。原仓库历史标签保留发行来源，候选重建不等于正式发行或设备部署。
- 用户反馈与 Issue 转录见 FEEDBACK.md；M18–M29 保留原需求，M30–M39 新增多订阅、Encryption、可观测状态和重建交付验收。SOURCE_AUDIT.md 分开记录基线缺陷、当前源码修复和仍未知事项；配方合同或源码 main 更新都不等于 Android 版本已发布/部署或 #426 根因已确认。

Android 全产品最低版本及 WebView 最低版本仍未知。Java 网络策略桥以 API 26 为最低目标不等于整个产品保证支持 Android 8。不得从一台 Android 14 设备推导全版本兼容。

## 阅读范围

完整阅读本文件、BEHAVIOR.md、ACCEPTANCE.md、FEEDBACK.md、SOURCE_AUDIT.md、PERFORMANCE.md、PROVENANCE.md、DEPENDENCIES.md、LICENSE.md，以及四个依赖和所有递归依赖的全部 Markdown。归档内的依赖按 alias 展开，不能只读根入口。

本轮增加的具体合同为 control/SUBSCRIPTION_INTERFACE.md、runtime/SUBSCRIPTION_CONTRACT.md、webui/SUBSCRIPTION_FLOW.md、engine/VLESS_ENCRYPTION.md；这里的前缀是依赖职责简称，包名及实际位置由 RECIPE/LOCK 决定。依赖完整闭包仍是八包，不因补充合同新增常驻服务。

## 独立重建边界

新构建上下文只接收完整递归 Markdown 配方和明确允许的通用工具/外部资源。先在空实现目录构建，不读取、复制、调用旧 MagicNet 实现、历史源码或原测试实现作为产品基线；源码路径与提交只是证据索引，不能要求构建者再去原仓库补需求。已明确允许的固定 sing-box 内核/密码学实现、规则数据和第三方工具可按许可证复用，并在交付中分别说明，不能把复用部分宣称成独立重写成果。

原已发布实现的编译路径与从配方独立生成新实现分别记录。仅 check/pack/build 配方不需要初始化 generated/magicnet-android 或任何旧产品源码子模块。验证新实现后再按既有仓库布局集成并固定提交，不覆盖未保存的用户工作。

### 本轮可独立取得的外部材料与职责

- 允许复用规则数据：`https://github.com/LIghtJUNction/MagicNetRules.git`，固定提交 `f3335f9420d07b8c50b26488df2a9492da6bbb44`。仅将该版本的规则数据、必要的描述/许可证作为不可变分类素材；记录取得的路径、摘要及许可，不能借此引入旧 MagicNet 管理实现。规则发布包与源码 revision 的对应关系未经证实时不得猜测。
- `MagicSingBox@e4ecf47499c35bf25e10d04257a21a4f7975ebad` 是历史默认模板的观察来源。新默认配置依据 policy 的完整行为与 POLICY_INVENTORY 生成；不要求构建者访问或复制该历史模板仓库。
- sing-box 固定复用边界由 engine/BUILD_PROMPT 与 VLESS_ENCRYPTION 决定；其余可分发第三方资产按 delivery/EXTERNAL_ASSETS 固定并核验。复用组件与本轮独立实现分别记录。
- 本轮构建者在空实现目录交付完整源码、安装物、依赖与检查记录。主 agent 在交付后负责将源码提交到既有独立仓库、更新主仓库 gitlink，并检查原主仓库的技能子模块及 topics。历史六个嵌套子模块和旧 tree 不是新实现必须复制的目录/技术栈；旧 tree 相同只用于判断历史测试证据是否仍适用。
- runtime SUB-007 是节点身份、可选去重和引用重映射的完整目标。跨 tag 的等价节点可以保留；若选择合并，必须忽略显示名并保留可证明的全部来源归属。同名冲突引用在逐来源身份明确时随稳定重命名一起重写，只有真正歧义或缺失时拒绝。SOURCE_AUDIT 中当前未发行修复的限制不是重建目标的上限。

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

安装器的暂存目录会在管理器提交时迁移，模块自有规则、cache、Tailscale 路径及其 checkpoint/LKG 必须在迁移后继续有效；自定义外部路径保持不变。网络策略失败重试和回滚必须保留最初全部共享 UID 身份与策略及逐项进度。更新请求的历史成功回执也必须先经过当前 pending、恢复 journal、禁用/更新 marker 与所有权门槛，不能绕过当前恢复需求。详细反例纳入 M11–M13；这些是本轮独立验收补充，实际冻结输入不作事后替换。

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
