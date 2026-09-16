# DNS and network-resource ownership repair

Complementary to #306 (feedback, memory and Tailscale), following device reports
#304 and #305. These reports do not retain a failed Google Play flow; do not
claim Play/GMS authentication or downloads pass based on the checks below.

## Runtime fixes

- Dual-family DNS policy now has separate 127.0.0.1 and ::1 listeners on 1053,
  handled by the exact DNS inbound tags. There are no wildcard listeners.
  IPv4-only policy removes the IPv6 listener and stale IPv6 DNS redirect.
- Missing optional legacy IPv6 NAT is a capability outcome in IPv4-first mode.
  A readable legacy proc table registry avoids asking for absent NAT/autoload.
  nft backend, permissions and timeouts remain distinct; IPv6-first required
  capture still fails when unavailable. No kernel table is created as a repair.
- DNS capture compares the complete owned chain and first/single OUTPUT jump.
  Unchanged rules are not rebuilt. Changed rules detach only the owned jump,
  build the complete owned chain and then attach it. A failed detach cannot
  flush a still-attached chain. This is ordered repair, not a claim of atomic
  replacement across both firewall families.
- Route cleanup requires a stopped owned core. Table 2022 is never flushed
  indiscriminately: only dev magicnet0 entries are eligible, and foreign rows
  cause preservation of policy rules and the recovery journal. Unreadable
  route/rule state cannot be interpreted as empty. Hotspot rules are removed
  only through their journaled exact tuples, not a matching iif/table guess.
- Optional DNS guard rules carry magicnet-dns-guard ownership comments. The
  private journal is staged before mutation. Legacy unlabelled rules are
  eligible only on recorded interfaces, not inferred physical links. A foreign
  lookalike REJECT is not adopted; read/cleanup failures retain recovery data.
- Read-only support, route snapshots and Tailscale status no longer trigger
  implicit machine-state publication. Explicit mutating lifecycle paths keep
  their existing reconciliation. The log view gives explicit severity priority,
  so [warn] ... failed is one warning rather than also an error.

This change does not select proxy nodes, force Google direct, change the
production Go memory limit, migrate the TUN stack, or add netd/TProxy routes.
The existing signed release checks remain mandatory.

## Tests

The exact pinned fork was executed against a controlled local DNS server over
IPv4 TCP, IPv4 UDP, IPv6 TCP and IPv6 UDP. The new real-socket test is part of
the module build. Stateful firewall tests cover ordering, no-op reapplication,
IPv4-only cleanup and error propagation. Route/guard tests cover foreign
resources and failed reads without erasing ownership journals. Existing
orchestrator tests validate generated configuration through the real core.

These checks do not establish Android TUN capture, provider compatibility,
physical-device Play/GMS use, handover, or absence of long-term memory growth.
Use the enhanced feedback in #306 to obtain the missing affected-device facts.
