## Unreleased

- Delegate sing-box outbound interface changes to Android instead of relying on
  default-interface auto-detection that can fail on Android 16 policy routes.
- Disable Android tether offload while hotspot Proxy is enabled, then restore
  the previous system value when disabled or uninstalled so tethered traffic
  cannot bypass the TUN through vendor hardware/BPF forwarding.
- Import Clash YAML, base64, share-link, JSON, or text subscription files as a
  persistent local source with atomic URL/local switching and rollback.
- Batch-assign selected installed apps with one confirmation, policy write,
  and core restart.
- Resolve configured app packages to per-user Android UIDs so Bypass TUN and
  whitelist policies install effective kernel routing exclusions instead of
  relying on package-name fields alone.
- Wait for fswatch and the other supervisors before service start/restart
  returns, preventing a transient stopped warning after the core is ready.
- Support validated standalone sing-box JSON configs without requiring a subscription URL.
- Decode JSON Unicode escapes in native VMess share-link names.
- Coordinate userspace Tailscale endpoints with `magicnet0`, preserve endpoints across template
  sync, protect one-time auth keys, and expose route/state health evidence.
- Reapply subscription keyword filters while sanitizing cached/generated
  outbounds so filtered nodes cannot survive through a repair or cache replay.
- Order every AI selector with United States nodes first, Japan second, and
  other eligible regions afterward, while excluding mainland China, Hong Kong,
  and Taiwan labels from all AI groups.

## v1.1.27 (2026-07-28)

- Add a persistent custom User-Agent for subscription downloads, configurable
  from the CLI and WebUI and applied consistently by curl and wget.
- Fix #64 by keeping Android network validation on the automatic healthy-node
  group when the general proxy selector is pinned to a manual node, preventing
  a stalled node from making the system mark Wi-Fi as disconnected.
- Keep ChatGPT remote pairing feature traffic on the pinned ChatGPT path and
  route all X Android action requests before the FakeIP guard.
- Start each AI service selector on its filtered service-specific automatic
  failover group after a subscription provides eligible nodes, while keeping
  zero-node configurations blocked and preserving explicit user selections.
- Resolve WeChat media uploads through the local DNS path and route Tencent
  media domains before the FakeIP loop guard, while preserving Clash mode and
  destination-specific policy precedence.
- Include the redacted startup blocker in support bundles so stopped-core issue
  reports distinguish missing subscriptions or nodes from runtime crashes.
- Add line numbers, JSON syntax highlighting, and live JSON syntax checks to the
  configuration editor.
- Remove the built-in supporter leaderboard.
- Clarify the supported sing-box + `magicnet0` TUN runtime and align device
  diagnostics with `cli transparent status`, `cli health`, and the available
  CLI contract.

## v1.1.23 (2026-07-19)

- Give ChatGPT, Gemini, Grok, and Claude independent `urltest` automatic
  failover while keeping their selectors fail-closed.
- Make first subscription activation atomic, recover interrupted transactions
  from a journal, reuse the SHA-256 identity cache, and serialize owner-safe
  scheduled and manual refreshes.
- Rework the WebUI for first-time and subsequent subscription setup plus refresh
  scheduling, surface structured errno details, produce a single redacted issue
  report per failure, and polish desktop and mobile layouts.

## v1.1.22 (2026-07-17)

- Fix #46 by retrying a failed direct subscription download through the local
  sing-box mixed proxy only when its API confirms that the owned service is
  available; explicit proxy configuration remains fail-closed.

## v1.1.21 (2026-07-16)

- Fix #44 by removing DNS capture and leak-guard rules whenever the core stops,
  keeping runtime configuration inert while stopped, and clearing stale rules
  before subscription refresh or kernel startup.
- Route the dedicated `magicnet-dns-in` listener directly to `hijack-dns`
  without requiring protocol sniffing before the DNS rule can match.
- Add default direct bypasses for Xianyu, Taobao, Pinduoduo, Meituan, Ctrip,
  and Railway 12306 in blacklist app-routing mode.

## v1.1.20 (2026-07-14)

- Add an independent non-China/Hong Kong `ai-proxy` selector and route the
  ChatGPT, Gemini, Grok, and Claude selectors through it while remaining
  fail-closed by default.
- Persist selector choices across subscription activation and service restarts.
- Fetch subscriptions directly by default, with bounded downloader and process
  timeouts plus owner-aware update and configuration locks.
- Make subscription activation transactional and restart only the verified
  owned sing-box process, restoring the previous configuration on failure.

## v1.1.19 (2026-07-14)

- Repair legacy sing-box subscription configurations that are missing the
  fail-closed ChatGPT, Gemini, Grok, and Claude outbound selectors.
- Validate cached AI selectors across jq and no-jq paths, rejecting malformed,
  duplicate, or stale outbound references before rebuilding the subscription.

## v1.1.18 (2026-07-13)

- Fix #40 by normalizing pasted HTTP(S) URLs in the WebUI to canonical hostnames
  and canonicalizing valid CLI allow-rule inputs while rejecting invalid or unsupported values.
- Migrate legacy scheme-bearing `ad-allow` rules atomically and idempotently,
  validated with real-device A/B tests of the allow and block paths.

## v1.1.17 (2026-07-13)

- Fix #36 by making `ad-allow` inherit the normal `final` policy by default,
  while preserving explicit Direct and Proxy overrides across bundled, jq,
  no-jq, and upgrade-generated configurations.
- Fix #37 by adding a high-priority package rule for Proxy-listed apps and
  restarting sing-box after app policy changes so the selected policy takes
  effect immediately.
- Update Proxy/Bypass lists transactionally during multi-app changes to avoid
  partially applied policy state.

## v1.1.16 (2026-07-12)

- Fix #34 with an explicit delete action for ad allowlist chips, and refresh
  blocklist state after removal so community rules return to the community list
  while manually added entries do not.

## v1.1.15 (2026-07-11)

- Add a prioritized ad allowlist routed through selectable `direct` or `proxy`
  outbounds, make `ad-block` selectable between `block`, `direct`, and `proxy`,
  and expose allowlist rule management in the WebUI.
- Add independent fail-closed `ai-chatgpt`, `ai-gemini`, `ai-grok`, and
  `ai-claude` selectors pinned only to explicit eligible nodes.
- Exclude mainland China and Hong Kong labels, including Hong Kong variants and
  standalone `HK` or `HKG`, from pinned AI selectors without boundary false
  positives.

## v1.1.14 (2026-07-11)

- Set the managed sing-box TUN MTU to 1400 to mitigate slow uploads.
- Generate compact, size-bounded unified diffs for configuration issues instead
  of embedding truncated full configurations in issue URLs.
- Use fail-closed structural redaction so node endpoints, credentials, and
  arbitrary private configuration values cannot leak into issue drafts.

## v1.1.13 (2026-07-11)

- Fix #24 by allowing long mobile WebUI text to scroll horizontally while
  preserving page zoom and pinch gestures.
- Keep the top WebUI controls on a single line with a compact narrow-screen
  layout.
- Move the KAM dev staging path to `/sdcard/Download/MagicNet`.

## v1.1.12 (2026-07-10)

- Add a WebUI control workspace with functional diagnostic and configuration
  preview tools.
- Recover routing after interface changes, and improve CLI backup and help
  flows plus default node handling.
- Update the bundled MagicBox and Zashboard revisions.
- Preserve AnyTLS and TUIC nodes during subscription imports, with packaged
  regression coverage.
- Remove tracked local runtime state from the repository.

## v1.1.11 (2026-06-30)

- Avoid manager/non-TTY install hangs by skipping MagicNet interactive prompts
  unless the installer has a real TTY.
- Add install smoke coverage for manager-style installs with
  `MAGICNET_NONINTERACTIVE` unset.
- Route Google China traffic through `proxy` and update the KAM framework
  submodule to the fetchable language install revision.
- Document how to add nodes through WebUI subscriptions or `cli setup`.

## v1.1.10 (2026-06-26)

- Fix multi-subscription share-link aggregation so proxylink sees every source
  before import.
- Fall back when proxylink emits fewer valid nodes than the extractor
  collected, instead of reporting a misleadingly short list.
- Refresh node list cache and current-config parsing to avoid stale node counts
  and other misleading summaries.
- Remove stale runtime packaging flags from the module artifact and document
  that runtime executables belong in `bin/`, not legacy `.local/bin`.
- Simplify generated sing-box subscription selectors by removing fixed region
  buckets such as `hk` and `jp`; imported nodes now stay under `proxy` and
  rule selectors point to `proxy` or `direct`.
- Speed up sing-box startup by treating a stable sing-box process as ready
  instead of waiting for the Clash/WebUI API port.

## v1.1.9 (2026-06-26)

- Capture Android system DNS queries on port 53 into a local sing-box DNS
  inbound so app traffic is not seeded with carrier-poisoned domain answers.
- Keep the DNS capture chain removable when MagicNet is disabled and skip it
  for the UDP Cloudflare DNS profile to avoid self-redirect loops.

## v1.1.8 (2026-06-21)

- Remove eBPF, TProxy, and non-TUN transparent mode support from the runtime,
  CLI, WebUI, MCP schema, build pipeline, and smoke tests.
- Keep MagicNet on the single stable `sing-box` + `magicnet0` TUN path.
- Add MagicBox as a submodule and limit its transparent controls to TUN mode.

## v1.1.7 (2026-06-21)

- Refine eBPF transparent mode into a TCP bridge profile with TUN kept as the
  compatibility fallback for UDP-sensitive traffic.
- Remove the unfinished UDP bridge/TProxy main path and keep only migration
  cleanup for stale UDP TProxy chains.
- Split large eBPF and diagnostics modules so individual source files stay
  below 500 lines and the TCP/eBPF health checks are easier to audit.

## v1.1.6 (2026-06-20)

- Add a WebUI issue creation action that copies the full diagnostic context to
  the clipboard and opens a short prefilled GitHub issue URL.
- Sanitize sing-box subscription fields before JSON emission so CR/LF control
  characters from provider data cannot break generated configs.
- Fix the CLI health check for sing-box DoH servers that use IP addresses with
  `tls.server_name`, avoiding a false `remote_dns_detour=missing` warning.
- Skip local sing-box subscription refresh during normal startup when cached
  nodes are already present, so the core starts immediately and provider-specific
  downloads are left to the core or explicit subscription update commands.

## v1.1.5 (2026-06-14)

- Package runtime executables under `bin/`, including the
  `cli -> bin/magicnet-cli` compatibility entry.
- Add a config editor action to sync the latest upstream mihomo and sing-box
  templates from their template repositories while preserving subscription
  provider/node configuration.
- Add sing-box REDIRECT inbound generation for local TCP capture in TProxy mode
  and verify the paired NAT OUTPUT REDIRECT data path in the fake Magisk smoke.
- Keep sing-box sniff inbound lists aligned with the active transparent mode.
- Add closed-loop local, AVD, and physical-device validation for hotspot shared
  proxy rules, sing-box, mihomo, and VPN coexistence.
- Force subscription refresh before starting sing-box or mihomo and refuse to
  boot with stale cached nodes when the refresh fails.
- Refresh WebUI dependency locks after the esbuild advisory bump.

## v1.1.4 (2026-06-11)

- Show a default `premium_a` mihomo provider slot when config templates do not
  define proxy-providers yet, so WebUI subscription entry is always available.
- Create the missing mihomo `proxy-providers` section when saving a subscription
  and make missing-subscription startup errors point to the exact setup command.
- Let the config editor load a minimal editable template when the real config is
  missing, and rename the hotspot rule button to “重新加载”.

## v1.1.3 (2026-06-11)

- Refine kamfw console output by replacing emoji and decorative status marks
  with concise bracket labels for logs, panels, and volume-key prompts.

## v1.1.2 (2026-06-11)

- Build and package the Vue WebUI during `kam build` so the module archive
  always contains `webroot/index.html` and frontend assets.
- Remove unused standalone hotspot and VPN coexistence wrapper scripts; the
  runtime functions remain wired through MagicNet startup/config flows.

## v1.1.0 (2026-06-03)

- Use `magicnet0` as the default MagicNet virtual interface name for both
  sing-box and mihomo templates, avoiding collisions with generic `tun0` used
  by other VPN clients.
- Document the Rust CLI and MCP server layout under `bin/`, while keeping
  `/data/adb/modules/MagicNet/cli` as the stable compatibility entry.
- Add CLI-managed subscription updates for sing-box and mihomo providers,
  hotspot proxy/direct switching, transparent mode switching, watchdog
  diagnostics, and safer support bundle guidance.
- Refresh README feature docs for the management WebUI, TUN/TProxy modes,
  `magicnet0` diagnostics, hotspot forwarding, VPN coexistence, and dev checks.

## v1.0.38 (2026-06-02)

- Fix hotspot forwarding detection on devices that expose hotspot as a `wlan*`
  interface with a private address in Android's `local_network` route table
  instead of a conventional `.1` gateway address.

## v1.0.37 (2026-06-02)

- Fix VPN coexistence by moving sing-box TUN from the generic `tun0` name to
  `magicnet0`, avoiding interface-name collisions with other VPN clients.
- Enable VPN coexistence handling by default and apply external VPN bypass rules
  before sing-box auto-route interception.
- Keep subscription restart cleanup compatible with both `magicnet0` and legacy
  `tun0` runtime interfaces.
- Route Google, YouTube, AMP, and related domains explicitly through the proxy
  before CN rule sets can match them as direct.

## v1.0.36 (2026-06-02)

- Fix sing-box TUN loopback on Android by using gVisor auto-redirect and binding
  outbound traffic to the detected physical default interface before startup.
- Route Google connectivity checks through the proxy path while keeping Microsoft
  connectivity checks direct.
- Avoid generating unsupported uTLS settings for imported hysteria2 share links.
- Stop sing-box by exact daemon PID instead of `pkill -f`, preventing module
  action shells from killing themselves during restart.

## v1.0.35 (2026-06-01)

## v1.0.34 (2025-12-29)

## v1.0.33 (2025-12-29)

## v1.0.32 (2025-12-28)

## v1.0.31 (2025-12-28)

## v1.0.30 (2025-12-29)

## v1.0.29 (2025-12-29)

## v1.0.28 (2025-12-28)

## v1.0.27 (2025-12-28)

## v1.0.25 (2025-12-28)

## v1.0.24 (2025-12-27)

## v1.0.23 (2025-12-27)

## v1.0.19 (2025-12-26)

## v1.0.18 (2025-12-26)

## v1.0.17 (2025-12-26)

## v1.0.16 (2025-12-25)

## v1.0.15 (2025-12-25)
