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
- removes `100.64.0.0/10` and `fd7a:115c:a1e0::/48` from `tun-in.route_exclude_address`;
- removes those CIDRs from the general `lan` rule;
- inserts one route rule for both CIDRs before the first `lan` rule, using the configured endpoint tag;
- restores the canonical exclusions and LAN behavior when no userspace endpoint is configured.

Use `cli health` to inspect `state_created`, `tun_ingress`, and `route_linked`. Runtime acceptance
still uses `cli transparent status`, `cli health`, and the presence of `magicnet0`.
