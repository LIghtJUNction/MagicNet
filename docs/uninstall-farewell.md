# Uninstall cleanup and farewell

`src/MagicNet/uninstall.sh` is the root-manager uninstall entry. It is part of
our module source, not an install-time download. Managers may execute it only
when removal is committed on reboot, rather than when the Remove button is
first pressed. Disabling the module or updating it does not invoke this entry.

## Cleanup first

The hook verifies `id=MagicNet`, creates the existing `disable` marker to prevent
restarts, and calls the existing CLI interfaces in this order:

1. `cli mcp stop`
2. `cli supervisor stop all`
3. `cli service stop`
4. `cli state reconcile`

Each step is attempted even if a previous one fails. Runtime cleanup remains
owned by the existing service lifecycle; this hook does not independently flush
iptables, detach arbitrary eBPF programs, or kill every process named sing-box.
BusyBox timeouts bound each CLI call when available. Missing CLI or cleanup
errors produce a warning and nonzero hook status, not a successful-cleanup claim.
The root manager controls whether that status stops removal.

The manager removes the module directory, including its configuration, logs and
caches. The hook does not recursively delete exported files in Download, other
modules, or another VPN's resources. A per-module lock prevents concurrent
teardown; repeated calls can retry cleanup without reopening the farewell page.

## Optional browser page

After cleanup has been attempted, an independent worker prepares a static local
page and uses the existing `launch browser` implementation to select the current
Android user's default browser. Browser failure does not change cleanup status.

The worker copies only its executable and public page assets into a private
`/data/adb/.magicnet-farewell.XXXXXX` directory before the module is removed.
It waits at most 300 seconds for Android boot completion, serves on an ephemeral
`127.0.0.1` port for at most 120 seconds, and has an outer 480-second deadline.
The listener exposes only a random page path, no CGI, configuration or privileged
commands. Normal exits and handled signals remove temporary files and stop the
owned listener. Power loss or an uncatchable SIGKILL can interrupt final cleanup;
no persistent boot service is installed to recover such temporary files.

All page CSS and JavaScript are inline, so the loaded tab remains usable after
the listener stops. The page never closes itself or waits for the user before
allowing uninstall to finish. Reloading an old tab after the listener expires is
not supported. Silent/recovery uninstalls skip the page; supported overrides are
`MAGICNET_NONINTERACTIVE=1` and `MAGICNET_UNINSTALL_FAREWELL=0`.

The page supports Chinese, English and Russian, system light/dark appearance,
and narrow mobile viewports. Both choices are optional:

- Agree opens the repository's **new issue draft** in a separate tab, with the
  module version and feedback outline. The user signs in if needed, edits,
  reviews and submits it. The original tab retains the farewell message and a
  retry link; it does not claim that an issue was submitted.
- Decline leaves the farewell message, performs no navigation, and asks no more
  questions within that page session.

Only a bounded ASCII version string is read from `module.prop` as data; it is
passed in a URL fragment. No subscription, node, logs, device identifier or
account credential is collected. No external resource or analytics request is
made by the page before agreement. The draft warns that GitHub issues are public.
The feedback template must be merged to the default branch before GitHub can use
it in production.

## Verification

```sh
python3 scripts/test-uninstall.py
python3 -m pip install playwright==1.57.0
python3 -m playwright install chromium
python3 scripts/test-uninstall-page.py
```

The first suite uses actual BusyBox ash/httpd/setsid/timeout with fixture-only
Android and CLI stubs. It checks cleanup ordering, failures, repeated calls,
symlink boundaries, temporary-server survival after module deletion, and metadata
sanitization. It does **not** execute Android's real networking teardown.

The Chromium suite intercepts GitHub navigation rather than submitting issues.
It checks opt-in, draft contents, independent tabs, declining, language changes,
untrusted fragments, and mobile layouts. Set `MAGICNET_TEST_SCREENSHOTS` to an
output directory to capture the Chinese light/dark layouts. On a host whose
browser policy blocks all navigation, `MAGICNET_TEST_OFFLINE=1` enables inline
rendering and explicitly skips the navigation test; CI uses normal mode.

Real Magisk/KernelSU/APatch uninstall timing, locked-user behavior, SELinux,
background-activity limits, and final TUN/eBPF networking recovery still require
physical-device acceptance. Host mocks and screenshots are not proof of those
Android behaviors. The bounded UI worker is best-effort, never a cleanup gate.
