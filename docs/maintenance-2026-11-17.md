# MagicNet 2026-11-17 维护验收

## 发布身份

目标版本为 v1.8.9，versionCode 10617。维护源码固定为 c5a1368639da929ae619a5a74444dc79e657618a。正式发布流程尚待本轮运行完成；公开结果、安装资产与稳定索引在完成后回读并记录。

## 修复原因

Android 构建失败来自 zlib 旧下载端点返回 HTTP 200 的 HTML 页面，原 SHA-256 门禁正确拒绝。固定来源现为官方 GitHub Release；损坏缓存重新获取，错误内容保持失败。curl、OpenSSL、zlib、CA 及验收共用固定输入。

此前发布已完成构建、Android 和资产门禁，末端在创建草稿后重新列举时未发现该草稿。发布器现直接使用创建响应的数字 ID，保留原有身份及资产验证。失败证据：[Android 构建](https://github.com/LIghtJUNction/magicnet-android/actions/runs/43916363849/job/133471990323)、[发布末端](https://github.com/LIghtJUNction/MagicNet/actions/runs/43916818151/job/133507075123)。

本轮发布运行 [43931861481](https://github.com/LIghtJUNction/MagicNet/actions/runs/43931861481/job/133527040021) 在准备 x86_64 安装载荷时发现 eCapture fixture 仍固定 2.5.2，与生产 2.11.0 不一致。正式包内容与安装检查已通过，但该 Android 前置失败使发布保持阻断。修复同步官方 amd64 资产及摘要，并增加早期同版、失配拒绝、坏摘要拒绝回归；同步消除 AVD yq 的重复版本来源和 WebUI Zashboard 旧下载候选。

## 变更与固定输入

详细版本与用户变化见 [v1.8.9 说明](releases/v1.8.9.md)，完整固定摘要见 [EXTERNAL_ASSETS](../recipes/magicnet-module-delivery/EXTERNAL_ASSETS.md)。规则安装减少一次重复比较；TLS/GoTLS 显式使用 hook 文本来源。统一 ELF 结构校验替代 file/readelf 的文字解析，接受合格静态 PIE 并拒绝错误架构、GNU 解释器及普通共享库。Rust 与前端锁文件的净删行主要来自自动依赖去重，不作为运行性能提升结论。

## 本地验证

| 范围 | 结果 |
| --- | --- |
| 发布计划 | 42 项通过，包含列表滞后时使用创建响应完成发布 |
| 规则与下载 | 20 + 6 项通过；实际核验 116 个 SRS；默认模板安装 54 个规则和 54 个 marker |
| WebUI | 392 项通过，类型检查与构建通过，npm audit 0 漏洞，npm/Bun 冻结锁一致 |
| Rust 依赖阶段 | 873 单元 + 68 集成通过，1 个既有 ignored，Clippy -D warnings 通过 |
| eCapture 兼容 | 9 项通过，模拟 CLI 参数与无效输入零副作用 |
| curl 与模拟器合同 | 13 + 114 项通过 |
| 内嵌 CA | 实际官方 CA 的 4 项定向验证通过 |
| Android ELF | 14 项通过，含真实官方 eCapture static PIE；现有 CLI 符号链接及 ARM64 工具兼容通过 |
| AVD 固定值同步 | 33 项 workflow 回归通过；完整 x86_64 载荷准备脚本实跑成功，eCapture 2.11.0 与 Proxylink 均通过架构检查；yq 4.54.3 实际 Go 构建成功 |
| Dashboard 下载候选 | 3.30.0 普通与无字体 ZIP 实物 SHA-256/完整性通过；WebUI 类型检查与私密载荷合同检查通过 |
| 发行完整性 | 外部资产实物摘要匹配；既有归档、路径、损坏输入负例与组件检查通过 |

宿主完整 TLS proof 测试使用开发机系统 curl 时，既有解析器拒绝系统 zlib-ng 版本后缀；本轮没有修改该 Android 版本解析规则。正式 Ubuntu/Android 流程使用锁定的纯数字版本构建，完整结果以本轮发布 CI 为准。

本轮未在物理手机安装新包、变更订阅、重启服务或调整网络。模拟器证据和实际手机验收分别记录。eCapture 官方 Android 资产未提供 nspr/nss；本轮新增测试覆盖参数转发和 TLS/GoTLS 兼容，不声称新增 Android nspr 能力。

## 正式 CI 与资产

本轮发布完成后，记录不可变快照、源码 SHA、CI 链接、Release URL、附件数量及摘要、在线/离线安装包和稳定 update.json 回读结果。
