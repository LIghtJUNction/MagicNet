# kamfw browser-input extension

The extension is kept in `src/MagicNet/lib/kamfw-web` and staged into the
installed kamfw directory by `magicnet_install_stage_web_input`. It uses the
existing kamfw importer and launcher API; the upstream submodule is unchanged.
This overlay can be removed after the same API is accepted upstream.

`import web_input` provides an optional, synchronous input session without an APK.
It requires a BusyBox build with `httpd`, CGI, `ash`, `setsid`, `timeout`, `wget`
and the applets checked by `web_input_busybox`. Missing features return an error;
no dependency is downloaded and no SELinux or firewall policy is changed.

```sh
import web_input
rc=0
web_input_collect "$MODPATH/setup" "$MODPATH/.config/input.txt" 180 \
    "$MODPATH/lib/validate-input.sh" || rc=$?
case "$rc" in
    0) print 'Saved' ;;
    2|3) print 'Configure later' ;;
    *) print 'Browser setup unavailable; use the normal configuration entry' ;;
esac
```

Create the output parent beforehand. The input is single-line text, 1–8192 bytes
without control characters or spaces. `index.html` is required; optional
`setup.css` and `setup.js` are the only other published files. The validator is a
trusted shell script receiving a private body-file path as its sole argument.
It must return zero for acceptance; it must not execute, source or log the input.
The optional fourth argument can be omitted for generic single-line input.

The framework starts a private loopback HTTP server, tests both page and CGI,
then calls `launch browser` with a short-lived URL. Android uses the current
user’s VIEW/BROWSABLE resolver; no particular browser package is selected.
When no default browser is set Android may show a chooser. If opening fails,
the installer prints a full local URL for manual use. This is not a notification
reply field. A manager install does not need a TTY.

## Page protocol

The fragment contains a 48-character random token. POST to `/cgi-bin/api/save`
with `Content-Type: text/plain;charset=UTF-8`, the unchanged input as the body,
and `X-Setup-Token` set to that token. POST to `/cgi-bin/api/skip` for cancellation.
Do not place the input in query strings. Responses are plain enum strings:
`saved`, `skipped`, or `invalid`, `forbidden`, `too_long`, `format`, `method`,
`missing`, `busy`, `changed`, `finished`, `save_failed` with matching HTTP status.
A successful response means the atomic file replacement has already completed.

Return codes: 0 saved, 2 skipped, 3 timeout, 1 unavailable/error. The default
waiting period is 180 seconds (allowed range 5–1800); bounded startup and cleanup
add a few seconds. The session does not download the submitted URL or run any
consumer-specific service. Updates during an open form produce `changed` rather
than silently overwriting another writer’s value.

## Security and cleanup

Only public page assets are served, never the consumer’s configuration directory.
The random session directory has mode 700 and the output has mode 600. Host,
Origin (when provided), token and cross-site fetch metadata are checked. One
submission holds a directory lock; request size and CGI duration are bounded.
Ordinary exit/signals remove the private directory and the complete HTTP process
group. An independent watchdog bounds the listener lifetime even after installer
SIGKILL; SIGKILL can still leave a private temporary directory for later cleanup.
The ephemeral setup URL is printed to the installer, but the input itself is not.
Treat installer logs as private while the session is live.

`KAMFW_WEB_INPUT_BUSYBOX` supplies a preferred absolute BusyBox path.
`KAMFW_WEB_INPUT_NO_OPEN=1` disables automatic browser opening for tests only.
Run host regressions with `python3 scripts/test-kamfw-web-input.py`. Android OEM browser
resolution and SELinux behavior require device testing; failure is nonfatal only
when the consuming installer explicitly handles the return code as above.
