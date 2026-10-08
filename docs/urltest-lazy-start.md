# Generated URLTest groups start on demand

MagicNet enables the bundled sing-box fork's `lazy_start: true` option on
`proxy-auto`, the four AI `*-auto` groups, and `chain-auto` when a chain is
configured. Subscription import and normalization both add the option to these
managed groups. Normalization preserves custom URLTest fields.
Subscription regeneration keeps its existing replacement policy for the
outbound array.

An unused group does not launch a startup or network-change batch. Its first
use starts an immediate background check; later checks keep the existing
interval and ten-minute idle timeout. Explicit manual URLTest requests continue
to work. Manual node choices and the persistent selector store are unchanged;
an empty subscription still selects `block` and creates no auto groups.

`lazy_start` is a fork extension and requires the new bundled core. Do not copy
the generated configuration onto a device running an older core. Config
validation remains mandatory when a core is available; a rejection leaves the
previous active configuration in place. Install the complete matching module
instead of updating only its shell libraries.

A normal complete module upgrade already rebuilds managed groups from saved
subscription nodes using the new template, generator, and bundled core. This
change reuses that installer path. Merely replacing the core or hot-copying shell
libraries is unsupported and does not upgrade an existing valid configuration:
startup can reuse it without running subscription normalization. An explicit
subscription import or refresh also generates the new managed groups.

`scripts/test-service-selectors.sh` checks generation, normalization, custom
group preservation, saved-choice membership, empty-node behavior, and real-core
configuration validation. `scripts/test-singbox-chain.sh` checks the chain's
option and enable/disable rollback. These fixtures establish configuration
behavior; they do not measure battery use or guarantee external node latency.
