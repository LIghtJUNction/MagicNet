# Network recovery and diagnostic scope — v1.5.6

## Changes made after reports #304 and #305

The exported reports had a head/tail splice in the middle of route evidence.
They did not preserve a failed Google Play request. A successful unrelated active
connection is not evidence of working Play search, images, authentication or downloads.
Do not close the device incident solely because this patch builds.

The production changes in this patch address independently reproducible defects:

- An available IPv6 OUTPUT DNS redirect previously pointed to a port with only
  an IPv4 loopback listener. Dual-family configurations now provide `::1` as well
  as `127.0.0.1`, with both exact inbound tags handled by the DNS action. No public
  or wildcard listener is introduced. Switching to IPv4-only removes stale IPv6
  redirects before reporting success.
- A missing optional legacy IPv6 NAT table is a capability result in IPv4-first
  mode, not an exception that must be repaired by installing tables. Legacy proc
  evidence is not applied to the nft backend. Permission and timeout errors
  remain failures. IPv6-first requirements are not silently waived.
- Existing DNS chains are compared to the expected rules and OUTPUT order. A
  correct configuration is left unchanged. Rebuilds detach only the owned jump,
  assemble the owned chain, then attach it. A failed detach cannot be followed
  by flushing a still-attached chain.
- Stale route cleanup never flushes all of table 2022. It is restricted to
  `dev magicnet0`, requires a stopped core, and refuses foreign entries or
  unreadable ownership evidence. A matching hotspot interface/table alone does
  not authorize deletion. Failed cleanup preserves private recovery journals.
- New optional DNS guard rules carry `magicnet-dns-guard` ownership comments.
  Legacy unlabelled rules are eligible only on journal-recorded interfaces.
  A foreign lookalike REJECT rule is not adopted, and failure to read a rule set
  is not interpreted as an empty rule set. Ownership is journaled before writes.

The changes do not select a new subscription node, force Google traffic direct,
upgrade the sing-tun stack, add netd rules, or alter unrelated routes. They do not
prove the affected phone's Play failure has been fixed.

## Feedback and observation

The WebUI keeps complete lines within its URL budget and requests a separate
sanitized text-file download. The download request is not called a confirmed
save. The complete text is also retained on the output page. Users must review
and attach the text file themselves; no account, subscription or raw capture is
uploaded automatically.

Network/DNS/readiness facts precede active flow samples. Google/Play service
samples are prioritized before the sample limit, and intentional policy blocks
are counted separately. The report explicitly states that closed/failed flows
are not represented by `/connections`. A warning containing the word `failed`
is counted once as a warning rather than additionally as an error.

`support bundle` adds bounded owned-process RSS, anonymous/file/shared memory,
PSS/private/swap values where readable, and active rule-set/Tailscale endpoint
counts. Process identity is checked before and after the snapshot; unavailable
fields remain unknown. No environment, maps, command-line or private config is
exported. Support collection and Tailscale status reads no longer implicitly
publish/reconcile machine state.

## Memory investigation (not an Android benchmark)

The exact v1.5.5 fork, `495fb0c8006c99ff37d87136267136022c7ea739`, was built with
Go 1.26.7 for Linux amd64 using the module's build tags. The released 53 SRS files
and configuration were tested on this host with no inbounds, no Tailscale
endpoints, no experimental API, and no app traffic. Only direct/block/selector
outbounds exist in this bundled template. `GOMEMLIMIT=384MiB`; three samples
were taken at 3, 6 and 9 seconds. These are short idle observations, not a
long-running leak test. The snapshot data is in `network-memory-v1.5.5-host.json`.

| Variant | RSS (KiB) | Anonymous (KiB) | File-backed (KiB) |
| --- | ---: | ---: | ---: |
| Minimal direct configuration | 54,376 | 7,984 | 46,392 |
| Bundled configuration with 53 rule sets | 72,736 | 24,376 | 48,360 |
| Rule sets with minimal direct routing | 61,280 | 14,192 | 47,088 |
| Bundled configuration without rule sets | 55,660 | 9,140 | 46,520 |

This comparison accounts for a substantial baseline and roughly 17–18 MiB of
additional RSS in the full routing/rule-set configuration. It does not attribute
the phone's reported 100 MB to a leak or to Tailscale. The core API's `memory`
value is retained Go memory (`StackInuse + HeapInuse + HeapIdle - HeapReleased`),
not total process RSS and not solely live heap allocations. Reports label it
`go_retained_bytes`; RSS is not replaced with that smaller number. The runtime
memory limit was not lowered to make the display appear better.

## Tailscale

Continuing browser login on an unchanged configured endpoint is read-only; it
no longer restarts all proxied connections. Saving changed configuration still
uses the existing validated private transaction. Removal requires confirmation.
Unknown connection state is distinct from offline/online, stale responses cannot
repopulate an inactive page, and hidden/inactive pages stop polling. Hostname is
shared by both methods; the optional key form is collapsed, long metadata and
actions wrap on narrow viewports, and keys are cleared when leaving the page.

## Checks and limits

The exact built fork was executed against a controlled local DNS responder over
IPv4 TCP, IPv4 UDP, IPv6 TCP and IPv6 UDP. This is a real socket/listener check,
not a mock of the request result. Stateful firewall fixtures check rule order,
no-op reapplication, family cleanup, failure propagation and foreign-rule
preservation. Page tests execute stale-read/save and destructive-confirmation
paths. CI executes the complete build, host, Rust and browser checks before
release; their run results are recorded in the release/PR, not asserted here.

Actual Play/GMS downloads, Android TUN interception on the reported phone,
Wi-Fi/cellular handover and long-term memory growth still need device evidence.
The new TUN-stack migration (#261) and repository administration (#281) are not
silently declared complete by this patch.
