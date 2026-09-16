# Rules Release distribution

`rules` is now a source-only MagicNetRules submodule. Its history was rewritten to remove generated `dist/`, downloaded `sources/`, and `sources_binary/`; do not restore the old gitlink or merge the old generated history into it.

`hooks/pre-build/5450.update_sing_box_rules.sh` invokes the submodule's Release downloader at build time. The downloader resolves the latest published Release once, then obtains the checksum file and runtime archive from the same concrete tag. It checks the archive SHA-256, rejects unsafe archive members, validates every SRS against `manifest.json`, and replaces the local ignored `rules/dist/` only after complete verification.

The hook validates the full configured SRS inventory before installing selected rules. Missing files, bad checksums, download errors, missing submodule, and invalid config fail the build; there is no fallback to unrelated upstream branches or stale local data. Rule files and state markers are updated through temporary files. Unchanged rules retain their modification time. The separately configured ChatGPT Voice JSON feed is still handled by hook 5460; this migration does not change its routing format.

For a reproducible build, set `MAGICNET_RULES_TAG` to a published tag, for example:

```bash
export MAGICNET_RULES_TAG=rules-20260916-a270f753b3240ffc
kam build
```

For an explicitly offline build, point `MAGICNET_RULES_DIR` at an already extracted, verified runtime bundle containing `manifest.json` and SRS files. This is opt-in; merely finding old files in `rules/dist/` never disables the normal Release download.

MagicNetRules checks upstreams every six hours and publishes only changed, tested runtime contents. Rule data and archives do not enter either Git repository. External executable dependencies retain their existing reviewed release-lock policy.

After updating the parent repository, run `git submodule update --init -- rules` to check out its new gitlink. Existing standalone MagicNetRules clones should be freshly cloned after saving any local work; old refs can keep the removed blobs alive locally. GitHub-managed historical PR refs and server object retention are not deleted by the rewrite.

Validation includes offline failure/rollback tests plus `Rules Release Integration`, which checks a fresh submodule clone's reachable history and actually downloads/installs a published Release.
