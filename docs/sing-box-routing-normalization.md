# Modern sing-box routing normalization

## Scope

`hooks/pre-build/5470.optimize_sing_box_routing.sh` applies
`scripts/optimize-sing-box-routing.py` to the packaged `config.json`.
These changes affect that existing build step, not the MagicSingBox submodule
pin, the incremental template downloader, or a device's current configuration.
They do not upgrade the core, download new rule sets, or change subscription
nodes, selector choices, DNS servers, TUN parameters or default outbound tags.

## Routing changes

- For the template's scoped `mixed-in`/`tun-in` sniff followed by DNS hijacking,
  add a port-53 hijack immediately before sniffing. Keep the protocol-based
  fallback for DNS on other ports. Earlier policies and custom inbound rules
  are not bypassed.
- Place the maintained foreign-domain fallback before pure China-IP dispatches.
  Domestic domain exceptions, named services, LAN and explicit modes retain
  their earlier precedence. An IP's country must not override a known foreign
  domain solely because both classifiers match.
- Preserve narrow WeChat priority over advertising without promoting the broad
  Tencent classifier above advertising. No whole-application direct override
  is added. Explicit `action: route` dispatches are accepted alongside the
  implicit spelling; scoped and inverted rules are not treated as pure dispatches.

## Stateful DNS and route actions

sing-box 1.14 DNS `evaluate` does not finish matching: it saves a response for
later `match_response` and `respond` rules. Removing a repeated evaluation can
change which response is returned. Likewise, route `resolve`, `sniff` and
`route-options` can change metadata used by later rules.

The optimizer retains these actions and does not deduplicate terminal rules
across them. Response matches, including nested logical matches, and explicit
mode rules are ordering barriers. Only adjacent pure rule-set dispatches with
the same target are compacted.

This is not a general schema migrator. Domain-only DNS rules do not need an
extra evaluation step. Legacy DNS address-filter migration and missing local
rule-set assets must be checked separately against the deployed core.

## Validation

```sh
python3 scripts/test-routing-optimizer.py
python3 scripts/test-routing-modern.py
bash scripts/test-host.sh
# Requires prepared local rule sets and the matching sing-box core:
bash scripts/test-host.sh --with-routing-assets
```

The new tests cover synthetic classifier overlaps, stateful DNS evaluation,
custom/scoped rules, idempotence and atomic file replacement. They do not prove
real-world speed, DNS availability or Android networking behavior. Before
activation, validate the candidate using the deployed core's `sing-box check`
with the correct working directory and rule-set assets. Work on a backup copy;
the optimizer rewrites its input and does not manage service lifecycle locks.

Stopping-service firewall cleanup and the previously reported loss of network
connectivity are separate from this configuration normalization.

## References

- [sing-box migration guide](https://sing-box.sagernet.org/migration/)
- [DNS rule actions](https://sing-box.sagernet.org/configuration/dns/rule_action/)
- [Route rule actions](https://sing-box.sagernet.org/configuration/route/rule_action/)
- [Maintained classifiers and selector policy](maintained-routing.md)
