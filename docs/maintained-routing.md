# Maintained routing classifiers

Business domains and service IPs are maintained upstream, rather than duplicated
in the MagicNet template:

- [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat/tree/sing/geo/geosite): named AI services, Apple/iCloud, Bing/Microsoft, developers, gaming downloads, games, media/entertainment, social/communication, Telegram, connectivity, encrypted DNS and IP diagnostics.
- [lyc8503/sing-box-rules](https://github.com/lyc8503/sing-box-rules): existing CN, advertising and Telegram GeoIP classifiers.
- [KaringX/karing-ruleset](https://github.com/KaringX/karing-ruleset): existing WeChat and China domain/IP classifiers.
- [HaGeZi via razaxq](https://github.com/razaxq/dns-blocklists-sing-box): light advertising/tracking classifier. Copyright/anti-piracy lists are not part of the default advertising policy.
- [SukkaLab/ruleset.skk.moe](https://github.com/SukkaLab/ruleset.skk.moe/blob/master/sing-box/ip/ai.json): ChatGPT Voice IPs, generated from OpenAI's published feed.

Build hooks resolve immutable upstream revisions, download the referenced files,
and package local rule sets. New upstream data arrives with a new build; ordinary
subscription refresh does not update these classifiers. Startup works without
fetching rules from GitHub. Build state records the resolved revisions.

## Policy that remains local

MagicNet retains mode selection, per-app choices, LAN and reserved addresses,
the explicit domestic connectivity probe exception, and the mapping from a
classifier to a selector. These are device/product policy, not business lists.
No generic `analytics`, `tracker`, `github`, or `captive` substring routing remains.

Rule ordering gives explicit modes precedence, protects LAN traffic, applies
native app hints, and uses maintained advertising classifiers before general
business classification. Specific AI services precede general AI; iCloud precedes
Apple; Bing and development/game services precede Microsoft. Gaming download
endpoints precede gaming login/community traffic. Telegram precedes general
communication. Known business domains precede generic country IP ownership.

Domestic and LAN selectors default to direct. Advertising defaults to block.
Foreign service selectors default to proxy; AI selectors remain fail-closed
until subscriptions populate them. User selector choices remain supported.
DNS domain classifiers use the same ordering and matching conditions as route
classifiers. Direct service classes resolve through local encrypted DNS; proxy
classes through the remote resolvers. IP/protocol-only routes are not copied into
DNS rules. Manual DNS-profile overrides retain their existing behavior.

## Validation

`python3 scripts/test-maintained-routing.py` checks references, selector defaults,
ordering and DNS/route classifier parity without requiring downloads.
`--assets` additionally calls the sing-box matcher on actual bundled upstream
files for TCP/UDP first-match cases, DNS ownership, explicit modes, LAN,
advertising, voice ports, foreign-service/CN-IP overlap and keyword false positives.
Legacy embedded-list tests remain available for legacy templates.
