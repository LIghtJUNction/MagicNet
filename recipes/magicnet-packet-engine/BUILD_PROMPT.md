# TUN 与 eBPF 引擎

重建满足 MagicNet 的 sing-box 兼容数据面。生产 Android arm64 保留 tun 与 with_ebpf；Linux amd64 用于校验/主机测试。模块只允许 tun|ebpf；内部 eBPF mode local/shared/hybrid 是其子配置，不是第三种模块模式。
来源 fork 为 LIghtJUNction/sing-box，完整 revision 871b7a3440cd9c850f1b09ef3b4ada9babb4384b；父仓库 sing-box.version 写 1.15.0-alpha.10，但 git describe 为 v1.14.2-386-g871b7a34，二者不是同一身份字段，重建应校验提交及产物元数据，不能只看版本名。
可以按其实际许可证复用固定 fork/上游协议实现；源码是明确外部构建前提，不藏进配方，不作为无配方的依赖。需要网络/上游许可时显式记录。语言自由不意味着要手写未经验证的密码学。

## 兼容接口

提供 sing-box run、check、version 及本地 Clash API 所需配置/API；支持混合入站 127.0.0.1:7892、controller 默认 127.0.0.1:9090、TUN、selector/urltest/direct/block、DNS 与规则集、Tailscale/WireGuard endpoint 和订阅原生协议。
配置失败、未知字段/缺失出站/空不合格代理组不能假成功；管理器激活前执行真实 check。配置能力与编译 tags 写入可检验元数据。

## TUN

root 管理 magicnet0，不调用 Android VpnService.establish，不占 VPN slot。只捕获应由本模块管理的流量；应用 bypass 同时退出 DNS 捕获。管理自己创建的路由和规则，不清除其他 VPN/OEM 的规则。
保留 IPv4/IPv6、MTU、DNS 端口、内核路由/应用策略集成；不能用“tun 存在”推断 API 与出站网络成功。

## eBPF inbound

JSON type=ebpf。支持 network tcp/udp、udp_timeout 默认 5m、bypass_rule_set；local/shared/hybrid，其中引擎默认 local，MagicNet materializer 默认 hybrid。
local 支持 cgroup_path、ipv6、bypass_private_address、include/exclude UID/range、Android user、package；exclude 优先，存在 include 时其他主体绕过。包启动时解析 UID，共享 UID 无法区分；系统 resolver/下载器/isolated UID 代发流量的边界必须说明。
shared 支持接口、独立 ipv6/private bypass、来源 CIDR/MAC include/exclude、TC priority。仅确认的下游接口挂 ingress/egress，非 lo/上游/L3-only；不会创建 DHCP/NAT/RA/热点。
hybrid 可无下游，local 工作，shared pending；shared-only 无接口拒绝。不在首个真实接口出现前冒充 TC attached。接口出现/消失时维护 attachment，短暂消失可以保留 backend，状态准确。
每个 Box 最多一个 local/hybrid backend，自己创建 socket 通过该 Box 的 cookie 绕过，不能进程全局串扰或自环。

两平面的 dns_mode 都支持 hijack/respect_policy/off，默认 respect_policy：
- hijack：53 拦截在主体/来源和目的绕过前；
- respect_policy：尊重 UID/包或来源策略，但选中主体的 DNS 不受私网/目的绕过而逃逸；
- off：用户策略前放过 53。
自身防回环、协议开关、DHCP/报文有效性、禁用该平面 IPv6 等正确性门控始终优先。只处理启用协议的 53，不声称能识别 DoH/DoT。
FakeIP 的地址范围在私网/规则集 bypass 前捕获，但主体选择、自身防回环、本地真实地址等安全门控仍优先；危险范围冲突启动拒绝。规则集只提取目的 CIDR，域名/端口不在 BPF 中求值；更新 map，不篡改已有流既定选择。
shared 真实 IPv4/IPv6 非原子分片按 best effort 原样绕过；egress 内部 token 来源碎片丢弃，防止内部地址泄漏；IPv6 atomic fragment 正常解析。

## 能力与风险边界

要求 BPF_SYSCALL，local/hybrid 要 cgroup v2/CGroup BPF，shared/hybrid 要 scheduler/TC/clsact/BPF。IPv6 功能需要 IPv6。JIT 是性能优化；BTF、CO-RE、BPF_LSM、STREAM_PARSER 不是本入站通用必需项。按运行探测而非内核版本猜能力，厂商可能 backport。
来源文档标明 Linux 6.6.0–6.6.46 的 LPM trie 更新风险；涉及 UID/来源 CIDR/bypass rule set 的策略需 6.6.47 或相应修复，已知不安全组合应拒绝而非冒险。其他厂商能力未知就报告未知。
内部 tools ebpf status --mode ... --json 只做能力探测；模块 public 诊断为 cli transparent status/health。实际 readiness 必须检查当前受控进程的 cgroup/TC，而不是仅成功加载探针。
