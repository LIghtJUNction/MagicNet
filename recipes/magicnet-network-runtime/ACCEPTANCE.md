# 运行时验收

未来实现必须运行，当前未做新实现验收。

| 输入/故障 | 操作 | 预期 |
| --- | --- | --- |
| 可用 HTTPS、私网跳转、DNS rebinding、TLS 错误、六个来源、复杂无转换器 YAML | 保存订阅 | 只有合法候选生效；拒绝项保留原来源、字节、选择和进程 |
| 各分享协议，WS server/Host/SNI/path 不同，缺 SOCKS 密码 | 导入并检查候选 | 正确字段分别保留；缺认证失败；命名不覆盖受控 selector |
| 信号中断每个激活阶段、并发更新、旧 owner、停止时 updater 不退出 | 重启/恢复 | 单 owner；有界停止；journal 可恢复；失败状态不丢 |
| tun/ebpf、无下游/新下游/下游消失、TC 附着失败、核心退出 | 切换并观察 | configured/effective/pending 分明，回滚准确，无混合成功 |
| 多用户/共享 UID/卸载重装、UID 枚举失败 | 应用三种策略 | 真实身份解析；未知不当成功；bypass DNS 同步；不删除他人规则 |
| 64 KiB 名单边界/坏编码/非法/读取失败，blacklist/whitelist | 编辑和轮询 | 失败保留旧状态，成功模式与名单语义一致并主动发布 |
| 原 offload 为不同值、外部规则与自有规则并存 | 热点启停/卸载 | 恢复精确原值，仅删已证明 owned 的项 |
| 相同配置、仅无关文件修改、规则内容修改 | config apply | 前两者不重启，真正有效变化校验后才重启 |
| 非 Tailnet CGNAT、暂停/恢复/登出、自定义状态目录、失败停止 | Tailscale 操作 | 非 Tailnet 正常 LAN 处理；不删外部目录/账号；失败不重新启用 |
| missing provider、过期候选、限制被外部改写、setter 忽略写入、崩溃 | network-access 流程 | unsupported/conflict/readback error/持久恢复准确；零自动清除 |

设备验收还需真实 App UID 的 DNS、前后台连接、IPv4/IPv6、网络切换、热点客户端和厂商网络栈；本机 mock 不覆盖这些。
