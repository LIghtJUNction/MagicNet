# Kam Build Hooks

MagicNet hooks are intentionally small and idempotent. They download generated
runtime executables into `bin/`, generated configuration into `.config/`, and
hook state into `.local/state/`. Packaged runtime binaries must not live under
`.local/bin`; the package smoke test rejects that legacy layout.

## Important hooks

- `pre-build/2000.BUILD_WEBUI.sh` builds `webui/` and copies the generated
  static files into `src/MagicNet/webroot` so `kam build` packages the WebUI.
- `pre-build/4900.update_tools.sh` downloads `yq` and `jq` arm64 release
  binaries into `bin/` for on-device YAML / JSON maintenance helpers.
- `pre-build/5100.update_sing_box.sh` selects the best sing-box Android arm64
  release asset, verifies the digest when available, and installs only the
  binary into `bin/`.
- `pre-build/5150.update_ecapture.sh` selects the latest eCapture Android
  arm64 release asset, verifies the digest when available, and installs the
  `ecapture` network analysis binary into `bin/`.
- `pre-build/3000.BUILD_CRATES.sh` builds Rust module tools, installs
  `magicnet-cli` and `magicnet-mcp-server` into `bin/`, and refreshes the
  `cli -> bin/magicnet-cli` compatibility symlink.
- `pre-build/6000.check_config.sh` parses sing-box JSON and runs
  `sing-box check` when the validator is installed. Set
  `MAGIC_CONFIG_CHECK_STRICT=1` to fail when the validator is missing.

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
