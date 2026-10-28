# 人类 CLI 合同

来源：固定提交的 commands.rs 命令登记。以下为公开用法，不包含实现。

| 命令 | 参数 |
| --- | --- |
| service | {status / start / ensure / stop / restart [current / sing-box] / toggle sing-box / logs [webui / sing-box / mcp / fswatch / supervisors / filename] [lines]} |
| supervisor | {status / start / stop / restart} [fswatch / wifi-policy / all] |
| state | reconcile |
| health |  |
| pingtest |  |
| speedtest |  |
| topology |  |
| ecapture | {status / version / help [tls / gotls / nspr / pcap] / tls [seconds] [pid / all] [uid / all] / gotls [seconds] [pid / all] [uid / all] / nspr [seconds] [pid / all] [uid / all] / pcap [seconds] <ifname> [pcap-filter ...]} |
| sysroute | {list / snapshot / add-rule <priority> <table> / del-rule <priority> / add-route <table> <dest / default> <dev> [via] / del-route <table> <dest / default>} |
| repair |  |
| support | bundle |
| setup | <subscription-url> |
| config | apply |
| override | {status / inspect / preview-file <payload> / set-file <payload> / reset-file <payload> / apply-file <payload> / apply} --json |
| config-editor | {get / path / validate / save / save-file / sync-template} <sing-box / all> [base64-config / webui-payload-path]  /  repo {get / get-json / set / set-file / reset} [base64-json / webui-payload-path] |
| transparent | {status / set tun / set ebpf / apply} |
| network-access | {status / inspect / check <candidate> / repair <candidate> --confirm / reapply <candidate> --confirm / rollback <candidate> --confirm} |
| network | {status / set <ipv4_only / prefer_ipv4 / prefer_ipv6> <mtu:1280-1500> <udp-timeout:1m / 3m / 5m / 10m / 15m / 30m> / apply} |
| core | {status / selected / select sing-box} |
| node | {list / current / use / test <name> / test-all [name ...]} |
| chain | {status / enable / disable / set-upstream <tag> / set-exit <tag> / clear-upstream / clear-exit / mode <manual / auto> / select-upstream <tag> / select-exit <tag>} |
| mode | [rule / global / direct] |
| wifi | {status / enable / disable / mode <blacklist / whitelist> / interval <3-300> / add-ssid <ssid> / remove-ssid <ssid> / add-bssid <mac> / remove-bssid <mac> / check} |
| tailscale | {status / enable <revision> / disable <revision> / logout <revision>} |
| hotspot | {status / enable / disable / reconcile} |
| route | {list / add-domain <proxy / direct / block / warp> <domain-suffix> / remove-domain <proxy / direct / block / warp> <domain-suffix> / apply} |
| dns | {status / set <default / cloudflare-doh / cloudflare-dot / cloudflare-udp> / test [domain] / apply} |
| warp | {status / import-file <wireguard-conf-path> / enable / disable / global / rule / apply / test} |
| sub | {update <sing-box / all> / update-all / clear / status / schedule {status / set <off / 12 / 24 / 48 / 72>} / user-agent {get / set <base64-value> / clear} / filter {list / set <base64-lines> / clear} / list / get sing-box / set sing-box <url> / set-file sing-box <base64-lines> / apply-file sing-box <base64-lines> / file [sing-box]} |
| block | {list / enable / disable / community <on / off> / url <http-url> / update / add-domain <suffix> / remove-domain <suffix> / allow-rule <rule> / unallow-rule <rule> / diff / apply} |
| mcp | {status / enable [bind] [port] / disable / set [bind] [port] / secret / rotate-secret / start / stop / restart / logs [lines]} |
| webui | {status / verify / install-local <https-download-url> <sha256> [name] / payload {create <tmp / subscription> <safe-basename> / append <tmp / subscription> <safe-basename> <base64-chunk> / remove <tmp / subscription> <safe-basename> / apply-subscription <safe-basename> / apply-subscription-source <safe-basename>}} |
| backup | {export [password] / restore [password / -] <base64> / restore-file [password / -] <path>} |
| api | {endpoint / ui [current / sing-box / all] / groups / proxies / select <group> <node> / conns / stats / close <id> / close-top [count] / close-matching <query> / close-all} |
| app | {list / packages [query] / recommendations / mode <blacklist / whitelist> / add <package> [proxy / direct / bypass] / add-many <proxy / direct / bypass> <package...> / remove <package> [proxy / direct / bypass] / apply}; proxy=sing-box proxy outbound, direct=sing-box direct outbound, bypass=outside MagicNet |
| diagnose |  |

参数中的 / 代表可选分支的分隔。准确 argv 必须作为独立参数传递；用户输入不得作为 shell 代码求值。机器写接口在 MACHINE_CONTRACT.md 单独设计，不因存在同名人类命令就自动支持 --json。

`app inspect` 仅在显式 `--json` 机器模式提供私密应用名清单；人类 `app packages [query]` 保留包名兼容路径。
