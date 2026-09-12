# WebUI network setup

## Tailscale browser login

Select **Log in to Tailscale and configure automatically** in the WebUI. MagicNet
validates and saves a persistent userspace Tailscale endpoint, restarts sing-box,
and opens the device authorization URL reported by that endpoint. No separate
Tailscale app or copied Auth key is required. Existing key-based setup remains
available; existing accounts and custom control servers are not silently reset.

The runtime adds Tailnet IP routing and a Tailscale DNS server for `*.ts.net`.
Login state stays in the endpoint's private state directory. Returning to the
WebUI polls the core; it reports connected only for Running + online. Device
approval or unavailable network connectivity may still require user action.
Polling is bounded and can be restarted with Refresh login status.

Browser setup creates a random `experimental.clash_api.tailscale_secret` when
needed. This protects only the login-status endpoint and leaves existing Clash
API clients unchanged. An existing global API secret takes precedence. CLI
requests are restricted to loopback, bypass HTTP proxies, and send the secret
through curl stdin rather than argv. Login links are not copied or logged by
the WebUI. Only official `https://login.tailscale.com/a/...` links are opened.

## Hotspot forwarding

Hotspot discovery supports `ap0`/bridged AP names and Android's per-interface
routing tables. TUN interception installs narrow IPv4 FORWARD rules from the
confirmed downstream interface to `magicnet0`, and permits established return
traffic. Cleanup removes only the rules owned by MagicNet.

The WebUI distinguishes configured, waiting-for-hotspot and degraded states.
TUN readiness requires routing and forwarding rules for every detected interface.
Discovery errors cannot be reported as an inactive hotspot. eBPF status never
uses `magicnet0` or table 2022 as attachment proof; verify it using
`cli transparent status` and `cli health`.

Host fixtures verify discovery, rule installation/cleanup and API/UI behavior.
They do not prove forwarding on every Android vendor or IPv6 tethering path;
verify with a connected hotspot client on the target device before relying on it.
