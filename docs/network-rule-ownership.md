# Network resource ownership and recovery

A status query is not permission to repair the network. Inspection paths must
not add/delete policy rules, flush routes, or install firewall chains.
`ip6tables -t nat -L` is a capability query, not a route-table write. Known missing
IPv6 NAT is an unsupported capability; permissions, lock deadlines and failed
inspection remain errors. IPv4-first operation does not imply IPv6 DNS capture.

## Lifecycle boundaries

The normal configuration/lifecycle lock serializes MagicNet producers. Before
starting a stopped TUN core, a private, boot-bound journal records existing rules
in the configured conventional table/window (2022, priorities 9000–9099 and 32768).
After core/TUN readiness, the journal commits full new rule selectors. Repeating
the observation never adopts rules added later. Pre-existing rules are not owned
merely because their priority or table matches. These conventional indices are
not a generic cleanup API for arbitrary custom routing tables.

Normal core shutdown remains the first owner of its own routes. Only after the
core is confirmed stopped can residual cleanup remove an exact recorded policy
rule and routes targeting `magicnet0`. There is no whole-table flush or heuristic
hotspot orphan scan. Foreign routes in table 2022 and different rules at the same
priority must survive. A competing rule at the same priority/table is treated as ambiguous:
netlink deletion treats some omitted or zero-valued selectors as wildcards, so
printed full selectors alone do not prove an exact deletion. Cleanup refuses the
ambiguous case rather than risking the other rule. Each delete is read back; an unreadable ruleset or a lying
successful delete is not an empty ruleset. Stopped, live and unknown process
states remain distinct. Changing to eBPF clears a verified stopped TUN generation
without installing new TUN state.

A legacy journal or interrupted start may lack enough evidence to attribute a
remaining rule. Such a case fails visibly and retains recovery evidence instead
of guessing ownership. This is unresolved cleanup, not a claimed clean stop.
It may require a verified device-specific recovery; do not clear the journal or
flush the table merely to make the status green.

## Firewall and hotspot transactions

Unchanged DNS capture chains and hotspot rules are inspected and left in place.
Absent exact rules do not receive speculative delete commands. Hotspot routing
uses a private `tun-rules.list.pending` write-ahead journal before the first rule
insertion; only verified installation promotes it to `tun-rules.list`. Cleanup
also marks the installation pending before changing it. Partial apply or rollback
retains the journal, and canonical `hotspot.state` reports `pending`, not `active`.

New DNS leak-guard REJECT rules carry the comment `magicnet-dns-guard`; their
interface journal is published before insertion. Untagged rules belonging to
Android/other modules are not discovered merely by port and physical interface.
Legacy untagged cleanup is restricted to interfaces already in a legacy journal;
a new tagged journal cannot authorize untagged deletion. A failed OUTPUT listing
never falls back to speculative cleanup. Cleanup failures preserve the journal.

These journals are private recovery inputs, not a second public status API.
Existing canonical state reconciliation runs after failed as well as successful
CLI control commands. Route-ownership failures feed the existing canonical
`transparent.recent_error`; successful cleanup clears only its own error token.

The final uninstall hook stops through this same lifecycle and exits with its
actual result. No runtime helper appends blind fallback deleters to the hook;
legacy appended commands cannot run afterward or mask a failed cleanup. Tether
offload restoration compares the current value, refuses conflicting external
changes, and keeps its journal until the restored value is read back correctly.
Repeated enable/restore of the already-correct value does not write settings.

## Regression evidence and limits

`test-kernel-route-lifecycle.sh` executes stateful netlink/firewall fixtures under
sh, bash and BusyBox when available. It verifies same-priority foreign rules,
pre-start baselines, late/replaced rules, scoped table cleanup, repeat no-ops,
unknown liveness, read/delete/readback failures, legacy journals, mode switching,
hotspot write-ahead/rollback, and tagged versus unrelated DNS REJECT rules.
The Rust state regression verifies that an incomplete hotspot transaction is not
published as active. Existing ordered DNS, startup and timeout regressions remain. The GitHub PR and
release host gates also execute a disposable real Linux network namespace,
including colliding-rule insertion orders and scoped cleanup. Namespace creation
failure is a failed test, not an accepted skip. WebUI log classification respects
the declared severity, so one WARN containing "failed" cannot count as both a
warning and an error.

These checks are host fault-injection evidence. They do not establish physical
Android routing behavior, authenticated Google Play/GMS downloads, IPv6 DNS leak
absence, provider compatibility, or reduced Android RSS. Do not use them to close
those independent acceptance issues.
