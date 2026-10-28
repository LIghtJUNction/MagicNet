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
| hotspot reconcile 持锁期间发起 service start/stop/restart，含核心已运行的 no-op | 并发生命周期 | 周期 reconcile try-lock 失败则无副作用跳过；用户动作得到有界等待/规范 busy 结果，不被误报为核心失败 |
| 热点拓扑首次变化、应用耗时超过一次 UI 请求、读取状态失败/晚返回 | WebUI 生命周期与刷新 | 后台阶段可观察；旧 ready 不复用；调用端超时不释放设备 owner；非冲突读操作仍可用 |
| 连续五轮核心启停、清理中断、PID/owner unknown | stop/start 恢复 | 优雅关闭先给清理机会；只回收拥有的 tun/cgroup/TC/路由资源；失败保留证据且明确不完整 |
| 下游分别具备/不具备全局 IPv6，热点代理与直连 | 客户端回程 | 实际客户端双栈结果分开记录；健康状态不能覆盖失败回程；没有 v6 前提则标未覆盖 |
| Play/GMS/GSF 真实应用请求、DNS 与系统 per-UID 策略变化 | OEM 网络验收 | API readback、root curl 和 TUN 接口存在均非应用成功证明；不同厂商逐项记录，不应用全局直连绕过 |
| 活动 config 空/损坏、last-known-good 无效、事务每个阶段中断 | 配置恢复 | 先验证独立备份；无有效基线则拒绝激活；保留 journal 与用户配置供重试 |
| HTTPS 订阅超时、DNS 错误、解析失败、用户取消后重试 | 下载诊断 | 阶段错误可区分，状态不含 URL/响应正文；无第二个 updater owner，重试不丢已有有效来源 |
| 相同配置、仅无关文件修改、规则内容修改 | config apply | 前两者不重启，真正有效变化校验后才重启 |
| 非 Tailnet CGNAT、暂停/恢复/登出、自定义状态目录、失败停止 | Tailscale 操作 | 非 Tailnet 正常 LAN 处理；不删外部目录/账号；失败不重新启用 |
| missing provider、过期候选、限制被外部改写、setter 忽略写入、崩溃 | network-access 流程 | unsupported/conflict/readback error/持久恢复准确；零自动清除 |

设备验收还需真实 App UID 的 DNS、前后台连接、IPv4/IPv6、网络切换、热点客户端和厂商网络栈；Google Play/GMS、Tailscale TSMP/业务连接与 no-op 生命周期锁争用都需要真机覆盖。本机 mock 不覆盖这些。
