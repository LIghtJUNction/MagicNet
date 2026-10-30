# 分发验收

| 场景 | 操作 | 结果 |
| --- | --- | --- |
| full、core+组件、旧版无 manifest、全复用 | 安装/升级 | 同一最终 runtime 文件与权限；full/复用不联网；保留订阅和用户配置 |
| staging 完整安装后真实 rename 到最终模块目录，含自有缓存/checkpoint/last-known-good 与外部自定义路径 | 晋升后启动检查、恢复和再升级 | 自有路径解析到最终位置，不依赖已消失 staging；恢复内容保留；外部路径意图不被误改，不能只在未移动的测试目录宣称通过 |
| MagicNet-core.zip、MagicNet.zip、magicnet_installer.zip | 比较摘要/模块身份，再分别安装升级 | 三者逐字节相同、ID 都为 MagicNet；更新同一模块，不出现外层 installer 模块、嵌套安装或重复核心下载 |
| 未变组件只改 WebUI、改变 ZIP 顺序/时间戳 | 构建 | 未变组件 identity 不变，更新流量不强制重下核心 |
| 字节篡改/私网重定向/TLS 错误/磁盘不足 | 下载 | 校验前不激活，规范错误，旧文件保留 |
| 每个替换点强杀、恢复时 I/O 失败 | 再次安装 | 先恢复 journal，不能普通成功；恢复证据留下但空间有界 |
| zip-slip、重复条目、头部歧义、unsafe link、错架构/身份 | 安装/更新 | manager 运行前拒绝，用户目录不被写 |
| 同 ID、冲突 ID、4096 budget、receipt 过期、并发 | module-update | 幂等/conflict/busy/耗尽明确，不遗忘重放历史 |
| 成功回执存在后新增 pending、update/disable/remove marker、坏 journal 或另一任务 recovery_required；再对照健康同意图重放 | 重放历史 request ID | 在受控 owner 内先检查当前阻断，旧成功不能绕过；不启动新 worker、不覆盖原 ledger/恢复证据、不删外部 pending，健康同意图不重复安装 |
| manager exit0 但 staged 不符、有效 pending/disable/remove | install | 拒绝或 staging_unverified，不能误报新版本已生效 |
| reboot 前后、CLI hash不符、manifest缺失 | status | reboot_required/unknown/effective version 准确 |
| 真 manager 部分失败/被杀 | 恢复 | recovery_required，不擅删他人 staging，不自动重启 |
| 迁移清单中增加状态路径，只修改“备份”或“恢复”其中一边；再测试显式模板排除项、权限、复制失败 | 首次安装/升级 | 备份与恢复由同一清单派生，配置重建例外单独可审阅；遗漏不能 exit 0 静默丢数据；失败退出非零并留下可恢复证据 |
| 真实发布 ZIP 与 support canary | 包检查 | 无 .env/本地状态/密钥/日志/旧 TProxy资产；with_ebpf 元数据和所有摘要一致 |
| 主仓库只更新配方/固定源码，手动 build/publish、错误源码 SHA、错更新地址、既有标签、版本未递增、缺失/篡改资产、Android 失败或跳过 | 按 RELEASE_CONTRACT 执行构建发布 | build 不发布；全部构建/验收使用同一 gitlink；只向 MagicNet 正式发行；不覆盖旧标签；任一必需门槛或服务端摘要失败都不公开草稿 |
| 主仓库根 module.yaml 缺失、description/icon 引用失效、身份/架构或 release.assetPattern 与交付不一致 | 配方迁移、分支合并后的目录检查及发布前复核 | 文件与引用资源受跟踪且可解析；身份 MagicNet、官方仓库和 MagicNet-full.zip 一致；任一缺失或不一致明确失败，源码子模块中单独存在 manifest 不能替代主仓库入口 |
| 上传后的草稿标签查询 404、无匹配草稿、多个同名草稿、非法 ID、服务端摘要不符 | 读取并公开草稿 | 唯一数字 release ID 可继续核对；缺失/歧义/非法 ID 或错误摘要均不能调用公开操作 |
| 构建与 Android/完整质量已通过，仅发布控制失败 | 独立恢复原草稿 | 验证原 run、源码与配方提交及不可变 artifact，重新核对完整字节与服务端资产后按原 ID 公开；任一构建/验收失败仍拒绝；不替换附件或旧标签，单独记录恢复结果 |

这些是分发合同，不是当前轮次的执行报告。各次构建、manager、发布及设备结果按固定提交分别记录于根 VERIFICATION.md；0.3.2 新增目录晋升、历史回执和模块目录要求在取得本轮证据前仍为未验证。
