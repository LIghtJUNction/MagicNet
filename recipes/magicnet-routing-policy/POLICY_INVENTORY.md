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
- sukka-chatgpt-voice：local / source
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

这一库存不保证分类文件可获取；必须获取经固定 revision/摘要验证的真实数据并测试 first-match，而不是用标签存在代替内容有效。
