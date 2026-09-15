# Kam Build Hooks

MagicNet build hooks are intentionally small and idempotent. Hooks should only
orchestrate build-time work; reusable download, verification, archive, logging,
and atomic-file helpers belong in `hooks/lib/`.

Pre-build hooks are ordered by their four-digit numeric prefix. Prefixes must be
unique so ordering never depends on filename sorting inside the same slot.

Generated runtime executables go to `bin/`, generated configuration goes to
`.config/`, and persistent hook state goes to `.local/state/`. Packaged runtime
binaries must not live under `.local/bin`; the package smoke test rejects that
legacy layout.

## Layout

- `lib/utils.sh`: logging and required-command checks used by build hooks.
  Installer functions and automatic host package installation do not belong here.
- `lib/release_locks.sh`: reviewed upstream repository, tag, asset, and SHA-256
  locks for external release artifacts.
- `lib/release_utils.sh`: locked download/cache handling, integrity checks, safe
  archive extraction, and atomic promotion helpers.
- `pre-build/`: ordered build/update/config-validation hooks.
- `post-build/`: final archive sanitation before signing.

## Important hooks

- `pre-build/2000.BUILD_WEBUI.sh` builds `webui/` and copies generated static
  files into `src/MagicNet/webroot` so `kam build` packages the WebUI.
- `pre-build/3000.BUILD_CRATES.sh` builds the Rust module tools and installs
  their runtime executables into `bin/`.
- `pre-build/4900.update_tools.sh` installs the reviewed, SHA-256-locked arm64
  releases of `yq` and `jq`.
- `pre-build/5100.update_sing_box.sh` builds the checked-out
  `LIghtJUNction/sing-box` source snapshot for Android arm64 and records its
  source revision.
- `pre-build/5150.update_ecapture.sh` installs the reviewed, SHA-256-locked
  eCapture Android arm64 release.
- `pre-build/5200.update_zashboard.sh` installs the reviewed, SHA-256-locked
  zashboard release into the sing-box configuration tree.
- `pre-build/5450.update_sing_box_rules.sh` refreshes configured rule-set assets
  from immutable upstream revisions.
- `pre-build/5460.update_chatgpt_voice_rules.sh` refreshes the validated
  ChatGPT Voice rule-set.
- `pre-build/5470.optimize_sing_box_routing.sh` normalizes routing after rule
  assets are ready.
- `pre-build/6000.check_config.sh` parses sing-box JSON and runs
  `sing-box check` when the validator is installed. Set
  `MAGIC_CONFIG_CHECK_STRICT=1` to fail when the validator is missing.

## Release policy

External release artifacts must be declared in `lib/release_locks.sh`. A hook
must not query "latest" and install it directly. The shared release helpers
verify the immutable SHA-256 before replacing an existing cache or runtime
file. Failed downloads, validation, or extraction must leave the previous
installation intact.

## 2026 config policy

sing-box 1.13+ no longer supports the old GeoIP / GeoSite database path. The
config check hook rejects `geosite:` / `geoip:` strings and deprecated
`geosite`, `geoip`, `source_geoip` rule fields so CI does not accept configs
that only fail later on-device.

Generated files such as downloaded cores, version markers, archives, and
`dist/*.zip` must stay ignored and must not be committed.

## Package policy

`scripts/package-smoke.sh` validates the release zip before install smoke tests
run. It rejects legacy mihomo/TProxy/proxy-capture entries, `.local/bin`
runtime entries, `.local/subscriptions.env`, and stale kamfw runtime exports
such as `MAGIC_MIHOMO`, `MAGIC_HOTSPOT_FORWARD`, and `MAGIC_VPN_COEXIST`.
