# MagicNet Next-Gen Architecture

MagicNet is evolving from a VPN-shaped transparent proxy module into a user-space network orchestrator. The orchestrator should decide where flows go, while packet ownership can remain with Android, an external VPN, or sing-box depending on the selected mode.

## Goals

- Do not call Android `VpnService.establish()` or claim the system VPN slot from an app process.
- Keep Clash, WireGuard, sing-box, or another system VPN free to coexist with MagicNet.
- Provide one routing plane for multiple outbound types: SOCKS5, HTTP CONNECT, sing-box selectors, and direct sockets.
- Keep dynamic policy routing hot-reloadable through CLI, WebUI, MCP, and local config files.
- Preserve the existing root/sing-box TUN path as a compatibility mode while making proxy-only operation the preferred zero-conflict mode.

## Runtime modes

| Mode | Packet ownership | MagicNet role | System VPN conflict |
| --- | --- | --- | --- |
| `proxy` | Apps or other tools explicitly use `127.0.0.1:7892` | Local mixed proxy and policy router | None |
| `external-tun` | Clash, WireGuard, or another VPN owns capture | MagicNet consumes forwarded/proxied flows and routes them onward | None |
| `hybrid` | sing-box TUN feeds MagicNet and may chain to other backends | TUN input plus multi-backend router | Root TUN path; no app `VpnService.establish()` |
| `tun` | Legacy-compatible sing-box TUN (`magicnet0`) | Transparent TUN plus policy router | Root TUN path; no app `VpnService.establish()` |

`proxy` is the recommended coexistence mode. `tun` remains the default for existing installs so upgrades do not silently remove transparent capture.

## Data plane

```text
Android apps / external VPN / local proxy clients
        │
        ▼
MagicNet input layer
  - mixed proxy listener (SOCKS5 + HTTP CONNECT)
  - optional sing-box TUN input for hybrid/tun modes
        │
        ▼
MagicNet policy plane
  - domain, app, geo, port, and blocklist rules
  - runtime route list hot reload
  - DNS leak guard and remote DoH detours
        │
        ▼
Outbound router
  - sing-box selector pools
  - SOCKS5/HTTP CONNECT compatible local upstreams
  - direct fallback
```

## Control plane

The existing control surfaces remain the source of truth:

- CLI: `cli transparent set <proxy|external-tun|hybrid|tun>` and `cli route ...`.
- WebUI: calls the same CLI paths.
- MCP: exposes `magicnet_transparent_set` with the same mode enum.
- Config files: `.config/magicnet/transparent-mode.conf`, route lists, app policy lists, and sing-box config.

## Non-goals

- Reintroducing the deleted TProxy data path.
- Auto-promoting unfinished eBPF redirect data plane to netd `ALLOW_MULTI` before `TUN` fallback.
- Taking ownership of Android's app-level `VpnService` slot.
