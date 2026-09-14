# DNS capture regression coverage

`network.sh` must place exactly one unconditional `magicnet-dns-output` jump at the
front of NAT OUTPUT after every successful capture application. Checking `-C`
alone is insufficient: a core restart can prepend `sing-box-output`, whose UDP DNS
DNAT terminates NAT traversal before MagicNet's local port-1053 listener is reached.
This is independent of website name; do not fix it with Google-only routing rules.

The installer now removes duplicate and temporary TCP/UDP port-53 jump forms,
then prepends its jump after the capture chain's redirects and exemptions are
ready. Cleanup removes the same owned forms. Foreign chains are never flushed.
Existing UID bypass, marked resolver loop prevention, eBPF ownership and the
IPv6-NAT capability policy remain unchanged. This is lifecycle reconciliation,
not a claim that arbitrary third-party firewall rewrites cannot occur later.

## Required host regressions

Run `python3 scripts/test-dns-output-order.py`. The normal `scripts/test-host.sh`
entrypoint and its successful-only content-addressed cache include this suite.
Changes to the source, tests or workflow invalidate the host cache.

The stateful fixture executes the production shell in sh, bash and, when
available, BusyBox ash. It preserves OUTPUT order and models DNAT/REDIRECT as
terminal NAT verdicts, rather than always reporting that rules are absent. It
checks fresh setup, the pre-existing wrong order, restart/reapplication,
duplicates, temporary-rule migration, disable/stop, both DNS transports,
IPv4/IPv6, root/netd and Google/application UIDs, bypasses, marks, non-DNS traffic,
custom ports, missing IPv6 NAT, permission failures and bounded deletion errors.
The stale-order test fails against the pre-fix source in all three shells.

## Real kernel packet regression

Run `python3 scripts/test-dns-kernel.py --require` on Linux with `iproute2`,
`iptables`, `ip6tables`, `unshare`, and root or passwordless sudo. All network
changes occur in a newly created network namespace. The script refuses to run
its mutating fixture in its parent's network namespace. The Network regression
workflow runs it with `--require`: missing tools/capabilities are not a pass.

This fixture uses real UDP/TCP sockets, real IPv4/IPv6 NAT and the production
installer. It first creates the competing DNAT black hole, verifies failure,
then reapplies capture and verifies A/AAAA answers for every hostname in the
shared HTTPS corpus plus Google authentication/service DNS names. It checks
priority, duplicate removal and stop cleanup. Replies use documentation/benchmark
addresses from a local server; no public DNS or subscription is involved.

## Website and device acceptance are separate

Keep `scripts/test-network-check.py` and the existing HTTPS endpoint observation.
They cover strict HTTP results, redirects, DNS/connect/TLS errors, timeouts and
capability gaps. A 403, 404, 429, or DNS error must not be converted into success.
Runner internet observations remain labelled as observations, not Android proof.

After installing the built module, device acceptance still requires the Android
system resolver and affected apps, Google sign-in/Play loading and downloading,
representative domestic/global websites, restart and Wi-Fi/cellular transitions.
A Termux or explicit SOCKS success alone is not sufficient. Preserve failure
statuses and identify unsupported transports; do not silently fall back and call
them passed. Never commit device logs, account identifiers or subscription URLs.
