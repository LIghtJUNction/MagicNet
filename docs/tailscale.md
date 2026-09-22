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

## Disable, resume, and sign out

The WebUI connection card separates **Disable Tailscale** from **Sign out of this
device**. Disabling removes active Tailscale endpoints and MagicNet-owned DNS and
routing references from the validated configuration. The endpoint settings are
kept in the private `.config/sing-box/tailscale-paused.json` file; the protected
Auth key and local identity are preserved for **Resume connection**. An ordinary
core restart does not restore the removed endpoint. A stopped core remains stopped.

Signing out first stops the module-owned core and confirms it has stopped, then
persists a configuration without Tailscale and clears the protected Auth key.
It removes only MagicNet's dedicated `.state/sing-box/tailscale` identity directory.
The cloud device record is not revoked or deleted; use the device console to
remove that record. A custom state directory is never recursively deleted by this
operation. If cleanup fails, disabled intent and a `logout-pending` phase remain
on disk, and resume is blocked until cleanup is completed. This is local sign-out,
not deletion of a Tailscale account.

Commands use the revision returned by `cli --json tailscale status`:

```text
cli tailscale disable <revision>
cli tailscale enable <revision>
cli tailscale logout <revision>
```

The machine status is an observation-only schema-1 envelope named
`tailscale.status`. Its data fields are `enabled` (configured intent), `resumable`,
`logout_pending`, `local_identity` (boolean or null for unknown), `revision`, and
`core` (`running`, `stopped`, or `unknown`). It creates no state or lock files and
contains no device name, key, URL, or identity data. Online/login confirmation
continues to use the authenticated local Tailscale status API, not this intent
snapshot. The capabilities response advertises `tailscale.status`.

Mutations serialize with the existing core lifecycle lock, re-check the revision
before committing, validate the candidate configuration, and use recoverable
multi-file replacement. Custom references are rejected rather than silently
removed or routed directly. A failed enable rolls back to the disabled settings;
a failed disable or logout never rolls back into an unwanted login. The UI checks
the exit status and re-reads the machine snapshot before showing success.

Regression coverage includes enabled → disabled → enabled, local sign-out from
enabled/paused/legacy-residue states, repeated commands, stopped/unknown runtimes,
stop and restart failures, custom references and state directories, path symlinks,
concurrent revisions, pending cleanup, navigation races, double submission, and
320/360/390/430-pixel, landscape, and desktop WebUI layouts. Browser fixtures do not
constitute a real-device Tailscale connectivity test.
