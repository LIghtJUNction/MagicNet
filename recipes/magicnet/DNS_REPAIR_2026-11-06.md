# MagicNet DNS 默认出口修复记录

日期：2026-11-06（Asia/Taipei）。范围：受管默认配置中，未分类 DNS 查询的出口、引导解析、配置诊断及升级入口。

## 结论与交付

受管默认配置的未分类 DNS 查询现已使用经 `proxy` 发送的 `doh-cloudflare`。代理连接失败时，默认查询失败，不回退到直连 bootstrap。国内分类、LAN/Tailnet、显式 Direct 模式及代理节点地址的引导解析保持原有策略。用户自定义的独立 DNS 图与显式覆写继续由用户控制。

| 层 | 固定提交与审阅入口 |
| --- | --- |
| Android 源码 | [`47097272655e5bf9bb80dcc910d110e56667be05`](https://github.com/LIghtJUNction/magicnet-android/commit/47097272655e5bf9bb80dcc910d110e56667be05)，[PR #2](https://github.com/LIghtJUNction/magicnet-android/pull/2) |
| 默认模板 | [`ba5793b41fd06704102116fe2536eef5988f2905`](https://github.com/LIghtJUNction/MagicSingBox/commit/ba5793b41fd06704102116fe2536eef5988f2905)，[PR #21](https://github.com/LIghtJUNction/MagicSingBox/pull/21) |
| 模板内容摘要 | `config.json` SHA-256：`e269e2303cf1e23d3b4ce69dcb7cca39f0f53dc647c5d03aace4c4bd7f986be0` |
| 实际核心 | `1.15.0-alpha.13+LIghtJUNction.d850ff0ff68e`；源码 pin `d850ff0ff68e11a71aa8207627e0a826cb52808f` |

本轮不改变 Android 软件版本，不创建正式 Release，不把用户设备视为已安装本次修改。

## 根因

DNS 捕获和上游解析是两个不同步骤。捕获决定哪个进程接收查询；DNS server 的 `detour` 决定该进程向上游查询时使用哪个出口。旧模板及 `magicnet_dns_apply_singbox` 都将 `dns.final` 设为没有代理 detour 的 `bootstrap-local-dns`。运行时又为同一解析器追加无条件 `evaluate/respond` 规则。因此，一个随后通过代理访问的网站，其未匹配分类的域名查询仍可能先通过直连 DNS 发出。

sing-box 的新式 HTTPS DNS server 在没有 detour 时使用直接拨号；`dns.final` 指定默认解析器，缺省时使用列表中的第一个解析器。这解释了为什么加密 DNS、成功捕获 53 端口或关闭 fake IP，仍不足以单独判断默认查询的出口。参见 [HTTPS DNS 文档](https://sing-box.sagernet.org/configuration/dns/server/https/) 与 [DNS final 文档](https://sing-box.sagernet.org/configuration/dns/)。

旧健康检查只要求服务器列表中存在一个经 `proxy` 访问的已知厂商。它没有检查被默认路径实际引用的 server：存在一个未被使用的海外 DNS 可以掩盖直连默认；IP 形式或其他厂商的合法代理解析器也可能被误报。

## 修复方式

1. **模板与运行时使用相同默认出口。** 默认 `dns.final` 和 `magicnet-final-dns` 的 evaluate server 均使用 `doh-cloudflare`。受管旧配置缺少该解析器时补入代理 DoH；保留标签存在但定义冲突、类型不合格或重复的情况则原子拒绝，旧文件保持完整。
2. **代理节点独立引导解析。** 受管配置缺少 `route.default_domain_resolver` 时使用直连的 `bootstrap-local-dns`。否则，建立代理连接所需的节点域名可能需要先通过尚未建立的代理解析。已有显式 resolver 与 default standalone 配置的原解析图保留。[Dial Fields 文档](https://sing-box.sagernet.org/configuration/shared/dial/)说明该字段对代理出站解析的是服务器地址。
3. **诊断检查默认引用。** 健康检查核对最终解析器与无条件 route/evaluate 的 resolver detour，拒绝缺失、重复或直连的默认引用，接受不同厂商和 IP 地址形式。它是配置层检查，实际出口仍由数据包测试确认。
4. **升级与展示同步。** 安装器、CLI、WebUI、默认配置源和子模块统一固定到新模板。迁移只匹配官方旧 revision 与 digest 的精确配对；自定义仓库、版本或摘要保持原值。默认 DNS 状态展示为 `doh-cloudflare`，机器接口 schema 与显式 profile 名称保持兼容。

本次未增加常驻进程、周期探测或公共联网请求。正常模板复用现有 DNS server；手动 Cloudflare UDP/DoT/DoH profile 继续保留各自传输方式。没有从这些结构性事实推导未经测量的性能提升比例。

## 验证证据

### 修复前对照

新增模板回归在旧源配置和旧生成配置上出现四个预期失败：两个合成未知域名均选择了直连 bootstrap。运行生产 DNS 物化函数的新增测试也在旧 `dns.sh` 上退出 1，原因是默认最终解析器没有代理 detour。修复后的同一路径通过。

### 本地验证

| 检查 | 结果与范围 |
| --- | --- |
| 模板 `python3 -m unittest discover -s tests` | 33 项通过；源配置、生成配置、分类次序、显式模式与无节点默认 |
| 模板 `python3 generate.py --check` | 通过；生成文件与源配置一致 |
| `bash scripts/test-dns-profile-safety.sh` | 通过；三个手动 profile、默认远端、缺失补齐、冲突/重复拒绝、独立配置、缓存偏好与原子写入 |
| `python3 scripts/test-dns-proxy-egress.py` | 生产物化断言通过：默认代理、独立 bootstrap、显式直连保留、重复应用字节一致 |
| 锁定核心 `sing-box check` | 本地合成的生产 DNS 配置通过校验 |
| `bash scripts/quality-gate.sh rust` | 格式检查、Clippy 与全套 Rust 单元/集成测试通过；诊断补正后再次全套通过，DNS 诊断定向 26 项通过 |
| `python3 scripts/test-dns-output-order.py` | 15 项通过 |
| `python3 scripts/test-dns-capture-fast-path.py` | 6 项通过 |
| `bash scripts/test-dns-leak-guard-timeout.sh` | 有界超时保护通过 |
| pin、精确迁移、安装刷新与路由模板检查 | 通过；自定义 pin 保留。安装模板套件 20 通过、2 因可选环境缺失跳过 |
| WebUI DNS profile 测试与类型检查 | 通过；类型检查使用 `NODE_OPTIONS=--max-old-space-size=768` |
| 正式 Shell lint、源码检查与 CI 合同测试 | 通过 |

本地容器禁止创建 `AF_NETLINK` 套接字，实际核心在 DNS listener 启动前退出。因此本地 `--require` 数据包测试明确失败于环境能力，没有把跳过记作通过。

### 独立审查与补正

独立审查发现一项 P2 诊断漏报：显式 `type: "default"` 与省略类型在核心中等价，但前一候选的健康检查把类型元数据误当成匹配条件，可能漏报无条件直连规则。新增回归在前一候选上失败；最终提交 `4709727` 识别省略、空串和显式默认类型，并依据固定核心语义处理没有匹配条件时的 `invert` 元数据。route/evaluate 的直连反例、远端正例及带条件的国内/Direct 合法规则均通过。该补正只改动诊断与单元测试，生产 DNS 物化脚本、模板、核心和数据包夹具与 `e2725d7` 相同。

### GitHub 实际核心数据包测试

[前一候选 e2725d7 的 Network Regression Evidence](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42182836598)整套成功，包含步骤 `Verify DNS proxy egress and closed failure with the production core`。`core-evidence` job `127776187925` 于 07:47:12–07:47:18 UTC 执行该步骤，使用仓库固定核心，在本地 TLS DoH 服务与 HTTP CONNECT 代理之间发送真实数据包，保持生产物化结果中的 DNS 规则、final、detour 和节点解析器，仅替换端点地址、端口与证书信任。

| 场景 | 实际验收 |
| --- | --- |
| 未分类 A/AAAA，经 UDP/TCP 进入核心 | 返回远端夹具答案，并观察到代理 CONNECT；直连解析器没有对应业务查询 |
| 代理节点地址为域名 | 通过直连 bootstrap 解析，代理成功建立，无递归依赖 |
| 显式直连测试域名 | 返回直连夹具答案，原策略有效 |
| 代理拒绝连接 | A/AAAA 查询失败；对应直连业务查询为零；没有绕过代理到达远端夹具 |

测试不访问公共 DNS、不使用用户订阅、不修改主机路由或防火墙，也不关闭 TLS 证书验证。CI 使用 `--require`，缺核心或能力不足会失败。模板的 [Validate configuration](https://github.com/LIghtJUNction/MagicSingBox/actions/runs/42182106388) 与源码的 [Network regression](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42182836609)亦已通过。

### 配方与发布入口

根配方升至 0.3.15，routing-policy 升至 0.2.5，新增 M60 和 POLICY-A21–A25。`scripts/check-recipes.py` 完成目录检查、打包、归档检查和完整中文提示词验证：8 个包、60 份 Markdown；`scripts/test-release.py` 的 21 项检查通过。未打包源码、私密配置或测试目录进入配方负载。

## 兼容范围与设备边界

修复对象是受管默认解析路径。国内直连、用户显式 Direct、代理节点引导解析和 standalone 自定义解析图仍保留；显式配置覆写也可能有意改变 DNS 选择，健康检查读取最终配置后再作判断。没有强制把所有用户配置替换为统一的海外 DNS。

真实核心回环测试覆盖解析出口和代理故障行为。物理 Android 手机、移动网络切换、Android Private DNS、独立应用自带 DoH 和用户实际节点的端到端抓包未在本轮执行。安装包含本次提交的模块并完成设备验收之后，才能把结果扩大到对应设备与网络环境。

## 自审

| 问题 | 依据 |
| --- | --- |
| 修复解决了什么？ | 旧版本对照失败，新版本默认引用与实际代理出口通过 |
| 原因能否复述？ | final 选中了直连 bootstrap；捕获与上游出口分别检查 |
| 是否验证故障？ | 代理拒绝后 DNS 失败，对应直连查询为零 |
| 是否保留合法行为？ | 显式直连、节点 bootstrap、三个手动 profile、standalone 与自定义 pin 的回归 |
| 结论是否超出证据？ | 配置、真实核心回环、CI 和物理设备范围分别记录；没有声称已部署或全面消除所有 DNS 出口风险 |
