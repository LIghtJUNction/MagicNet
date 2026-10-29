# Android 网络运行时

依赖 engine 提供 sing-box/check/Clash API/TUN/eBPF，依赖 policy 提供默认配置、selector 和本地规则数据。先结构化生成候选配置，再 sing-box check，最后在串行、有截止时间的生命周期事务里生效。集成验收：两种数据面、业务策略、订阅来源、API 与公共状态一致，失败恢复旧有效状态。

必须完整阅读 [SUBSCRIPTION_CONTRACT.md](SUBSCRIPTION_CONTRACT.md) 与 [ACCEPTANCE.md](ACCEPTANCE.md)。runtime 0.1.1 从固定 v1.8.0 源码补齐订阅端到端合同，包含 #426 多源反馈、URL 身份统一、同名不同节点、逐源转换完整性和批次诊断；标注“重建修正”的条目是本轮目标，不表示旧实现已修复。

## 生命周期与所有权

启动、ensure、停止、重启、supervisor、开机入口与卸载使用同一归属模型。PID 不是充分身份证据，必须核对可执行文件/命令/启动身份与模块所有权；未知不杀进程。先优雅停止，超时按所有权安全升级，记录失败；无关进程/iptables/路由不能被 flush。
config apply 对有效配置和规则指纹无变化时不重启；transparent apply 显式重建当前数据面。状态读取无写；写生命周期完成 publish/reconcile。
周期 hotspot reconcile 使用非阻塞争锁，繁忙时无副作用跳过，不发布当前 owner 的状态；I/O/锁错误仍报告失败。实际尝试后，无论成功或失败都发布新的规范化观测。显式 service start|stop|restart 的锁获取有界等待，保留 startup/disabled/owner/事务恢复检查；参考实现只把服务操作锁预算从 2 秒扩为 10 秒，其他配置操作仍为 2 秒，该预算不代表完整操作耗时。
模式切换只收 tun|ebpf，先校验候选、记录旧配置和资源、停自有核心、启动并验证目标，再提交。任一步失败可回滚字节与 owned 资源；中断 journal 保留并可恢复。不声称多个 OS 资源更新同时原子。

## 订阅

URL 来源每行一个公网 HTTPS，最多五个；与本地文件来源互斥。完整定义和来源证据以 SUBSCRIPTION_CONTRACT.md 的 SUB-001–SUB-015 为准；所有入口统一规范化、去重与缓存身份，同一主机的不同 path/query 不能误并。支持 sing-box JSON、Clash/Mihomo YAML、base64 与分享链接/文本；原生 VLESS/VMess/Trojan/SS/SOCKS/Hysteria2/AnyTLS/TUIC；复杂 TLS/transport、别名、块标量与转义需要完整转换器，缺转换器明确拒绝，不猜内容。VLESS encryption 必须遵循 engine 的完整字段合同，不能静默剥离，也不能用短字段限制截断长密钥。
下载每跳验证 URL/TLS、公网解析地址和重定向，拒绝本机/私网/metadata 等目标及降级，防 DNS rebinding。用受控路径，不读用户 curl 配置或危险 loader/proxy 环境。
候选来源、完整 JSON 节点数组、合并配置、selector 选择、用量和 journal 同属一事务。jq 结构化合并，禁止用 AWK/正则改 JSON。空/不合格组 fail-closed；节点命名碰撞不覆盖受控服务 selector。
逐源转换完整性先于跨源合并：同名不同端点保留，真正重复可合并并保留来源；不能用去重后的总数与去重前原始条数比较而误拒多源，也不能为避免拒绝而放过丢字段。任一来源获取失败且无同身份缓存，或无法完整转换，整批保留旧代。新增批次状态采用 control 的 SUBSCRIPTION_INTERFACE.md / subscription_batch_v1，区分本次候选与旧已保存配置，不能只报旧 configured_count。
VMess WebSocket 独立保留 server、Host、SNI、path；SOCKS 用户名/密码同时有效。失败/中断保留旧源、配置、选择及恢复证据。URL→本地→URL 同样原子；本地内容不上传公共服务。
原生节点计数与构建须显式处理单节点解析失败，在 POSIX sh/dash、Bash 和 Android BusyBox 下保持相同失败语义；不能因 set -e 提前退出而把已知的语义不完整误报成计数设施错误，也不能让其他有效节点掩盖不完整来源。
URL 规范化清单、来源索引或缓存映射写入失败时立即停止该批次；先退出读取循环，再统一清理本次临时文件，保留旧有效配置，不能继续提交部分来源。
结构化 jq 表达式至少覆盖 CI 的 jq 1.7.1 与当前开发机版本；reduce 结果继续绑定变量时显式括起完整表达式，避免只在新版解释器中可解析而使整批合并失败。
周期 off/12/24/48/72 小时，单 refresh owner；超时、信号、并发 updater 和旧 PID 不生成重复驻留任务。订阅刷新不刷新上游业务分类数据。

## 应用、Wi-Fi、热点和 DNS

包身份在当前 Android 所有用户中解析，支持共享 UID、卸载重装；proxy/direct/bypass 语义按根行为保留。bypass 同时从两种数据面和 DNS 捕获排除；netd UID 0 代发 DNS 的设备保守保留 bypass 边界，不能谎称所有 DNS 必被代理。
Wi-Fi 读取失败不是空名单，64 KiB 有界并验证普通文件；非法/过大编辑保留旧文件且不切模式。后台轮询状态改变主动发布。
热点 TUN 按已确认下游配置 owned IPv4 路由，代理时保存并关闭 tether offload；eBPF hybrid 仅挂真实下游 TC，无下游 pending。disable、核心停止、卸载恢复原设置，仅删除 journal 里能证明是自己创建的资源。
物理出口 DNS/DoT 的 53/853 保护默认关闭，只有显式 MAGIC_DNS_LEAK_GUARD=1 且规则成功安装才生效，且须与旁路语义一致；浏览器 DoH、外部 VPN 和 OEM 通路另有边界。捕获接口按实际 route 观察，不写死 wlan0。
网络 prefer_ipv4/prefer_ipv6/ipv4_only、MTU 1280–1500、UDP 1m/3m/5m/10m/15m/30m；配置/实际值分层。TUN CIDR 要为派生 DNS 地址留空间，172.20.0.1/30 合法、.2/.3 不合法；fd12::2/126 合法、::3 不合法。默认值不证明与另一 VPN 无冲突。

## Tailscale 与 WARP

userspace endpoint system_interface=false，不创建第二个 Android TUN；显式用户配置后才启用。auth_key 提取到 0600 私密 sidecar，只在核心读取时注入，随后从可编辑配置移除，支持包排除。
路由仅把实际 peers/accepted routes/MagicDNS 引向 Tailnet，不能把整个 100.64.0.0/10 与 fd7a:115c:a1e0::/48 一概当成 Tailnet；在 LAN 前用 preferred_by:tailscale 和显式 ts.net DNS。
disable 保留身份与可恢复设置；enable 检查 revision；logout 先确认核心停止，删自有身份与 key，不删自定义目录或云账号。失败保持 disabled/logout-pending，不自动重新登录；原本停止的核心保持停止。WARP 导入、启停与 rule/global 按显式控制，不覆盖无关 endpoint。

## Android 网络限制恢复

只经已存在 provider 的能力证据识别 AOSP/Oplus 等支持情况，不按品牌猜成功。status/inspect/check 只读；repair/reapply/rollback 必须使用完整身份/原策略摘要候选并显式 --confirm。
写前重新读取全部共享包/用户/策略；私密 0700 目录和 0600 journal 先原子持久化并 sync，再调用 setter/readback；最多 128 身份、每 record 64 KiB。prepared/applied/rollback_prepared/rolled_back 区分；超时和响应丢失保留证据。相同重复无副作用，第三方变更拒绝覆盖；限制回来必须新的显式 reapply，不后台反复清除。
不关闭厂商控制器，不放松 SELinux，不加 ALLOW_MULTI；API 配置回读成功不是 DNS/Play 成功。
