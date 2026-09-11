# Install-time subscription setup

The installer sources `lib/magicnet/install_onboarding.sh` **after** restoring
old configuration, installing the new template and applying permissions. It no
longer opens the README on every install.

On a booted Android device without a saved subscription, a temporary loopback
page opens through kamfw's `import launcher` / `launch url` dispatcher. The
Android call uses `ACTION_VIEW`, `CATEGORY_BROWSABLE` and `--user current`, not a
browser package. Android chooses the configured browser; without a default it
may show its chooser. A blocked launch leaves the complete local URL in the
installer output. A clickable notification is best-effort, not required.

The page has Chinese, English, Russian, Japanese and Korean strings, a language
selector, automatic light/dark themes and reduced-motion support. It uses only
bundled HTML/CSS/JavaScript. GitHub Star, the guide, Discord and the author's LMM
API links are optional navigation; no login, tracking or automatic starring.

## Configuration and fallback

- Existing URL, local-subscription or standalone configuration is retained and
  does not reopen setup. Even malformed non-comment user data is not replaced.
- Saving stages one HTTPS URL in `.config/sing-box/subscription.url` with mode
  `0600` and an atomic rename. It does not download a subscription, start a core,
  modify the generated config, change SELinux or touch firewall rules.
- The normal startup pipeline validates the destination and loads the saved
  source. The installer checks URL syntax only, not whether a remote service is
  reachable or returns a valid subscription.
- Skipping or waiting 180 seconds continues installation. The module WebUI can
  configure the source later; the existing no-subscription startup guard stays
  unchanged.
- Recovery, an unbooted Android system, disabled sing-box, noninteractive mode,
  missing BusyBox applets or failed HTTP/CGI self-checks skip this optional step.

`MAGICNET_INSTALL_ONBOARDING=0` disables the prompt.
`MAGICNET_NONINTERACTIVE=1` also disables it, without relying on a TTY test.
`MAGICNET_SETUP_TIMEOUT` accepts 5–1800 seconds, default 180.
`MAGICNET_SETUP_BUSYBOX` optionally selects an existing compatible BusyBox.
No dependency is downloaded during installation.

## Local interface security

The server binds only to `127.0.0.1` on a randomized port. A 192-bit random
capability is delivered in the URL fragment and sent in a request header.
Requests enforce Host, Origin (when present), Fetch Metadata (when present),
method, content type and an 8192-byte limit. Subscription text stays out of the
URL and responses. Never share the temporary setup URL or installer screenshots
containing its fragment.

The CGI and state are outside the static document root. Input is treated as
literal data, not shell code. Private temporary directories, a submission lock,
symlink checks and a last-moment existing-data check protect publication.
Normal completion, timeout and catchable signals close the HTTP process group
and remove temporary state. A hard server deadline limits exposure after an
uncatchable kill; like any shell trap, cleanup cannot run after SIGKILL or power
loss. A stale install lock fails closed rather than deleting unverified data.

## Verification

Initialize the pinned kamfw submodule and install BusyBox with `httpd`, CGI,
`setsid`, `timeout` and `wget` support (Debian/Ubuntu: `busybox-static`):

```sh
git submodule update --init --depth 1 src/MagicNet/lib/kamfw
python3 scripts/install-onboarding-test.py
```

The dedicated Install Onboarding workflow runs real BusyBox HTTP/CGI tests and
ShellCheck. Android Binder calls are mocked; host success is **not** Android
SELinux, notification permission or OEM browser verification. Before release,
try first install, upgrade with existing data, skip, timeout, disabled automatic
activity launches, and install cancellation on Magisk, KernelSU and APatch.
