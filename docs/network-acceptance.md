# 网站联网验收

`cli pingtest` 是快速连通性诊断，收到 HTTP 错误响应也可能报告 reachable。
不能把它当作网站、登录或应用功能验收。新增 `network-check.sh` 专门执行更严格的
HTTPS GET 检查；本次不改变旧 CLI 输出格式或现有网络规则。

## 真机运行

模块正在运行、订阅已配置后执行：

```sh
su -c 'sh /data/adb/modules/MagicNet/network-check.sh --rounds 3'
```

默认通过 `http://127.0.0.1:7892` 的 mixed inbound 访问目标，由正在运行的核心处理。
清单包含 24 个公开端点：国内门户、电商、微信官网、Google 搜索/Play/登录/下载/
静态资源/Android 联网检测、YouTube、ChatGPT、Claude、GitHub、Microsoft、Apple、
Wikipedia、Telegram 和 Discord。它们是基本页面/基础设施探针，不是对应 App 的功能测试。

每个端点要求最终 HTTP 状态与清单完全一致（200 或 204），且 curl 完整完成传输。
403/404/429/5xx、证书错误、DNS 错误、超时、截断的 200 都不能通过；204 探针还要求
零跳转、零响应体，避免把认证门户当成联网成功。HTTPS 不能降级跳转到 HTTP。
不会读取 `.curlrc`，不会禁用证书校验，不做掩盖第一次失败的自动重试。

最多 8 路并发、3 轮独立请求，默认 4 路/1 轮；每个请求默认最多 12 秒、响应体上限
2 MiB。达到大小上限、缺少 curl 能力为 INCOMPLETE，不是 PASS。多轮中任一失败
都会使整个测试失败。实际流量取决于页面大小，最多 24 × 3 × 2 MiB 的响应体预算
（另有 TLS、请求头等开销；旧版 curl 对未知 Content-Length 的限制能力也可能不同）。

输出为 TSV，可保留用于前后版本对比。只输出目标 ID、分类、路径、执行 UID、轮次、
状态、curl 返回码、HTTP 状态和累计耗时，不输出订阅、账户、私有 URL、原始响应或
curl 错误文本。退出码：0 表示全部基本 HTTPS 探针通过；1 表示失败；2 表示未完整
测试；64 表示输入错误。403 可能来自网站风控，不能仅凭这一项就断定模块规则错误。
网站策略/重定向可能变化，更新目标清单时应核对真实结果，而不是放宽为任意状态都通过。

## 对照与 IPv4/IPv6

```sh
# 当前进程的系统路径对照：不是“保证直连”，也不是 App/TUN 验收。
su -c 'sh /data/adb/modules/MagicNet/network-check.sh --mode system --family 4'
su -c 'sh /data/adb/modules/MagicNet/network-check.sh --mode system --family 6'
```

root 在模块规则中可能被豁免，所以 system 路径成功不能证明普通应用的透明代理正常；
proxy 路径成功也不能证明按应用 UID 分流或 DNS 拦截正常。proxy 模式的域名解析由代理
处理，报告标记为 `proxy_managed`，拒绝用 `--family 4/6` 冒充目标地址族测试。IPv6
检查失败不会静默退回 IPv4，也不会当作 IPv6 通过。应分别记录 Wi-Fi/移动网络、
执行 UID、TUN/eBPF 模式、IPv6 能力及是否通过代理；不要混合成一个“全部正常”。

可通过 `--targets FILE` 使用自定义公开端点清单，格式为
`id|category|https_url|expected_status`。最多 64 项，ID 唯一；不支持 HTTP、认证 URL、
任意 Shell 命令或将 4xx 设置为成功预期。`--proxy` 仅允许本地 HTTP mixed inbound。

## CI 与实际验收的边界

```sh
python3 scripts/test-network-check.py
bash scripts/test-host.sh
```

离线用例包含 mock 的 DNS/连接/TLS 失败，及真实本地 TLS 服务器和真实 curl 的
GET、证书校验、重定向、IPv4/IPv6、超时、截断响应与受限并发测试。不需要订阅、
账号或互联网。本机缺少 curl/openssl 或 IPv6 loopback 时会明确 SKIP，不能把该项
写成已验证。此套件加入 `test-host.sh`，因此复用现有 shell 质量检查与发布前检查。

独立 Network regression 工作流还会从 GitHub 托管 runner 对公开端点做一次 system
路径观察并上传报告。该观察不阻断发布（第三方风控/故障不可控），但原始失败与退出码
必须原样保留；工作流成功不代表所有网站通过。它只代表 runner 出口，不代表用户手机、
节点或 MagicNet 透明代理。离线 fixture 测试失败则正常阻断。

以下项目仍必须在真实设备、真实账号和真实网络上验收，报告始终标为 NOT_TESTED，
不能用公开首页 200 或本地模拟通过来代替：

- Google Play：登录、打开应用详情、下载并安装一个免费应用、检查后台更新/推送。
- ChatGPT：登录、文本流式回复、建立并保持语音对话、Wi-Fi/移动数据切换。
- 微信：后台文字消息/图片、语音消息、语音或视频通话、国内直连是否异常。
- DNS/数据面：普通应用 UID 的 A/AAAA 解析、53/853 拦截/泄漏、TUN 与 eBPF 的独立
  验收、UDP/QUIC、断网重连与多应用并发。数据面状态使用 `cli transparent status`
  和 `cli health`，不能在 eBPF 模式下把没有 magicnet0 当作失败。

ChatGPT 官方网络说明将语音 UDP 3478 与 TCP 443 回退单独列出；本脚本不声称已完成
WebRTC/STUN/TURN 或登录后的语音握手：
https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps
