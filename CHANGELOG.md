## Unreleased

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
