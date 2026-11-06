# 默认配置的接口库存

由固定模板提炼，只包含命名和行为，不复制完整实现配置。

| Outbound tag | 类型 | 默认选择 |
| --- | --- | --- |
| proxy | selector | block |
| select | selector | proxy |
| lan | selector | direct |
| hotspot | selector | direct |
| ad-block | selector | block |
| ad-allow | selector | final |
| cn-direct | selector | direct |
| apple-cn | selector | direct |
| microsoft-cn | selector | direct |
| icloud | selector | direct |
| bing | selector | proxy |
| network-test | selector | proxy |
| dns-guard | selector | proxy |
| ai-chatgpt | selector | block |
| ai-gemini | selector | block |
| ai-grok | selector | block |
| ai-claude | selector | block |
| ai-proxy | selector | block |
| proxy-rule | selector | proxy |
| dev-proxy | selector | proxy |
| social-proxy | selector | proxy |
| download-direct | selector | direct |
| media-proxy | selector | proxy |
| game-proxy | selector | proxy |
| google-proxy | selector | proxy |
| youtube-proxy | selector | proxy |
| github-proxy | selector | proxy |
| discord-proxy | selector | proxy |
| netflix-proxy | selector | proxy |
| spotify-proxy | selector | proxy |
| twitter-proxy | selector | proxy |
| whatsapp-proxy | selector | proxy |
| telegram-proxy | selector | proxy |
| final | selector | proxy |
| direct | direct | — |
| block | block | — |

DNS server tags：bootstrap-local-dns, doh-google, doh-cloudflare.

## 指定域名拒绝

以下是默认模板中的固定路由规则，均使用原生 `action: reject`。前四个域名共用一条规则，第五个域名与目标端口共同构成另一条规则。

| 精确域名 | 目标端口 |
| --- | --- |
| `flash.sec.miui.com` | 不限 |
| `fraud-detection.engine.miui.com` | 不限 |
| `eps.caict.ac.cn` | 不限 |
| `gateway-papa.cloud.weizhi.com` | 不限 |
| `dm.wo.com.cn` | 仅 `18080`，TCP/UDP |

顺序为既有 DNS/嗅探/ICMP/`0.0.0.0` 处理之后，模式、应用、用户增量和业务分流之前。保留 DNS 捕获和解析配置；精确域名以外的父域名、子域名，以及 `dm.wo.com.cn` 的其他端口沿用原有规则。匹配范围为进入 sing-box 且目标域名可识别的流量。规则随内置模板分发，具体生成与验证要求见 BUILD_PROMPT.md 和 POLICY-A08–A12。

## 本地分类标签

- lyc-geosite-ads：local / binary
- lyc-geosite-cn：local / binary
- lyc-geoip-cn：local / binary
- lyc-geoip-telegram：local / binary
- metacubex-geosite-cn：local / binary
- metacubex-geoip-cn：local / binary
- metacubex-geosite-geolocation-not-cn：local / binary
- hagezi-light：local / binary
- karing-acl4ssr-wechat：local / binary
- service-wechat-dns：local / binary
- karing-acl4ssr-china-domain：local / binary
- karing-acl4ssr-china-ip：local / binary
- meta-tencent：local / binary
- meta-category-doh：local / binary
- meta-category-ip-geo-detect：local / binary
- meta-connectivity-check：local / binary
- meta-speedtest：local / binary
- meta-openai：local / binary
- meta-google-gemini：local / binary
- meta-xai：local / binary
- meta-anthropic：local / binary
- meta-bing@cn：local / binary
- meta-bing：local / binary
- meta-category-game-platforms-download：local / binary
- meta-win-update：local / binary
- meta-apple-update：local / binary
- meta-icloud：local / binary
- meta-apple：local / binary
- meta-microsoft：local / binary
- meta-category-scholar-!cn：local / binary
- meta-category-ai-!cn：local / binary
- meta-category-dev：local / binary
- meta-category-media：local / binary
- meta-category-games-!cn：local / binary
- meta-category-social-media-!cn：local / binary
- meta-telegram：local / binary
- meta-twitter：local / binary
- meta-whatsapp：local / binary
- meta-google：local / binary
- meta-google-play：local / binary
- meta-category-entertainment：local / binary
- meta-category-communication：local / binary
- meta-github：local / binary
- meta-huggingface：local / binary
- meta-gitlab：local / binary
- meta-docker：local / binary
- meta-npmjs：local / binary
- meta-notion：local / binary
- meta-discord：local / binary
- meta-slack：local / binary
- meta-reddit：local / binary
- meta-spotify：local / binary
- meta-netflix：local / binary
- meta-youtube：local / binary

ChatGPT 继续通过 `meta-openai` 域名分类和应用包名规则选择 `ai-chatgpt`，DNS 与路由条件保持对应。`sukka-chatgpt-voice` 及其专用 IP/端口规则已移出默认库存，旧来源中的同名 JSON 不再下载或打包。

这一库存不保证分类文件可获取；必须获取经固定 revision/摘要验证的真实数据并测试 first-match，而不是用标签存在代替内容有效。
