# MagicNet shell library layout

`lib/magicnet/` is the module's shell-library boundary. Keep the root boring: it is for runtime modules loaded by `lib/magicnet.sh`, stable entrypoints, and compatibility shims only.

- `singbox_subscribe/` — subscription fetch/parse/config/update pipeline, including bootstrap helpers.
- `onboarding/` — static assets and CGI helpers used by install onboarding.
- `jq/` — jq modules shared by runtime and subscription code.

`subscribe_bootstrap.sh` is a compatibility shim for the canonical `singbox_subscribe/bootstrap.sh` implementation. New code should use the canonical implementation and must not grow the shim.

`install_config.sh` and `install_onboarding.sh` deliberately stay at their stable root paths. Installer and host-test flows can run against a synthetic `MODPATH`, so moving those implementations behind a `MODPATH`-relative shim would change their path contract rather than merely reorganize files.

When adding code here:

1. Put general runtime functions in an existing runtime module when the responsibility already exists.
2. Put feature-specific implementation in a named subdirectory rather than adding another miscellaneous root file.
3. Keep data/static assets out of shell modules unless the runtime path contract requires them.
4. Do not duplicate implementations to fake a migration. Use one canonical implementation plus a thin compatibility shim only when path semantics remain intact.
