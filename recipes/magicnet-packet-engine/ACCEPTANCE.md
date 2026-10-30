# 引擎验收

1. 真实 Android arm64 二进制 version 元数据含审核 revision 与 with_ebpf；同一二进制合法 TUN/eBPF 配置 check 成功，缺关键能力/缺出站失败。
2. TUN 启动创建 magicnet0，停止只撤销自有资源；Android VPN slot 未占用。应用绕过与 DNS 同时验证。
3. eBPF local/hybrid 只作用于目标 UID/cgroup；重复 backend、自身 socket、共享 UID、include/exclude、TCP-only/UDP-only、IPv4-mapped IPv6 逐项验证。
4. hybrid 下游空→出现→消失→恢复：local 继续，shared pending/attached 正确；shared-only 无接口不假 ready；TC 检查有实际程序归属。
5. dns_mode 三值乘 local/shared，含私网 DNS、排除主体、协议禁用和 DHCP。结果符合优先级，不用 DoH 误作明文 DNS。
6. FakeIP 与 bypass 重叠、危险范围、分片/token 来源、防回环和热更新的现有流行为有真实数据包用例。
7. 缺 cgroup/TC/helper、已知未修复内核组合安全失败；capability probe 成功但实际挂载失败时，公共状态不能 ready。
8. TLS/UDP/QUIC、支持的分享协议、DNS、Clash selector/urltest、userspace Tailscale 实际端到端通信验证；仅 check 成功不算通信通过。
9. hotspot 有真实客户端时验证双栈 TCP/UDP 返回路径；没有客户端全局 IPv6 时将 IPv6 结论标记为未覆盖。`route_status=ready` 不能由规则存在单独推导。
10. 对同一锁定核心比较 mixed 与 Go/default TUN stack，覆盖 hotspot 回程、DNS、IPv4/IPv6、应用策略、长连接、CPU/RSS/延迟；旧栈与新栈结果可追溯，所有目标平台通过前不更改生产默认。该 stack 维度独立于 tun|ebpf 模式。
11. 执行 VLESS_ENCRYPTION.md 的 VE-005 矩阵：普通/none 回归、三种 appearance、两种 RTT、32/1184 字节有效测试公钥、多 key/padding、非法值与长字段、各导入/编辑/刷新/恢复入口，均不得丢字段后假成功。真实核心 check、受控服务器互通和取消/超时资源分别记录；仅原生解析探针通过不算协议通过。

12. 执行 CORE_LIFECYCLE.md 的 CORE-A01–A06：握手错误回调、绑定/关闭顺序及竞态、重复流的资源回收、固定参数内存测量、上游 WireGuard 完整差异与 AWG 保留、生产 tags 和 Android arm64 构建。每项绑定实际候选 SHA，并分开记录宿主与设备结果。

本次迁移未重新编译或运行 Android 数据面；这些场景均未验证。固定 fork 可用作合法实现前提，不代表已由配方独立重建。
