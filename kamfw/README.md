# kamfw

kamfw is the shell runtime embedded in Kam module templates. It provides the
common entrypoint, lifecycle dispatcher, logging, i18n, installer helpers, and
small Android/root-manager utilities used by generated modules.

The current implementation is shell-only. The old Rust CLI prototype under
`src/` was intentionally removed; runtime behavior should stay in the shell
modules here unless a new design is introduced deliberately.

## Entrypoint

Module scripts source `.kamfwrc`:

```sh
. "$MODDIR/lib/kamfw/.kamfwrc" || exit 1
```

`.kamfwrc` loads the core modules in this order:

1. `i18n`
2. `base`
3. `logging`
4. `kam`

Use `import <module>` to load additional helpers. `import` calls the internal
loader directly, so runtime command dispatch in `__runtime__.sh` cannot break
module loading.

## Runtime

`kam.sh` imports:

- `__runtime__`: `kamfw run <phase> -- "$@"`, KAM_HOME, PATH, and
  LD_LIBRARY_PATH setup.
- `init_dirs`: creates runtime directories under `$KAM_HOME`.
- root-manager helpers when detected: `magisk`, `ksu`, `ap`.

Supported lifecycle phases are:

- `install`
- `post-fs-data`
- `service`
- `boot-completed`
- `uninstall`
- `action`
- `post-mount`

Default phase handlers are no-ops and can be overridden by module code.
For startup behavior, use either `service` or `boot-completed` as the main
business phase. kamfw handles root-manager compatibility dispatch, including
script renaming for managers that do not expose every phase directly, so module
business code should not branch on Magisk, KernelSU, APatch, or ShiroSU for
lifecycle compatibility.

`uninstall` is optional. Do not ship an `uninstall.sh` just to import
`__uninstall__`; the default cleanup phase is quiet. Ship one only when the
module has real uninstall work, and make it call:

```sh
. "$MODDIR/lib/kamfw/.kamfwrc"
import __runtime__
kamfw run uninstall -- "$@"
```

For property rollback, use `import prop` and `persistprop`; it creates
`$MODPATH/uninstall.sh` lazily with the exact rollback commands needed.

## Installer

`import __installer__` is the complete public installer entrypoint. It loads:

- `__at_exit__`
- `__install_core__`
- `__installer_cmd__`

Public API:

```sh
install_reset_filters
install_exclude "pattern"
install_include "pattern"
install_check [src]
installer check [src]
installer run [src]
installer schedule [src]
```

Install filter order is:

1. list files from a source directory or zip
2. remove excluded files
3. re-add included files

Zip listing prefers `zipinfo`, then `unzip -Z1`, then structured `unzip -l`
parsing. Zip extraction requires `unzip` and fails fast if it is missing.

## Output And i18n

User-visible output should go through `print`, `info`, `warn`, `error`, or
`success`. New user-facing text should be registered with `set_i18n` and read
with `i18n`.

The `t` helper uses `$_1`, `$_2`, ... placeholders:

```sh
set_i18n "EXAMPLE" "en" "Installed: \$_1"
i18n "EXAMPLE" | t "bin/foo"
```

Do not add `|| echo ...` fallback output paths. Use a small helper or an
explicit fallback variable, then send the final message through the logging
wrapper.

`import rich` provides small UI helpers for installer and action screens:

```sh
panel "Module status"
panel_row "Version" "$KAM_MODULE_VERSION"
panel_divider
panel_success "Ready"
panel_warn "Optional config not found"
panel_error "Service failed"
panel_end
```

Available panel helpers are:

- `panel [title]` / `panel_end`
- `panel_line <text>` / `panel_blank` / `panel_divider`
- `panel_row <label> <value>`
- `panel_status <info|success|warn|error> <text>`
- `panel_note`, `panel_success`, `panel_warn`, `panel_error`

Panels use terminal colors only on TTY. Non-TTY and manager UI output stays
plain text with stable borders, so it remains readable in install logs.

## Log Rotation

`logging` can rotate the active log before appending a new line:

```sh
KAM_LOG_ROTATE_SIZE=256k
KAM_LOG_ROTATE_KEEP=3
info "service started"
```

The same behavior is available per call:

```sh
log --file "$MODDIR/service.log" --rotate 1m --rotate-keep 5 "service ready"
```

Rotation uses numbered backups: `service.log.1`, `service.log.2`, and so on.
`KAM_LOG_ROTATE_SIZE` accepts plain bytes or `k`, `m`, and `g` suffixes.
`KAM_LOG_ROTATE_KEEP=0` truncates the current log instead of keeping backups.

Modules can also call the helper directly:

```sh
import logrotate
logrotate --size 1m --keep 5 "$MODDIR/service.log"
```

## Watchdog

`import watchdog` loads an explicit watchdog helper. Importing it does not start
any background process; modules must call the API deliberately from a lifecycle
phase such as `service`.

Public API:

```sh
import watchdog

watchdog once 'command -v sing-box >/dev/null'
watchdog start network-check 30 'ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1'
watchdog start --notify core-check 30 'pidof mihomo >/dev/null 2>&1'
watchdog status network-check
watchdog stop network-check
```

State is stored under `$KAM_HOME/.state/watchdog` by default. Override with
`KAM_WATCHDOG_STATE_DIR` when a module needs a different state directory.

Failure notifications are opt-in. Use `watchdog start --notify ...`, or set
`KAM_WATCHDOG_NOTIFY=1`. The notification title defaults to `kamfw watchdog` and
can be changed with `KAM_WATCHDOG_NOTIFY_TITLE`.

Keep watchdog commands idempotent and short. Do not start long-running watchdogs
during install; start them from `service` or another runtime phase where a
background loop is expected.

## File Change Watcher

`import fswatch` loads an explicit asynchronous file change monitor. It uses
polling snapshots, so it does not require `inotify` and works on minimal Android
shell environments. Importing it does not start any background process.

Public API:

```sh
import fswatch

fswatch snapshot "$MODDIR/config"
fswatch changed "$MODDIR/config" "$KAM_HOME/.state/config.snapshot"
fswatch start config-watch "$MODDIR/config" 5 'kamfw run action -- reload-config'
fswatch status config-watch
fswatch stop config-watch
```

When a change is detected, the command runs with:

- `KAM_FSWATCH_NAME`
- `KAM_FSWATCH_PATH`
- `KAM_FSWATCH_SNAPSHOT`

State is stored under `$KAM_HOME/.state/fswatch` by default. Override with
`KAM_FSWATCH_STATE_DIR` when needed.

Keep watch commands short and idempotent. Start long-running file watchers from
runtime phases such as `service`, not from install/customize paths.

## Cached Downloads

`import cache_download` loads a cached download helper. It is useful for runtime
data files, rule sets, and small tools that should only replace the installed
file when content changes. Importing it does not download anything.

Public API:

```sh
import cache_download

cache_download "https://example.com/rules.dat" "$KAM_HOME/.config/rules.dat"
cache_download --hash "$sha256" "$url" "$dest"
cache_download --hash-url "$url.sha256" "$url" "$dest"
download_if_changed "$url" "$dest"
```

The helper downloads to a temporary file, computes sha256, and compares it with
the cached hash before replacing the destination. The result is exported as
`KAM_CACHE_DOWNLOAD_CHANGED=1` for updates and `0` when the destination is
unchanged.

Default hash state is stored under `$KAM_HOME/.cache/downloads`. Override with:

```sh
KAM_CACHE_DOWNLOAD_STATE_DIR="$KAM_HOME/.cache/my-downloads"
```

Use `--hash-file <file>` when a module wants to keep a stable, human-readable
state file next to related config.

## Notification

`import notify` loads a small Android notification helper. It uses
`cmd notification post`, which is available from Android shell/root
environments and does not require a bundled app. Importing it does not post
anything.

Public API:

```sh
import notify

notify post magicnet_guard "MagicNet" "core restarted"
notify alert magicnet_guard "MagicNet" "core restarted"
notify expand
notify test
```

`notify post` sends or replaces a notification with the same tag. `notify alert`
posts the notification and then asks SystemUI to expand the notification shade;
this is useful on ROMs that accept shell notifications but suppress heads-up
banners for the `shell_cmd` channel.

Environment overrides:

- `KAM_NOTIFY_AS_SHELL=0`: skip the default `su shell -c` notification path
- `KAM_NOTIFY_ICON`: icon spec passed to `cmd notification post -i`
- `KAM_NOTIFY_STYLE`: style passed to `cmd notification post -S`
- `KAM_NOTIFY_VERBOSE=1`: keep `cmd notification post -v` output visible

Avoid relying on `service call notification` transaction numbers for toast
messages. Those Binder interfaces are Android-version dependent and are not a
stable kamfw API.

## Validation

Useful local checks from the Kam repository root:

```sh
shellcheck -S error -s sh \
  "tmpl/kam_template/src/<module-id>/lib/kamfw/.kamfwrc" \
  "tmpl/kam_template/src/<module-id>/lib/kamfw/__install_core__.sh" \
  "tmpl/kam_template/src/<module-id>/lib/kamfw/__installer__.sh" \
  "tmpl/kam_template/src/<module-id>/lib/kamfw/__installer_cmd__.sh" \
  "tmpl/kam_template/src/<module-id>/lib/kamfw/kam.sh" \
  "tmpl/kam_template/src/<module-id>/lib/kamfw/__termux__.sh"

cargo run -- init /tmp/kam-smoke --tmpl --force
```

Minimal installer smoke test:

```sh
tmp=$(mktemp -d /tmp/kamfw-test.XXXXXX)
mkdir -p "$tmp/out/.config/kamfw" "$tmp/out/lib/kamfw" "$tmp/src/bin"
cp tmpl/kam_template/src/<module-id>/lib/kamfw/.kamfwrc "$tmp/out/lib/kamfw/.kamfwrc"
cp tmpl/kam_template/src/<module-id>/lib/kamfw/*.sh "$tmp/out/lib/kamfw/"
printf 'KAMFW_DIR=%s\nKAM_MODULES=""\nKAM_HOME=%s\n' \
  "$tmp/out/lib/kamfw" "$tmp/home" > "$tmp/out/.config/kamfw/.envrc"
printf '#!/bin/sh\necho ok\n' > "$tmp/src/bin/foo"
chmod +x "$tmp/src/bin/foo"
MODPATH="$tmp/out" KAM_MODULE_ROOT="$tmp/src" sh -c \
  '. "$0"; import __installer__; install_reset_filters; install_include "bin/*"; installer run' \
  "$tmp/out/lib/kamfw/.kamfwrc"
test -x "$tmp/out/bin/foo"
```

Panel helper smoke test:

```sh
tmp=$(mktemp -d /tmp/kamfw-panel.XXXXXX)
mkdir -p "$tmp/out/.config/kamfw" "$tmp/out/lib"
cp -a tmpl/kam_template/src/<module-id>/lib/kamfw "$tmp/out/lib/kamfw"
printf 'KAMFW_DIR=%s\nKAM_MODULES=""\nKAM_HOME=%s\n' \
  "$tmp/out/lib/kamfw" "$tmp/home" > "$tmp/out/.config/kamfw/.envrc"
MODPATH="$tmp/out" sh -c \
  '. "$0"; import rich; PANEL_WIDTH=44 panel "kamfw"; panel_row "Module" "demo"; panel_success "ready"; panel_end' \
  "$tmp/out/lib/kamfw/.kamfwrc"
```

## Thanks

[nga-utils](https://github.com/ShIroRRen/NGA-SDK/tree/nga)
