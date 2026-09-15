# Tailscale endpoint

MagicNet supports sing-box Tailscale endpoints without creating a second Android TUN. Keep
`system_interface` set to `false`; MagicNet continues to own the single `magicnet0` interface.

Add the endpoint through the validated WebUI JSON editor or `cli config-editor save-file`:

```json
{
  "endpoints": [
    {
      "type": "tailscale",
      "tag": "tailnet",
      "auth_key": "<one-time-auth-key>",
      "state_directory": "",
      "hostname": "",
      "control_url": "",
      "relay_server_port": 0,
      "relay_server_static_endpoints": [],
      "system_interface": false
    }
  ]
}
```

The editor removes `auth_key` from `config.json` and stores it in the private
`.config/sing-box/tailscale-auth.json` sidecar with mode `0600`. Startup injects the key only while
sing-box reads the configuration, then removes it from the editable configuration again. The key
is not included in health output or support bundles.

During every runtime configuration apply, MagicNet:

- keeps the endpoint and its state across subscription refresh and template synchronization;
- removes `100.64.0.0/10` and `fd7a:115c:a1e0::/48` from `tun-in.route_exclude_address` so userspace Tailscale traffic can enter `magicnet0`;
- keeps the normal `lan` CIDR rule intact instead of claiming the entire Tailscale CGNAT range;
- inserts a route rule before the first `lan` rule that combines the Tailscale CIDRs with `preferred_by: ["tailscale"]`, so only MagicDNS names, actual peers, and accepted Tailscale routes use the endpoint;
- keeps an explicit `ts.net` route and MagicDNS server binding for full MagicDNS names.

The `preferred_by` condition is important because `100.64.0.0/10` is shared RFC 6598 CGNAT space,
not a Tailscale-exclusive prefix. A carrier, ISP, or another network can legitimately use addresses
from the same range. Non-Tailscale destinations therefore fall through to the existing `lan`/normal
routing policy instead of being forced into the Tailnet endpoint.

Use `cli health` to inspect `state_created`, `tun_ingress`, and `route_linked`. Runtime acceptance
still uses `cli transparent status`, `cli health`, and the presence of `magicnet0`.
