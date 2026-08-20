# Security policy

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose secrets,
execute commands as root, bypass MCP authentication, or corrupt an installed
module. Use GitHub's private vulnerability reporting for this repository. If
that option is unavailable, contact the maintainer privately before sharing
proof-of-concept details.

Include the affected version or commit, threat model, reproduction steps,
impact, and any proposed mitigation. Remove subscription URLs, tokens, device
identifiers, and unrelated logs.

## Supported versions

Security fixes are made on the current `main` branch and released in the next
available MagicNet version. Users should reproduce against the latest release
before reporting an older build.

## Security boundaries

MagicNet is privileged Android networking software. Reviews should preserve
these properties:

- Android runtime paths are module-owned and are not redirected by untrusted
  environment variables.
- Shell inputs remain data: validate allowlisted values and avoid constructing
  executable syntax from user-controlled strings.
- Subscription and configuration changes validate candidates and activate them
  atomically, with bounded cleanup after interruption.
- Process lifecycle operations target only binaries and runtime paths owned by
  MagicNet.
- MCP stays disabled by default, binds to an explicit IP literal, and requires
  a secret before exposing control operations.
- Backups, diagnostic bundles, logs, and errors do not disclose stored secrets.

Changes to authentication, command execution, file permissions, backup or
restore, subscription fetching, or process ownership require regression tests
for both the accepted path and expected rejection path.
