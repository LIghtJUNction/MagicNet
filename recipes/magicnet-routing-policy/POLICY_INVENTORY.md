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

## DNS 解析器与本地链路范围

| DNS server tag | 类型 | 默认职责 |
| --- | --- | --- |
| `lan-mdns` | `mdns` | `.local` 和下列链路本地反向区域 |
| `bootstrap-local-dns` | `https` | 代理节点引导及既有直连分类 |
| `doh-google` | `https` | 保留既有显式分类，连接经 `proxy` |
| `doh-cloudflare` | `https` | 未命中分类的公网默认，连接经 `proxy` |

`lan-mdns` 的完整匹配范围为以下六个后缀。按域名标签边界匹配，规则先于 Direct/Global 模式的公网 DNS；启用 Tailscale 后，其既有 `ts.net` MagicDNS 规则保持优先且范围不重叠。

| 后缀 | 范围 | 依据 |
| --- | --- | --- |
| `local` | 当前链路的主机名及服务发现名称 | [RFC 6762 第 3 节](https://www.rfc-editor.org/rfc/rfc6762.html#section-3) |
| `254.169.in-addr.arpa` | `169.254.0.0/16` 的反向查询 | [RFC 6762 第 4 节](https://www.rfc-editor.org/rfc/rfc6762.html#section-4) |
| `8.e.f.ip6.arpa`、`9.e.f.ip6.arpa`、`a.e.f.ip6.arpa`、`b.e.f.ip6.arpa` | `fe80::/10` 的反向查询 | [RFC 6762 第 4 节](https://www.rfc-editor.org/rfc/rfc6762.html#section-4) |

`lan-mdns` 使用 [sing-box 原生 mDNS](https://sing-box.sagernet.org/configuration/dns/server/mdns/)，不配置公共或系统 DNS 后备。`home.arpa`、`.lan` 和其他私网反向区域保留旧策略；本项不代表这些名称已获得局域网解析能力，也不改变未知公网域名的代理 DNS 默认。

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

## 大陆教育域名后缀

以下 16 个后缀是本轮教育业务分类的完整清单，匹配根域名及其子域名。路由复用 `cn-direct`，默认 `direct`；DNS 使用相同后缀和现有本地加密解析器。官方来源于 2026-11-06 核验，用于确认服务域名及用途。

| 域名后缀 | 用途 | 官方来源 |
| --- | --- | --- |
| `edu.cn` | 教育科研域名空间 | [CERNIC 域名管理职责](https://www.nic.edu.cn/home.html) |
| `moe.gov.cn` | 教育部政府门户 | [教育部网站年度报表](https://www.moe.gov.cn/jyb_xxgk/s5743/s5744/A01/202601/t20260130_1427931.html) |
| `chsi.com.cn` | 学信网、学籍学历与招生服务 | [学信网介绍](https://www.chsi.com.cn/about/about_site.shtml) |
| `smartedu.cn` | 国家智慧教育公共服务平台 | [平台主站](https://www.smartedu.cn/)、[官方帮助中心](https://system.smartedu.cn/npss/help/3) |
| `neea.cn` | 中国教育考试网所属报名服务 | [中国教育考试网主站及入口](https://www.neea.edu.cn/) |
| `ncss.cn` | 国家大学生就业服务平台 | [主站](https://www.ncss.cn/)、[平台介绍](https://gyu.ncss.cn/intro) |
| `icourse163.org` | 中国大学 MOOC | [官方介绍](https://www.icourse163.org/about/aboutus.htm) |
| `icourses.cn` | 爱课程资源共享与视频公开课 | [官方学习服务](https://www.icourses.cn/webInfo?type=contactUs) |
| `xuetangx.com` | 学堂在线大学课程 | [官方平台介绍](https://next.xuetangx.com/?channel=i.area.navigation_bar) |
| `yuketang.cn` | 雨课堂教学、作业与互动 | [官方使用帮助](https://www.yuketang.cn/static/html/faq.html) |
| `chaoxing.com` | 超星与学习通课程服务 | [官方学习通介绍](https://apps.chaoxing.com/d/app/198.html) |
| `zhihuishu.com` | 智慧树高校共享课程 | [平台主站](https://www.zhihuishu.com/)、[官方介绍](https://www.zhihuishu.com/aboutus.html) |
| `eol.cn` | 教育在线资讯与教育服务 | [教育在线主站](https://www.eol.cn/) |
| `cnki.net` | 中国知网学术与毕业论文服务 | [官方毕业论文系统服务说明](https://co2.cnki.net/User/agreement.html) |
| `wanfangdata.com.cn` | 万方学术资源与科研学习服务 | [万方数据主站](https://www.wanfangdata.com.cn/) |
| `cqvip.com` | 维普文献与教育科研服务 | [维普主站](https://www.cqvip.com/) |

路由插在目标端口 `853` 的 `dns-guard` 规则之后，DNS 插在 `meta-category-doh` / `meta-category-ip-geo-detect` 规则之后。模式、LAN/Tailnet、用户和应用分流、广告及 DNS 防护继续优先；教育规则先于后续国外学术、AI、游戏、开发与媒体分类。路由省略 `action`，保留现有 `cn-direct` 组和用户选择。

清单不扩展到所有 `.edu`、`.cn`、包含教育关键词的域名或共享 CDN。官方页面引用的外部资源继续按原有规则处理；本清单不增加 selector、DNS server 或外部规则数据依赖。匹配、优先级及配置保留验收见 POLICY-A16–A20，实际网络与设备结果另记。

## 本地分类标签

规则来源固定为 [MagicNetRules `c4ad0a94f35af2b7950b47362e1c23e583209790`](https://github.com/LIghtJUNction/MagicNetRules/commit/c4ad0a94f35af2b7950b47362e1c23e583209790)，发行资产为 [rules-20261116-df4863416dd56ad6](https://github.com/LIghtJUNction/MagicNetRules/releases/tag/rules-20261116-df4863416dd56ad6)。manifest SHA-256 为 `701c103ede587ca83ed6852a2a9bd0b093248cc843e8e221c9b3b7cac6f116cc`；构建须同时校验清单和被引用资产，开机不依赖上游可用性。

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
