# 分发验收

| 场景 | 操作 | 结果 |
| --- | --- | --- |
| full、core+组件、旧版无 manifest、全复用 | 安装/升级 | 同一最终 runtime 文件与权限；full/复用不联网；保留订阅和用户配置 |
| 未变组件只改 WebUI、改变 ZIP 顺序/时间戳 | 构建 | 未变组件 identity 不变，更新流量不强制重下核心 |
| 字节篡改/私网重定向/TLS 错误/磁盘不足 | 下载 | 校验前不激活，规范错误，旧文件保留 |
| 每个替换点强杀、恢复时 I/O 失败 | 再次安装 | 先恢复 journal，不能普通成功；恢复证据留下但空间有界 |
| zip-slip、重复条目、头部歧义、unsafe link、错架构/身份 | 安装/更新 | manager 运行前拒绝，用户目录不被写 |
| 同 ID、冲突 ID、4096 budget、receipt 过期、并发 | module-update | 幂等/conflict/busy/耗尽明确，不遗忘重放历史 |
| manager exit0 但 staged 不符、有效 pending/disable/remove | install | 拒绝或 staging_unverified，不能误报新版本已生效 |
| reboot 前后、CLI hash不符、manifest缺失 | status | reboot_required/unknown/effective version 准确 |
| 真 manager 部分失败/被杀 | 恢复 | recovery_required，不擅删他人 staging，不自动重启 |
| 真实发布 ZIP 与 support canary | 包检查 | 无 .env/本地状态/密钥/日志/旧 TProxy资产；with_ebpf 元数据和所有摘要一致 |

当前未新构建完整模块、未安装设备、未验证 manager 更新或发布；本次仅对配方归档做结构检查。
