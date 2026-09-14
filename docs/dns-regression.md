# DNS capture regression contract

The TUN DNS OUTPUT jump must precede sing-box's auto_redirect jump. An existing
`iptables -C` match proves membership, not order. DNAT/REDIRECT terminates NAT
traversal, so a later DNS jump cannot recover an already-diverted query.

The installer builds UDP and TCP rules before publishing a new jump. Reapply
normalizes the owned jump order; the existing `service ensure` watchdog checks
and repairs later displacement without restarting the core. Healthy checks are
read-only and do not wait for the configuration lock. Repairs recheck liveness
under that lock. Stop also removes old port-scoped diagnostic workaround jumps.
Foreign OUTPUT rules and the existing mark/app-bypass policy are preserved.

## Tests

- `python3 scripts/test-dns-capture-order.py -v`: production shell with a
  persistent firewall model, including failed writes, duplicates, network-rule
  reordering, stop/start, stop races, and IPv6 NAT absence. No root required.
- `python3 scripts/test-dns-capture-netns.py`: real UDP/TCP packets through the
  production rules on both iptables-legacy and iptables-nft. Requires Linux,
  iptables, iproute2, util-linux, Python 3, and root or passwordless sudo. It
  refuses to edit the firewall without a newly created network namespace.

The kernel test covers A and AAAA over IPv4 and IPv6, four socket UIDs including
root/netd, Google and non-Google query names, NXDOMAIN, truncated UDP responses
retried over TCP, and non-DNS TCP preservation. It deliberately reproduces the
broken order before testing watchdog repair, then exercises cleanup/reinstall.
All DNS replies are local synthetic fixtures: no subscription or public DNS is
used. The shared CI/release shell gate runs this test and fingerprints backend
and kernel versions in addition to the normal source-addressed success cache.
A dedicated DNS workflow gives early feedback without building other components.

These checks are NOT Android acceptance or proof that public websites/accounts
work. Before release, verify actual Google app login/download and representative
non-Google browsing on a rooted device, including Wi-Fi/cellular transitions,
core restart, selected DNS profiles, and the device's IPv6 capabilities. Never
publish raw account, subscription, resolver, or node logs as test fixtures.
