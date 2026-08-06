# MagicNet 当前架构

文件名为兼容已有链接保留。这里描述已经运行的架构，不是未来路线图：MagicNet 只有 `sing-box` + `magicnet0` TUN 一条透明数据面，不包含 eBPF、TProxy 或自动切换到其他透明模式的路径。

## 数据面

```text
Android 应用 / 已进入内核转发的热点流量
                    │
                    ▼
          sing-box magicnet0 TUN
                    │
          ┌─────────┴─────────┐
          │ DNS 与规则匹配    │
          │ 域名 / IP / UID   │
          │ LAN / 热点 / 应用 │
          └─────────┬─────────┘
                    ▼
       selector / urltest / direct / block
                    │
                    ▼
         物理网络或显式 userspace endpoint
```

设备应用包由 root 管理的 TUN 自动路由进入 sing-box。MagicNet 不调用 Android 应用的 `VpnService.establish()`，因此不会占用系统 VPN slot。`Bypass TUN` UID 是明确例外：它们同时绕过 TUN 和 MagicNet DNS 捕获，回到原生网络或外部 VPN 的路径。

热点仍由 Android/OEM tethering 完成 DHCP、NAT 与转发。选择热点 Proxy 时，MagicNet 暂时关闭 tether 硬件卸载，使转发包有机会进入 `magicnet0`，再由 `hotspot` selector 决定 Direct 或 Proxy；退出 Proxy 或卸载会恢复原值。

## 控制面

CLI 是稳定的设备控制合同，WebUI、MagicBox 和 MCP 都复用相同能力：

- 订阅与配置：构造候选内容，执行解析和 `sing-box check`，原子激活。
- 节点与 selector：读取 sing-box API，保存选择并在更新后重放。
- 应用、Wi-Fi、热点和网络策略：更新模块管理的配置并触发受控应用。
- 健康与支持：汇总进程、TUN、DNS、路由、订阅、selector 和日志证据。

MCP 是可选远程控制面，默认关闭且独立 secret 认证；它不改变 CLI 的权限边界。

## 状态面

- `.config/`：用户选择和持久配置，包括当前订阅来源、应用/Wi-Fi/网络策略与 MCP endpoint。
- `.state/`：可重建运行状态、事务 journal、selector 选择、UID 解析结果和 supervisor PID。
- `.log/`：服务、订阅和 MCP 的轮转日志。
- `bin/`：发布包运行时；模块根 `cli` 保持到 `bin/magicnet-cli` 的兼容入口。

URL 与本地订阅来源互斥激活。更新事务保留上一个有效配置与来源，候选验证失败时回滚；中断后的 journal 会在下一次更新中协调恢复。

## 故障隔离与不变量

- 透明模式固定为 TUN；不存在 eBPF/cgroup/TC、TProxy 或 `auto` promote 的第二套状态机。
- 候选配置通过结构校验、节点校验和 `sing-box check` 后才能替换运行配置。
- 代理节点为空或服务专用组没有合格节点时，相关 selector fail-closed，不静默选择未知出口。
- 应用包名在每次应用策略时按 Android 用户解析 UID，避免只按主用户包名产生错配。
- 核心停止时清理模块管理的透明/DNS 规则；重启只读取已经验证的配置。
- 热点硬件卸载和一次性 Tailscale auth key 都有明确保存、恢复或擦除生命周期。

这些边界换取的是较少的内核兼容面和更清晰的故障定位。MagicNet 对标同类产品的用户结果——订阅、节点、分应用、Wi-Fi、热点和自动化——但不复制 cgroup/TC eBPF 的分片、Map、厂商 offload 与 hook 兼容风险。
