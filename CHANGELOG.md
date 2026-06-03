## Unreleased

## v1.1.0 (2026-06-03)

- Use `magicnet0` as the default MagicNet virtual interface name for both
  sing-box and mihomo templates, avoiding collisions with generic `tun0` used
  by other VPN clients.
- Document the Rust CLI and MCP server layout under `.local/bin`, while keeping
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
