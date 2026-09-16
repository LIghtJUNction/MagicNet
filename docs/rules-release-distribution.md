# Rules Release distribution

`rules` is now a source-only MagicNetRules submodule. Its history was rewritten to remove generated `dist/`, downloaded `sources/`, and `sources_binary/`; do not restore the old gitlink or merge the old generated history into it.

`hooks/pre-build/5450.update_sing_box_rules.sh` invokes the submodule's Release downloader at build time. The hook selects the reviewed tag in `rules-release.json`, then obtains the checksum file and runtime archive from that concrete tag. It checks the archive SHA-256, rejects unsafe archive members, validates every SRS against `manifest.json`, and replaces the local ignored `rules/dist/` only after complete verification.

The hook validates the full configured SRS inventory before installing selected rules. Missing files, bad checksums, download errors, missing submodule, and invalid config fail the build; there is no fallback to unrelated upstream branches or stale local data. Rule files and state markers are updated through temporary files. Unchanged rules retain their modification time. The separately configured ChatGPT Voice JSON feed is still handled by hook 5460; this migration does not change its routing format.

Normal builds use the committed release pin automatically. An explicit `MAGICNET_RULES_TAG` must equal that pin; changing the tag requires updating the pin and reviewing both changes.

For an explicitly offline build, point `MAGICNET_RULES_DIR` at an already extracted, verified runtime bundle containing `manifest.json` and SRS files. This is opt-in; merely finding old files in `rules/dist/` never disables the normal Release download.

MagicNetRules checks upstreams every six hours and publishes only changed, tested runtime contents. Rule data and archives do not enter either Git repository. External executable dependencies retain their existing reviewed release-lock policy.

After updating the parent repository, run `git submodule update --init -- rules` to check out its new gitlink. Existing standalone MagicNetRules clones should be freshly cloned after saving any local work; old refs can keep the removed blobs alive locally. GitHub-managed historical PR refs and server object retention are not deleted by the rewrite.

Validation includes offline failure/rollback tests plus `Rules Release Integration`, which checks a fresh submodule clone's reachable history and actually downloads/installs a published Release.

## Reviewed release pin

`rules-release.json` selects the exact release tag and SHA-256 of its
`manifest.json`. The build hook passes that tag to the downloader, then checks
the manifest digest before replacing any module file. The existing manifest
validation checks every selected SRS size and SHA-256. A moved tag, replaced
asset, stale cache, or conflicting `MAGICNET_RULES_TAG` cannot silently install
different rules into a release candidate.

Update the `rules` gitlink and this pin together in a reviewed PR after the
rules release workflow succeeds. Obtain the manifest digest from a runtime
archive verified against the release checksum, and run the integration and
module packaging checks. `recipe_commit` is provenance, not a replacement for
the content checks. Host regression caches include both the recipe and pin.

`MAGICNET_RULES_DIR` remains an explicit local development/test-fixture override;
it validates its own manifest but does not claim the reviewed release identity.
Formal release builds must leave it unset. A new upstream release alone does
not change this module's pinned rule bytes.
