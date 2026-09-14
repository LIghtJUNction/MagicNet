# Google outbound selection and recoverable config activation

## What was reproduced

- `magicnet_jq_install_config config tmp true` returned success and replaced an
  existing JSON config with zero bytes. A successful command is not a document.
- The maintained service builder emitted `google-proxy.default = "proxy"`, but
  sanitization removed that choice and pinned the group to the first node.
- A marker-less config lock containing a foreign entry could not be reclaimed;
  its unconditional retry skipped the overall timeout check indefinitely.

All three added regression groups fail against the pre-fix source and pass with
this patch. Existing subscription transaction rollback and PID/start-time owner
checks remain in use; no global process killing or recursive lock deletion was added.

## Recovery contract

Writers accept exactly one JSON object. The generated candidate is checked again
following sanitizer/chain operations; failure leaves the old file unchanged.
Successful startup/activation checkpoints the config and its embedded nodes in
`.state/sing-box/last-good-config.json` (0600, parent 0700). The one-use Tailscale
login key is stripped before checkpointing. Neither credentials nor node names
are printed in recovery diagnostics.

Recovery runs under the existing config lock, including the startup source gate.
It restores only a missing/structurally broken active config, never a valid user
edit. A checkpoint must match the configured TUN/eBPF mode and pass the installed
core's config check against current local assets. Checks have a 15-second deadline
and a 2-second forced-termination grace period. No subscription fetch or detached
service start is launched by the checkpoint helper. Missing/invalid checkpoints
fail closed; no direct-only configuration is invented. The checkpoint includes
node definitions, so disposable subscription-work cache loss does not prevent
recovery. A corrupt directory or checkpoint is not deleted to force recovery.

This is process-failure recovery, not a claim of filesystem power-loss durability
on every Android filesystem. Existing transaction journals still govern interrupted
activation and byte-exact rollback.

## Google routing: what the patch does and does not establish

Maintained service groups now include `proxy` and follow it by default. Legacy
first-node groups lacking `proxy` migrate to that default. Explicit direct/block
choices, and valid node pins on canonical groups, are preserved across generation.
Removed node choices return to `proxy`, not direct. AI selector policy is unchanged.
A user choice already saved in the core's selector cache remains an explicit
choice; the patch does not wipe the entire cache or silently override it.

The mandatory build check starts the exact compiled sing-box fork with two local
SOCKS fixtures. It verifies that fresh Google-group connections move from node A
to node B when `proxy` changes, and that explicit per-service pins still work.
The fixtures never connect to public Google services. This proves routing behavior,
not Android UID capture, UDP/QUIC compatibility, account login, or Play downloads.

The latest #253 device A/B report says direct works while the selected proxy path
fails. Host tests cannot prove that an external provider's Google path works, and
there is no connected Android test device in this validation environment. Keep
#253 open until the reported device passes Google Play search, images and download
through a known-working proxy, on the relevant Wi-Fi/mobile network. Check the
actual `google-proxy` selection in the dashboard; `proxy` follows the main group,
while a node pin deliberately does not. HTTP health checks are not app acceptance.

## Primary sources reviewed

- MagicNet device A/B evidence: https://github.com/LIghtJUNction/MagicNet/issues/253
- Config loss/lock report: https://github.com/LIghtJUNction/MagicNet/issues/254
- sing-box selector semantics: https://sing-box.sagernet.org/configuration/outbound/selector/
- sing-box URLTest scope: https://sing-box.sagernet.org/configuration/outbound/urltest/
- Upstream Google Play / Hysteria2 vs VLESS report (not proof of the same root
  cause): https://github.com/SagerNet/sing-box/issues/4383
- Android vs OpenWrt Play download report:
  https://github.com/SagerNet/sing-box/issues/2498
- jq empty input/exit-status history:
  https://github.com/jqlang/jq/issues/1497
- jq slurp and exit-status documentation: https://jqlang.org/manual/

The local jq 1.7 binary returns 4 for empty input with `-e`; the generic writer
bug does not depend on that historical jq behavior. `true` or `jq empty` can still
succeed without a usable output document. Explicit document validation is needed.
