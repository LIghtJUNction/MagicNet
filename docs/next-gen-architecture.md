# MagicNet 当前架构

文件名为兼容已有链接保留。MagicNet 使用 sing-box，透明模式显式选择 `tun|ebpf`，默认 `tun`。模式切换必须原子且可回滚；不支持 `auto`、TProxy、Redirect 或 netd `ALLOW_MULTI` 路径。

## 数据面

```text
Android 应用 / 已进入内核转发的热点流量
                    │
                    ▼
       sing-box inbound（显式二选一）
       tun: magicnet0 / ebpf: cgroup、TC
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

`tun` 模式通过 root 管理的 `magicnet0` 自动路由将设备应用流量送入 sing-box。MagicNet 不调用 Android 应用的 `VpnService.establish()`，因此不会占用系统 VPN slot。`Bypass TUN` UID 同时绕过 TUN 和 MagicNet DNS 捕获，回到原生网络或外部 VPN 的路径。

`ebpf` 模式使用 `type: "ebpf"` inbound，本机流量通过 cgroup 捕获，仅在确认下游接口后挂载共享 TC 程序。检查此模式时以 capability、cgroup 和 TC attachment 状态为准，不要求存在 `magicnet0`。

热点仍由 Android/OEM tethering 完成 DHCP 与 NAT。`tun` 模式选择热点 Proxy 时，MagicNet 发现真实 tether 接口，在 Android tethering 规则之前添加指向 sing-box `table 2022` 的临时 `ip rule`，并关闭 tether 硬件卸载，让转发包进入 `magicnet0`，再由 `hotspot` selector 决定 Direct 或 Proxy；接口变化由 watcher 重算，退出 Proxy、停止服务或卸载会清理策略规则并恢复原值。`ebpf` 模式按下游接口的共享 TC 挂载状态判断热点捕获。

## 控制面

CLI 是稳定的设备控制合同，WebUI 和 MCP 都复用相同能力：

- 订阅与配置：构造候选内容，执行解析和 `sing-box check`，原子激活。
- 节点与 selector：读取 sing-box API，保存选择并在更新后重放。
- 应用、Wi-Fi、热点和网络策略：更新模块管理的配置并触发受控应用。
- 健康与支持：通过 `cli transparent status` 和 `cli health` 汇总进程、当前模式的数据面、DNS、路由、订阅、selector 和日志证据。

MCP 是可选远程控制面，默认关闭且独立 secret 认证；它不改变 CLI 的权限边界。

## 状态面

- `.config/`：用户选择和持久配置，包括当前订阅来源、应用/Wi-Fi/网络策略与 MCP endpoint。
- `.state/`：可重建运行状态、事务 journal、selector 选择、UID 解析结果和 supervisor PID。
- `.log/`：服务、订阅和 MCP 的轮转日志。
- `bin/`：发布包运行时；模块根 `cli` 保持到 `bin/magicnet-cli` 的兼容入口。

URL 与本地订阅来源互斥激活。更新事务保留上一个有效配置与来源，候选验证失败时回滚；中断后的 journal 会在下一次更新中协调恢复。

## 故障隔离与不变量

- 透明模式只允许 `tun|ebpf`，默认 `tun`；必须显式切换，验证失败时恢复先前模式与配置。
- 候选配置通过结构校验、节点校验和 `sing-box check` 后才能替换运行配置。
- 代理节点为空或服务专用组没有合格节点时，相关 selector fail-closed，不静默选择未知出口。
- 应用包名在每次应用策略时按 Android 用户解析 UID，避免只按主用户包名产生错配。
- 核心停止时清理模块管理的透明/DNS 规则；重启只读取已经验证的配置。
- 热点硬件卸载和一次性 Tailscale auth key 都有明确保存、恢复或擦除生命周期。

排查故障统一使用 `cli transparent status` 和 `cli health`，不要假定存在 `cli ebpf status`，也不要将 TUN 接口检查套用于 eBPF 模式。
