# MagicNet Next-Gen Architecture

MagicNet is a sing-box TUN network orchestrator. The orchestrator decides where flows go while sing-box owns transparent capture through the root-managed `magicnet0` TUN.

## Goals

- Do not call Android `VpnService.establish()` or claim the system VPN slot from an app process.
- Provide one routing plane for multiple outbound types: SOCKS5, HTTP CONNECT, sing-box selectors, and direct sockets.
- Keep dynamic policy routing hot-reloadable through CLI, WebUI, MCP, and local config files.
- Keep the existing root/sing-box TUN path as the only transparent capture mode.

## Runtime modes

| Mode | Packet ownership | MagicNet role | System VPN conflict |
| --- | --- | --- | --- |
| `tun` | sing-box TUN (`magicnet0`) | Transparent TUN plus policy router | Root TUN path; no app `VpnService.establish()` |

`tun` is the only accepted mode. Legacy `proxy`, `external-tun`, and `hybrid` configuration values are normalized to `tun`.

## Data plane

```text
Android apps
        │
        ▼
MagicNet input layer
  - mixed proxy listener (SOCKS5 + HTTP CONNECT)
  - sing-box TUN input
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

- CLI: `cli transparent set tun` and `cli route ...`.
- WebUI: calls the same CLI paths.
- MCP: exposes `magicnet_transparent_set` with the same mode enum.
- Config files: `.config/magicnet/transparent-mode.conf`, route lists, app policy lists, and sing-box config.

## Non-goals

- Reintroducing the deleted TProxy data path.
- Auto-promoting unfinished eBPF redirect data plane to netd `ALLOW_MULTI` before `TUN` fallback.
- Taking ownership of Android's app-level `VpnService` slot.
