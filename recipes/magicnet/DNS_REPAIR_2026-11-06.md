# MagicNet DNS 默认出口修复记录

日期：2026-11-06；本文 CI 时间均为 UTC。范围：受管默认配置中，未分类 DNS 查询的出口、引导解析、配置诊断及升级入口。

## 结论与交付

受管默认配置的未分类 DNS 查询现已使用经 `proxy` 发送的 `doh-cloudflare`。代理连接失败时，默认查询失败，不回退到直连 bootstrap。国内分类、LAN/Tailnet、显式 Direct 模式及代理节点地址的引导解析保持原有策略。用户自定义的独立 DNS 图与显式覆写继续由用户控制。

| 层 | 固定提交与审阅入口 |
| --- | --- |
| Android 源码 | [`38c6eea6a42eb5f2cc3697c81225f35fd3c82d5c`](https://github.com/LIghtJUNction/magicnet-android/commit/38c6eea6a42eb5f2cc3697c81225f35fd3c82d5c)，[PR #2](https://github.com/LIghtJUNction/magicnet-android/pull/2) |
| 默认模板 | [`ba5793b41fd06704102116fe2536eef5988f2905`](https://github.com/LIghtJUNction/MagicSingBox/commit/ba5793b41fd06704102116fe2536eef5988f2905)，[PR #21](https://github.com/LIghtJUNction/MagicSingBox/pull/21) |
| 模板内容摘要 | `config.json` SHA-256：`e269e2303cf1e23d3b4ce69dcb7cca39f0f53dc647c5d03aace4c4bd7f986be0` |
| 实际核心 | `1.15.0-alpha.13+LIghtJUNction.d850ff0ff68e`；源码 pin `d850ff0ff68e11a71aa8207627e0a826cb52808f` |

源码 [PR #2](https://github.com/LIghtJUNction/magicnet-android/pull/2) 已合并为 `faa7d956324a20889cb921ff35c9f13b66dc0c1a`，合并后源码树与受测候选完全一致；模板 PR #21 亦已合并。主项目的配方、固定依赖和证据由 [PR #441](https://github.com/LIghtJUNction/MagicNet/pull/441) 归档。本轮保留 Android 软件版本 `v1.8.5`，交付完整修复验证包；没有创建正式 Release 或安装用户设备。

## 根因

DNS 捕获和上游解析是两个不同步骤。捕获决定哪个进程接收查询；DNS server 的 `detour` 决定该进程向上游查询时使用哪个出口。旧模板及 `magicnet_dns_apply_singbox` 都将 `dns.final` 设为没有代理 detour 的 `bootstrap-local-dns`。运行时又为同一解析器追加无条件 `evaluate/respond` 规则。因此，一个随后通过代理访问的网站，其未匹配分类的域名查询仍可能先通过直连 DNS 发出。

sing-box 的新式 HTTPS DNS server 在没有 detour 时使用直接拨号；`dns.final` 指定默认解析器，缺省时使用列表中的第一个解析器。这解释了为什么加密 DNS、成功捕获 53 端口或关闭 fake IP，仍不足以单独判断默认查询的出口。参见 [HTTPS DNS 文档](https://sing-box.sagernet.org/configuration/dns/server/https/) 与 [DNS final 文档](https://sing-box.sagernet.org/configuration/dns/)。

旧健康检查只要求服务器列表中存在一个经 `proxy` 访问的已知厂商。它没有检查被默认路径实际引用的 server：存在一个未被使用的海外 DNS 可以掩盖直连默认；IP 形式或其他厂商的合法代理解析器也可能被误报。

## 修复方式

1. **模板与运行时使用相同默认出口。** 默认 `dns.final` 和 `magicnet-final-dns` 的 evaluate server 均使用 `doh-cloudflare`。受管旧配置缺少该解析器时补入代理 DoH；保留标签存在但定义冲突、类型不合格、重复或关闭 TLS 证书验证的情况则原子拒绝，旧文件保持完整。
2. **代理节点独立引导解析。** 受管配置缺少 `route.default_domain_resolver` 时使用直连的 `bootstrap-local-dns`。否则，建立代理连接所需的节点域名可能需要先通过尚未建立的代理解析。已有显式 resolver 与 default standalone 配置的原解析图保留。[Dial Fields 文档](https://sing-box.sagernet.org/configuration/shared/dial/)说明该字段对代理出站解析的是服务器地址。
3. **诊断检查默认引用。** 健康检查核对最终解析器、无条件 route/evaluate 及其配置的出站链，识别默认类型和空匹配值，拒绝缺失、重复、循环或落到直连的默认引用，接受不同厂商和 IP 地址形式。它是配置层检查，实际出口仍由数据包测试确认。
4. **升级与展示同步。** 安装器、CLI、WebUI、默认配置源和子模块统一固定到新模板。迁移只匹配官方旧 revision 与 digest 的精确配对；自定义仓库、版本或摘要保持原值。默认 DNS 状态及 WebUI 尚未取得响应时的初始值均为 `doh-cloudflare`，机器接口 schema 与显式 profile 名称保持兼容。

profile 应用与回滚复用现有配置锁；物化失败时恢复原 `dns.conf` 的精确内容或原不存在状态，回滚失败保留失败信息，失败路径不启动或停止核心。已有合法 profile 的成功路径保持。

DNS 修复没有增加常驻进程、周期探测或额外的产品侧公共探测请求。正常模板复用现有 DNS server；手动 Cloudflare UDP/DoT/DoH profile 继续保留各自传输方式。没有从这些结构性事实推导未经测量的性能提升比例。

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
| `bash scripts/quality-gate.sh rust` | 格式检查、Clippy 与全套 Rust 单元/集成测试通过；边界补正后再次全套通过，DNS/profile 定向 33 项通过 |
| `python3 scripts/test-dns-output-order.py` | 15 项通过 |
| `python3 scripts/test-dns-capture-fast-path.py` | 6 项通过 |
| `bash scripts/test-dns-leak-guard-timeout.sh` | 有界超时保护通过 |
| pin、精确迁移、安装刷新与路由模板检查 | 通过；自定义 pin 保留。安装模板套件 20 通过、2 因可选环境缺失跳过 |
| WebUI DNS/profile/状态/刷新测试与类型检查 | 相关测试 24 项通过；类型检查使用 `NODE_OPTIONS=--max-old-space-size=768` |
| 正式 Shell lint、源码检查与 CI 合同测试 | 通过 |

本地容器禁止创建 `AF_NETLINK` 套接字，实际核心在 DNS listener 启动前退出。因此本地 `--require` 数据包测试明确失败于环境能力，没有把跳过记作通过。

### 独立审查与补正

独立审查发现一项 P2 诊断漏报：显式 `type: "default"` 与省略类型在核心中等价，但前一候选的健康检查把类型元数据误当成匹配条件，可能漏报无条件直连规则。新增回归在前一候选上失败；增量提交 `4709727` 识别省略、空串和显式默认类型，并依据固定核心语义处理没有匹配条件时的 `invert` 元数据。route/evaluate 的直连反例、远端正例及带条件的国内/Direct 合法规则均通过。该补正只改动诊断与单元测试，生产 DNS 物化脚本、模板、核心和数据包夹具与 `e2725d7` 相同。

后续仓库自动审查的有效边界由 `38c6eea` 合并修正：空数组/null/关闭的匹配器不能把无条件规则伪装成条件规则；复用路由诊断解析 `proxy` 的实际配置链，直连、缺失、重复和循环不通过，默认无节点的 block 仍能阻止泄漏；受管远端拒绝 `tls.insecure: true`；失败应用恢复原 profile；前端初始默认值同步。对应空匹配器、伪装出站、TLS 和失败持久化的反例先失败后通过。

显式 `route.default_domain_resolver` 继续保留：它可能对应已有合法引导图、数字地址节点或单节点 resolver。强制覆盖所有非空值会破坏该配置接口；缺省受管配置已明确使用独立 bootstrap，用户自定义循环不被静默改写。

### GitHub 实际核心数据包测试

[最终候选 38c6eea 的 Network Regression Evidence](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346632)整套成功，包含步骤 `Verify DNS proxy egress and closed failure with the production core`。`core-evidence` job `127790723176` 于 08:25:41–08:25:47 UTC 执行该步骤，使用仓库固定核心，在本地 TLS DoH 服务与 HTTP CONNECT 代理之间发送真实数据包，保持生产物化结果中的 DNS 规则、final、detour 和节点解析器，仅替换端点地址、端口与证书信任。

| 场景 | 实际验收 |
| --- | --- |
| 未分类 A/AAAA，经 UDP/TCP 进入核心 | 返回远端夹具答案，并观察到代理 CONNECT；直连解析器没有对应业务查询 |
| 代理节点地址为域名 | 通过直连 bootstrap 解析，代理成功建立，无递归依赖 |
| 显式直连测试域名 | 返回直连夹具答案，原策略有效 |
| 代理拒绝连接 | A/AAAA 查询失败；对应直连业务查询为零；没有绕过代理到达远端夹具 |

测试不访问公共 DNS、不使用用户订阅、不修改主机路由或防火墙，也不关闭 TLS 证书验证。CI 使用 `--require`，缺核心或能力不足会失败。模板的 [Validate configuration](https://github.com/LIghtJUNction/MagicSingBox/actions/runs/42182106388) 与源码的 [Network regression](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42182836609)亦已通过。

最终候选 `38c6eea` 的 [Code Quality 42187346672](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346672) 全部 7 个 job 成功，包括 Rust、Shell/host、WebUI、组件与 Android probe 合同。前一候选 `e2725d7` 的 [42182836598](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42182836598) 也通过同一真实核心场景；每轮验证使用自己的运行记录，不将旧结果改写为新提交结果。最终 `38c6eea` 已重复通过该真实核心步骤及整套 Network Regression Evidence；最终同一源码的 Network regression、Rules Release Integration、Install Onboarding、Build Kam Module 和 Android KernelSU Acceptance 亦全部成功；Android 的首次失败和唯一复验分开记录如下。

### 完整模块与 Android 验收

最终候选的 [Build Kam Module 42187346674](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346674) 成功；build job `127790723609` 生成 artifact `13489440458`。构建使用 PR 合并提交 `635d4c34f43c8d6c69d890db30336c87986b6686`，其源码树与 `38c6eea` 均为 `1e83b5b00e2f8b3aa2018358717a81e228820a94`。

| 完整离线模块 | 核验结果 |
| --- | --- |
| 文件 | `MagicNet-DNS-fix-38c6eea-full.zip`；ARM64，产品版本仍为 `v1.8.5` |
| 大小 | 68,480,032 字节 |
| SHA-256 | `1fdc0caa0c2d412562bc44058b8527210ebad6df75dbc0fcc17d1eba44bab234` |
| ZIP | 360 个条目全部通过 CRC；无不安全路径、重复条目或符号链接 |
| 离线组件 | 10 个组件、168 个文件的存在性、尺寸、摘要和权限符合内嵌清单 |
| 生产内容 | DNS 脚本、安装配置脚本、模板仓库配置与固定源码逐字节一致；模板原始配置与固定模板一致 |
| 排除内容 | 未发现测试/fixture、`node_modules`、Git 元数据及已检查的开发缓存目录 |

该文件为 CI 构建的原始完整模块，只改了便于识别的下载文件名，没有重新打包。外层 artifact 的 142,231,785 字节及摘要也与 GitHub 元数据一致；外层摘要与上表完整模块摘要分别记录，避免混用。

[Android KernelSU Acceptance 42187346630](https://github.com/LIghtJUNction/magicnet-android/actions/runs/42187346630) 的首次执行失败，失败记录完整保留。前置 harness 套件 300 项中 1 项可选 CA 夹具跳过，其余通过；实际 Android 15 / KernelSU v3.2.0 / x86_64 TUN 流程的 environment、kernelsu-bootstrap、install-before-first-boot 通过，cold-boot 在 `curl_tls_positive_failed` 处失败，后续 8 个生命周期阶段未运行。已安装 curl 的摘要核验、核心运行、数据面就绪及该次重启的 root/SELinux Enforcing/原生 init 阶段均通过。

失败发生于本地 HTTPS 正向控制：它用 `--resolve` 固定回环地址、显式关闭代理并经 ADB reverse 访问临时 TLS 服务，不使用 DNS 查询或代理出站。harness 未保留具体 curl 退出码或 TLS 错误细节，连接失败与测试服务请求计数不符会进入同一错误，因此不能认定唯一根因，也不能把首次 Android 验收写成成功。仅对同一提交的失败 jobs 启动一次复验；源码、TLS 信任、超时及断言均未修改。复验结论及其范围如下。

唯一一次复验（attempt 2）成功：12/12 生命周期阶段全部通过，5/5 重启均核对新 boot、root、SELinux Enforcing 和 KernelSU 原生 init。实际模块 curl 的本地 TLS 正向控制收到 1 次 GET；错误主机名与默认信任拒绝控制均未收到 GET，资源清理通过。Android 主 job `127798786927` 为 41 个成功步骤、7 个条件跳过、0 失败，最终 Simulation Gate 成功。已成功的前置 harness 在复验中复用，未将 300 项测试计成执行两遍。

两次都使用相同源码快照和固定依赖，未修改 TLS 信任、时间预算或断言；但 CI 重新构建了组件，curl 摘要由 `3f49744aea2d375281bb5485f6c428b6606373326f9b262702bfa4ed5f24e062` 变为 `9150917b8986fa83002f6d8719955a63d14990505007d02490deb3a7163fa22f`。其余 curl 构建元数据一致。因此结论是同一源码的一次复验通过，不是同一二进制重试；首次失败原因仍未定位，首次 artifact 未被复验覆盖。

Android 的正常产品探测仍记录 `offline/upstream_unavailable`、`primary_reason=tls_failure`，未观察到 Google HTTPS 204；这次产品探测失败后进入 60 秒退避，没有执行订阅刷新或重启恢复。生命周期与诊断行为通过，不代表实际公网代理质量已通过。

原始运行身份、数据包断言、首次失败阶段与产物摘要见[机器可读证据](https://github.com/LIghtJUNction/MagicNet/blob/main/docs/evidence/dns-repair-ci-2026-11-06.json)。ARM64 完整模块的构建和文件审计，与 x86_64 模拟设备的执行验收分别记录。

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
