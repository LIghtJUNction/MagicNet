---
name: kamfw
description: Maintain MagicNet's shell KAM framework under src/MagicNet/lib/kamfw, including helpers, imports, i18n, logging, install filters, dependency checks, and EXIT handlers.
---

# MagicNet KAM Framework

Use this skill only inside the MagicNet repository when changing `src/MagicNet/lib/kamfw` or callers that depend on it.

## Inspect Before Editing

Search the framework and its callers before adding a helper:

```bash
rg '<symbol-or-behavior>' src/MagicNet/lib/kamfw src/MagicNet
```

Prefer an existing helper. Put a reusable helper in `src/MagicNet/lib/kamfw/<name>.sh` (or the established `__name__.sh` internal form) and load it through `import`; do not bury shared helpers in `customize.sh` or hooks.

## Framework Contract

- Use the framework's `print`, `info`, `warn`, `error`, `debug`, and `success` wrappers for user-visible output. Use raw `printf` only for formatting that wrappers cannot express, and explain why.
- Register all user-visible text with `set_i18n`; retrieve it through `i18n`/`t`. List new or changed keys in the PR.
- Check optional commands with `command -v`. Missing required dependencies must fail fast through `abort` with an i18n message.
- Verify downloaded content with at least SHA-256; add signature verification when the trust model requires it. Never commit keys or secrets.
- Preserve user configuration by default. Interactive replacement needs explicit confirmation; non-interactive input uses the safe path (skip or create an update file).
- Do not rewrite system paths, start durable background processes, or silently downgrade behavior without explicit design and user-visible reporting.
- Keep functions small, single-purpose, and documented with rationale rather than narration.

## TTY and Non-Interactive Behavior

There is no framework `is_ci` helper. Use the repository's existing TTY conventions instead of inventing one:

```sh
if [ -t 0 ] || [ -t 1 ]; then
    # interactive-capable path
else
    # safe non-interactive default
fi
```

Follow the owning helper when it uses stricter stdin-only checks such as `[ -t 0 ]`.

## Logging

`logging.sh` owns log behavior:

- `KAM_LOGLEVEL` / `set_loglevel`: `ERROR`, `WARN`, `INFO`, or `DEBUG` (default `INFO`)
- `KAM_DEBUG=1`: compatibility alias for debug logging
- `KAM_LOGFILE`: default `$MODDIR/kam.log`
- `KAM_LOG_ROTATE_SIZE`: accepts K/M/G suffixes

Use wrappers for level filtering and console output. Direct `log` remains a file-writing compatibility API.

## EXIT Handlers

`__at_exit__.sh` exposes:

- `at_exit_add`, `at_exit_remove`, `at_exit_list`, `at_exit_clear`
- `at_exit_register_trap`, `at_exit_unregister_trap`
- `__at_exit_install_from_filters`

Current behavior is important:

- handlers run in registration order in the **current shell** via `eval`;
- one handler failure is logged and does not stop the remaining handlers;
- registration installs `trap "__at_exit_master_handler" EXIT` and does not preserve a pre-existing EXIT trap.

Do not describe handlers as subshell-isolated. Inspect compatibility before composing this helper with another EXIT trap.

## Install Filters

Apply filters in this order:

1. `install_exclude`
2. `install_include` (may override an exclusion)
3. `install_check` preview
4. interactive confirmation where applicable
5. install

Both source-directory (`KAM_MODULE_ROOT`) and ZIP (`ZIPFILE`) flows are supported. Check `unzip`/`zipinfo` before ZIP operations and abort with an i18n message when absent.

## Verification

For every change:

1. Exercise the changed helper through the same import path used in production.
2. Test both interactive and non-interactive branches.
3. Cover dependency-missing and failure paths.
4. For install filters, test directory and ZIP inputs plus include-overrides-exclude behavior.
5. For EXIT handlers, verify order, failure continuation, and interaction with existing traps.
6. Run the repository's relevant shell/static tests and record exact commands and results.

## PR Checklist

Include:

- what changed and why;
- new/changed i18n keys;
- compatibility and security risks;
- interactive and non-interactive verification;
- dependency, network-integrity, logging, install, or EXIT-handler checks as applicable.
