# 重建 MagicNet

为 Android root 用户重建 MagicNet：从首次安装与订阅导入，到按应用、Wi-Fi、热点分流，再到节点、故障诊断和自动化控制。保留来源版本的完整用户行为，不能交付只有静态页面或包装命令的演示。

## 用户已确认的选择

- 语言由重建 Agent 根据 Android、特权边界、协议兼容与维护成本选择；没有必须保留 Rust、Shell、Go 或 Vue 的要求。可复用合规第三方实现，不要求重新发明加密协议。
- 保留全部功能及现有目标平台：生产设备为 Android root / arm64，支持 Magisk、KernelSU、APatch；WebUI 由模块管理器提供的 WebView/浏览器桥接运行。Linux 宿主与 x86_64 模拟器是开发环境，不是新的生产平台。
- 保留操作流程，重新设计视觉，避免通用 AI dashboard。不能因改版删除诊断、文件草稿、失败恢复或无障碍状态。
- 沿用现有语种：WebUI zh-CN/en/ru；安装向导和操作菜单保留已有中、英、俄、日、韩语言能力及各自回退。机器 token、命令参数、配置内容、日志不翻译。
- 测量并记录现有性能基线；性能预算未知，不能把基线直接宣布为承诺。见 PERFORMANCE.md。
- 项目和仓库名称保持 MagicNet，不加 recipkg 后缀。配方为本体；generated/ 中的源码是可重新生成的本地产物，不是配方依赖。本轮迁移不独立重建实现。

Android 全产品最低版本及 WebView 最低版本仍未知。Java 网络策略桥以 API 26 为最低目标不等于整个产品保证支持 Android 8。不得从一台 Android 14 设备推导全版本兼容。

## 阅读范围

完整阅读本文件、BEHAVIOR.md、ACCEPTANCE.md、PERFORMANCE.md、PROVENANCE.md、DEPENDENCIES.md、LICENSE.md，以及四个依赖的全部 Markdown。归档内的依赖按 alias 展开，不能只读根入口。

## 依赖使用合同

| 别名 | 职责 | 交付与集成验收 |
| --- | --- | --- |
| control | 特权 CLI、schema-1 JSON、MCP；递归包含 runtime | 三种入口改变同一份意图、同一运行时，错误和版本协商一致 |
| webui | 13 页 WebUI、编辑器、原生桥并发与国际化 | 只消费已协商控制面；不重复实现特权状态机；在成功、失败、未知和退出重进后准确显示 |
| delivery | Android 模块入口、组件安装、可信分发与更新 | 生成可安装 ZIP；升级保留配置，失败可恢复；staged 与 effective 版本区分 |
| quality | 设计、代码质量、性能证据的通用合同 | 作用于整个产品；是工程标准，不是运行库或额外业务功能；按其验收给出实际证据 |

这些组件最终组成一个 MagicNet 产品，不是要求六个常驻服务或六个可安装应用。跨组件接口可用进程、文件或库实现，但必须保留已经定义的外部行为。

## 必须成立的边界

只支持显式 tun|ebpf，默认 tun；不增加 auto，不恢复 TProxy、Redirect、netd ALLOW_MULTI、CA 注入或已删除 MITM/capture 路径。TUN 用 magicnet0，eBPF 用 capability/cgroup/TC 证据，禁止用 magicnet0 作为 eBPF 成功条件。配置意图、运行证据、事务阶段、资源所有权分开。

进程活着、API 返回成功、配置校验通过分别只能证明对应层，不能代替真实流量。支持包默认脱敏。用户订阅、SSID/BSSID、节点名、密钥和设备标识不得进入公共状态、MCP 自动资源或发布物。

## 实施与交付

先建立公开接口和验收夹具，再重建各依赖，最后集成为完整模块。实现写入 generated/<implementation-name>/；保留旧存储的兼容导入边界，不并行维护两个公共状态源。
执行合适的本地检查，不为日常迭代触发远程 CI。正式构建、签名、制品发布及设备验收另行报告。未获授权不重启用户设备、不更改其运行订阅、不启用 MCP 或发起抓包。
最终交付实际实现、安装物与检查证据；只生成本配方或 build 提示词不算完成独立重建。

## 本包补充材料

- [BEHAVIOR.md](BEHAVIOR.md)
- [DEPENDENCIES.md](DEPENDENCIES.md)
- [LICENSE.md](LICENSE.md)
- [PERFORMANCE.md](PERFORMANCE.md)
- [PROVENANCE.md](PROVENANCE.md)

- [VERIFICATION.md](VERIFICATION.md)：本次材料交付的实际检查结果。
