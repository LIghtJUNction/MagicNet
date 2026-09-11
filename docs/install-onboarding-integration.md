# Browser setup integration

PRs #184, #185 and #186 proposed the same installation feature concurrently.
The integration keeps one production entry: `magicnet_install_onboarding` in
`customize.sh`, backed by `lib/magicnet/onboarding/`. It does not install or run
three collectors and does not reopen a second page after the user skips one.

#184 is reconciled against the merged #185 implementation rather than adding
its parallel `setup/`, `install_web.sh` and `web_input` implementation. Its
Traditional Chinese support and community/author/feedback links are carried
into the production page. Existing token, HTTP/CGI, timeout, upgrade retention
and literal-input tests remain enabled. Main's corrected isolated installer
fixture (including `mv`) is retained, rather than reintroducing the failed
pre-merge packaging fixture.

#186 contributes browser-role selection and browser interaction coverage to
the same entry. Alternative setup implementations and their divergent HTTP
protocols must not be wired into `customize.sh`. New tests must exercise the
production `/cgi-bin/setup/{health,save,skip}` interface.

No historical failed run is deleted or marked successful. New commits need
fresh CI results. Host/browser CI does not replace testing Android Binder,
SELinux, notification permissions and background launch policy on a device.
