# Kam Build Hooks

MagicNet hooks are intentionally small and idempotent. They download generated
runtime assets into `.local/` or `.config/`, validate configs with the current
kernels when available, and keep downloaded binaries out of Git history.

## Important hooks

- `pre-build/4900.update_tools.sh` downloads `yq` and `jq` arm64 release
  binaries into `.local/bin` for on-device YAML / JSON maintenance helpers.
- `pre-build/5000.update_mihomo.sh` downloads the selected Android arm64 mihomo
  release and verifies the GitHub release digest when it is available.
- `pre-build/5100.update_sing_box.sh` selects the best sing-box Android arm64
  release asset, verifies the digest when available, and installs only the
  binary into `.local/bin`.
- `pre-build/3000.BUILD_CRATES.sh` builds Rust module tools, installs
  `magicnet-cli` and `magicnet-mcp-server` into `.local/bin`, and refreshes the
  `cli -> .local/bin/magicnet-cli` compatibility symlink.
- `pre-build/5500.update_geodata.sh` updates mihomo GeoIP / GeoSite data and
  stores hash state under `.local/state/geodata`.
- `pre-build/6000.check_config.sh` always parses mihomo YAML and sing-box JSON.
  If `mihomo` / `sing-box` are installed, it also runs the real runtime config
  validators. Set `MAGIC_CONFIG_CHECK_STRICT=1` to fail when the validators are
  missing.

## 2026 config policy

sing-box 1.13+ no longer supports the old GeoIP / GeoSite database path. The
config check hook rejects `geosite:` / `geoip:` strings and deprecated
`geosite`, `geoip`, `source_geoip` rule fields so CI does not accept configs
that only fail later on-device.

Generated files such as downloaded cores, `GeoIP.dat`, `GeoSite.dat`, version
markers, archives, and `dist/*.zip` must stay ignored and must not be committed.
