# MCP control plane

MagicNet's authenticated `/mcp` endpoint exposes named tools, JSON status
resources and two reusable prompts. Bind to loopback by default and use an ADB
forward for host access. Do not paste the bearer secret into logs or issue reports.

## Discovery

`initialize` negotiates the supported `2025-03-26` / `2025-06-18` protocol revisions.
The server advertises tools, resources and prompts. `ping` is supported;
notifications receive HTTP 202 with no JSON-RPC response and never execute tools.

`tools/list` remains the tool catalog. Every tool has explicit read-only,
destructive, idempotent and open-world hints. These are client hints, not
an authorization mechanism. The server independently validates types, required
fields, enums, numeric bounds, array sizes and unknown properties before dispatch.
Machine JSON results are also available as `structuredContent`; the text form
remains for existing clients.

Protocol reference: [MCP tools, 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/server/tools).

## Added tools

- Redacted state: `magicnet_capabilities`, `magicnet_transparent_status`,
  `magicnet_dns_status`, `magicnet_network_status`, `magicnet_subscription_status`,
  `magicnet_wifi_status`, `magicnet_hotspot_status`. `magicnet_network_status` reports configured and
  effective IPv6 mode, MTU, UDP timeout, DNS capture port and TUN CIDRs.
- Persistent overrides: `magicnet_override_status`, `magicnet_override_inspect`,
  `magicnet_override_preview`, `magicnet_override_set`, `magicnet_override_reset`,
  `magicnet_override_apply`. Inspect is explicitly private; saving is separate
  from activation. See [the override contract](config-overrides.md).
- Network controls: `magicnet_network_set`, `magicnet_dns_set`,
  `magicnet_dns_test`.
- Nodes and connections: `magicnet_node_list`, `magicnet_node_current`,
  `magicnet_node_test`, `magicnet_selector_select`, `magicnet_connection_close`.
- Maintenance: `magicnet_subscription_schedule`, `magicnet_route_domain`,
  `magicnet_supervisor_control`.

Existing service, subscription, application-policy, blocklist, backup, log,
eCapture and config-editor tools remain available. The generic CLI tool remains
an explicit argv interface, never an arbitrary shell interpreter. Private tools
can reveal configuration and traffic details; do not call them automatically for
ordinary status summaries. Captures and throughput tests remain intentional,
bounded actions.

The generic `magicnet_file_list` / `magicnet_file_read` tools refuse credential
files and their staging/backup names, the `.config/sing-box` tree, module-update
intent (`.config/magicnet/module-update.conf`), Wi-Fi SSID/BSSID lists
(`.config/magicnet/wifi-ssid.list` / `wifi-bssid.list`), runtime logs and capture
output under `.log`, and private runtime trees under `.state` (`sing-box`,
`transparent-transaction`, `override-materialization`, installer config,
onboarding scratch, `module-update` download state, and `wifi-policy`
last-state copies). These trees hold subscription sources, node credentials,
Tailscale identities, whole-config recovery copies, SSID/BSSID watch text,
and eCapture payloads under names such as `old-url` or `input-source`.
In-module symlink aliases receive the same checks. Public canonical state under
`.state/machines` remains readable. `magicnet_log_read` always redacts URLs and
secrets; the `redact` argument cannot disable that over MCP. Use
`magicnet_log_read` / `magicnet_log_list` for logs, and the explicitly private
config editor, override inspect or subscription tools when the user requests
those contents.

The generic `magicnet_cli` tool refuses the same private dumps: `mcp secret`,
`sub get` / `list` / `file` / `copy-path` / `inspect`, `sub user-agent` (including
the default `get`), `sub filter` (including the default `list`), human `sub
status` and `wifi` status / `list` / `check` / `watch` (omitted wifi action
defaults to status; use `--json` for the redacted machine envelopes),
`config-editor get` / `path` and repository getters, `backup` (including the
default `export`), `override inspect`, `wifi inspect`, `network-access inspect`,
raw `service` / `mcp` logs, human `diagnose` (unredacted sing-box log excerpts),
and internal commands whose name starts with `__`.
Ordinary command arguments, such as node names or SSIDs, may still start with `__`.
`magicnet_service_control` / `magicnet_mcp_control` log tails go through
`magicnet_log_read` redaction. Use those named tools instead of generic argv.

## Read-only resources

`resources/list` advertises these fixed URIs:

```text
magicnet://status/service
magicnet://status/transparent
magicnet://status/dns
magicnet://status/network
magicnet://status/subscription
magicnet://status/wifi
magicnet://status/overrides
```

`resources/read` returns the existing schema-1 machine envelope as JSON. Unknown
resources fail; the server never interprets a resource URI as a filesystem path.
These resources do not expose subscription URLs, SSIDs, node names or patches.

## Prompts

`diagnose-network` guides evidence-first diagnosis and distinguishes HTTP delay
from ICMP latency. `edit-config-overrides` describes preview, expected revision,
conflict handling, application and reset without embedding private configuration.

### Android application network policies

`magicnet_network_access_status` reads redacted OS policy counts through the
schema-1 machine interface. `magicnet_network_access_inspect` explicitly includes
installed package names and shared identities; keep this output private.
Neither tool changes policy or implies that application DNS is working. Missing
providers and unreadable observations remain unsupported/unknown. Repair is not
exposed by these tools; see issue #329 for the remaining recovery work.

`magicnet_app_inspect` 是主用户应用名/包名的显式私密只读 named tool，不进入自动资源、汇总或诊断；generic `magicnet_cli` 的 `app inspect`（无论 --json 位置）拒绝执行，不能绕过私密边界。完整目录现在为 85 个工具；风险 hints 不是操作授权。
