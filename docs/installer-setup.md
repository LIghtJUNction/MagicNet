# Installer subscription page

On a normal Android install, `customize.sh` restores existing inputs and installs
the release template before calling `magicnet_install_setup`. When no URL, local
subscription, or standalone configuration exists, it imports kamfw `web_form`,
starts a short-lived loopback form, and uses kamfw `launch browser` to open the
foreground user's default browser. It does not assume Chrome is installed.
The page also offers a clickable notification and a console-only fallback URL.

The page is bundled and offline: no CDN, analytics, external fonts, or remote
JavaScript. It follows the system light/dark setting and supports Chinese,
English, Russian, Japanese and Korean with automatic detection and manual
selection. Project/Star, guide, releases, issues, author and optional AI-service
links are ordinary user-initiated links, never automatic stars or redirects.

## Existing configuration and failure paths

Nonempty `subscription.url` / `subscription.local`, or a standalone-config marker,
prevent opening the page. Upgrades do not overwrite those inputs. GUI installs
work without a TTY. Recovery (`BOOTMODE=false`), `MAGICNET_NONINTERACTIVE=1`,
`MAGICNET_SETUP=0`, and `MAGIC_SINGBOX=0` skip collection. The default wait is 180
seconds; `MAGICNET_SETUP_TIMEOUT` accepts 5–1800 seconds. Skip, timeout, missing
BusyBox CGI, failed browser launch, and system restrictions do not abort install.
The user can later configure the subscription through the module WebUI/CLI.
No SELinux policy, routing rule or firewall is weakened by this feature.

The installer only saves the URL with mode 600. It does not fetch subscriptions
or start the core. Existing startup logic imports the saved subscription before
starting sing-box; without usable input/nodes the existing startup guard fails
closed. MagicNet's current reader accepts HTTPS only and rejects literal `@`;
the page and backend enforce that policy. Percent-encode `@` in query values.

## Framework delivery

The reusable implementation is a kamfw extension, not a second HTTP service in
`customize.sh`. Its source is under `src/MagicNet/lib/kamfw-overlay/`. Installation
copies the three explicit files into `lib/kamfw/` before loading `.kamfwrc`, so
normal `import web_form` and `import launcher` work. This also survives the
repository's build-time remote submodule refresh, without changing `.gitmodules`
to depend on an unmerged branch. The upstream kamfw repository was read-only to
the integration used for this change. Once this API is accepted upstream, remove
the overlay and its copy step together; do not remove only one of them.

The enhanced launcher now returns the actual command status (the old implementation
lost it in `unset`) and bounds commands when `timeout` is available. Role lookup
uses a numeric current user, with browsable ACTION_VIEW as a fallback. Android
may still show a chooser when no default browser exists or block activity starts.

## Verification

```sh
python3 scripts/test-install-setup.py
cd webui
node scripts/test-install-setup.mjs
```

The backend tests require BusyBox with CGI (`busybox-static` on Ubuntu) and use
the actual overlaid kamfw import loader and HTTP server, with Android intents
mocked. The browser suite uses Playwright Chromium against a real local HTTP
fixture and covers five locales, both themes, narrow/wide layouts, Enter-to-save,
skip, missing token, expired sessions, uncertain transport failures and links.
`MAGICNET_SETUP_SCREENSHOTS` can select a screenshots directory.

In environments which forbid browser navigation entirely,
`MAGICNET_SETUP_DOM_FIXTURE=1` runs the browser assertions against the same assets
in a DOM/XHR fixture. This mode is reported explicitly and is not an end-to-end
network or Android test. Do not alter managed browser policy to run the tests.
Android manager lifecycle, intent behavior and SELinux still require device
verification; passing host tests does not establish universal device support.

## API and security contract


`import web_form` provides `web_form_collect_url <assets-dir> <output-file> [seconds]`.
It returns 0 after saving, 2 after Skip, 3 after expiry, 4 when unavailable, and 5
when an existing nonempty output should be preserved. Import alone has no effects.
The existing `launcher` helper also gains `launch browser <http(s)-url>`.

The caller supplies a private existing output directory and three static files:
`index.html`, `style.css`, and `app.js`. Only these assets and the generated CGI
entry are served. The helper never downloads a dependency or the submitted URL.
An existing BusyBox with `httpd` CGI, `ash`, `wget`, `setsid`, `timeout`, and the
listed standard applets is required. `KAM_WEB_FORM_BUSYBOX` selects an explicit
binary; otherwise common Magisk, KernelSU, APatch and PATH locations are probed.
An actual authenticated CGI health request checks compatibility before opening.

The optional `web_form_ready <url> <seconds>` callback can print localized
instructions using the caller's kamfw i18n keys. Use `print` for the temporary
address, not a file-logging wrapper. `KAM_WEB_FORM_NOTICE_TITLE`,
`KAM_WEB_FORM_NOTICE_TEXT`, and `KAM_WEB_FORM_NOTICE_DONE` enable a best-effort
clickable Android notification which is replaced by a non-clickable result note
on cleanup. Browser opening always uses the public `launch browser` API.
No Chrome package is assumed. The foreground user's browser role is queried
using its numeric user ID; ordinary browsable ACTION_VIEW is the fallback.
Android may still refuse background activity starts, or show a chooser if the
user has not selected a default browser. The printed URL/notification is then
the fallback; there is no change to system policies.

## Page protocol

The URL fragment is a 48-character lowercase hex capability. The page sends it
as `X-Setup-Token`. POST `/cgi-bin/api/save` accepts the exact URL as a
`text/plain` UTF-8 body, not form-urlencoded data; POST `/cgi-bin/api/skip` skips.
GET `/cgi-bin/api/health` is authenticated and returns `ready`.
Successful saves return `saved` only **after** an atomic, mode-600 write.
The page must not treat a transport error as successful persistence.
URLs must use HTTP(S), contain a host, no userinfo, and no whitespace/control
characters; the maximum is 8192 bytes. Do not normalize the original query.
The helper never evaluates input as a command. Error bodies are stable codes
for the consumer to localize: `forbidden`, `method`, `missing`, `busy`,
`finished`, `format`, `invalid`, `too_long`, `storage`, and `existing`.

## Lifecycle and boundaries

The listener binds only to 127.0.0.1. Host and optional Origin must match the
local origin; custom-header authentication rejects cross-site submissions.
No CORS permission is granted. The random capability is not present in public
assets. Keep outgoing page links `noopener noreferrer` and use a no-referrer
policy so credentials are not disclosed by navigation.

The collector owns a dedicated process group and runs in a subshell, preserving
the parent's existing kamfw EXIT chain. Normal completion, skip, timeout and
catchable termination remove its listener, private session directory and lock.
A separate server watchdog bounds orphaned listeners if the parent is killed.
SIGKILL cannot run shell cleanup: after confirming that no collector is running,
a maintainer may remove the private `output-file.web-form.lock` and stale
`.web-form.*` session directory. Do not blindly remove someone else's active lock.
This is a short-lived local input service, not a general-purpose privileged web
server. Do not serve a module tree or reuse it as a durable background daemon.

## Verification

Run `python3 scripts/test-install-setup.py` with `busybox-static` installed. The suite
uses the real import loader, launcher and HTTP/CGI handler, but mocks Android
`am`/`cmd`. Android browser behavior, manager lifecycle and SELinux need device
tests; passing a host suite does not establish device compatibility.

`KAM_WEB_FORM_HTTPS_ONLY=1` restricts saved values to HTTPS and rejects literal
`@` characters (percent-encode them in query values). Use this for strict
subscription readers such as MagicNet. The default accepts HTTP and HTTPS.
