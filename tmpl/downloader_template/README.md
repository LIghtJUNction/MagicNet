# Module downloader template

Build a small, one-shot Android arm64 installer for a module's latest stable GitHub release.
It runs only during flashing and delegates installation to the current manager's existing
`install_module` function in an isolated subshell. It never recursively launches ksud.

```sh
kam tmpl import downloader_template.tar.gz --force
kam init magicnet_installer -t downloader_template.tar.gz --id magicnet_installer \
  --project-name 'MagicNet Installer' --author LIghtJUNction \
  --var target_repository=LIghtJUNction/MagicNet \
  --var target_asset=MagicNet.zip --var target_module=MagicNet
kam build magicnet_installer
```

Go 1.24+ builds a static Android arm64 helper; no curl, jq or Python is required
on the phone. `src/<id>/download.json` controls repository, asset, expected module
ID, candidate HTTPS proxy prefixes and the direct-path threshold (256 KiB/s).
The mirror list is a configurable candidate list, not a guarantee of availability.

The helper obtains release metadata directly from api.github.com over verified TLS.
Then it probes 256 KiB of the actual ZIP, with a 6-second deadline. A healthy direct
path is preferred. Otherwise mirrors are measured concurrently and sorted by measured
throughput. Failed, truncated, HTML, hash-mismatched or invalid-ZIP responses are rejected
and the next route is attempted. Failed range probes still get one full-GET fallback.
Full transfers are bounded to 10 minutes per route and 15 minutes for the entire run.
Only a complete SHA-256/CRC-checked ZIP with the expected module ID is installed.

Metadata is deliberately never trusted to a public download proxy. If the GitHub API
cannot be reached or omits its asset digest, installation stops with a clear error;
this template does not promise operation when every trusted metadata path is blocked.
No old release is silently substituted. Network failure happens before the target
installer is called; a target install failure is propagated to the manager.

Supported: Android arm64, booted Magisk/KernelSU/APatch managers exposing the usual
shell installer API. Recovery/offline installation is not supported. Keep the inert
downloader module or remove it after installation; it has no boot service.

Proxy format: https://proxy.example/https://github.com/owner/repo/releases/download/...
Candidates: ghfast.top, ghproxy.net, gh-proxy.com. Their availability is measured on
installation, and each downloaded byte is checked against GitHub's independent digest.

Progress output reports each probe and ranked route, then percentage, MiB transferred,
average KiB/s and estimated time remaining once per second (including stalled reads).
A 100% transfer is followed by separate SHA-256 and ZIP validation before installation.
