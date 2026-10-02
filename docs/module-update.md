# WebUI module updates

`module-update` is a separately designed exception to the machine interface's
read-only default. It updates only the official `LIghtJUNction/MagicNet` module.
There is no URL, repository, executable or shell-command input.

## Commands and concurrency

```text
cli --json module-update status
cli --json module-update check <request-id>
cli --json module-update install <expected-installed-version> <expected-latest-version> <request-id>
```

Request IDs contain 8–64 ASCII letters, digits, underscores or hyphens. Versions
use `vMAJOR.MINOR.PATCH`. `check` and `install` return an accepted schema-1 response
and detach a device worker from the WebUI session. Reopening the WebUI reads
`status`, rather than reconstructing a task from browser memory or human logs.
The worker inherits a locked file descriptor: there is no unlocked gap between
acceptance and background execution. A competing request receives `busy`;
repeating the same ID and identical intent returns the same operation. Reusing
an ID for different intent is a conflict. A bounded persistent receipt ledger
keeps the last 128 results and 4,096 consumed IDs. An older consumed ID whose
result has expired is rejected as a conflict, never executed again. Exhausting
the ID budget refuses further requests rather than forgetting replay history;
operator migration is then required. Intent, acceptance and receipt recording
use the existing recoverable multi-file transaction. Install compares both expected
versions with the checked metadata and the effective installed baseline.

`.config/magicnet/module-update.conf` records user intent, its request ID and the
expected versions. `.state/machines/module-update.state` is the sole public
canonical record. Its schema-1 bounded tokens separate operation phase,
effective installed version, candidate version, manager and recovery evidence.
Private download, release metadata and lock files under `.state/module-update/`
are recovery inputs, never a second public status API. Every producer phase is
published by synced atomic replacement. A crashed producer is reported as
interrupted, not running or successfully installed.

The private recovery receipt ledger is
`.state/module-update/receipts.json`, with a 512 KiB read limit. It
stores normalized request/result data, never network credentials or raw errors.
It is explicitly copied into the identity-verified staged module after success;
the updater does not rely on copying the old state tree.

Successful envelopes use `module-update.status`, `module-update.check` or
`module-update.install`. All share this data shape:

```json
{"installed":{"version":"v1.5.20","version_code":1789322931011},
 "latest":{"version":"v1.5.21","version_code":1789322931012},
 "update_available":true,"phase":"available","manager":"kernelsu",
 "supported":true,"busy":false,"reboot_required":false,
 "recovery_required":false,"error_code":null,"request_id":"request_1234"}
```

Phases are `idle`, `checking`, `available`, `up_to_date`, `downloading`,
`verifying`, `installing`, `reboot_required` and `failed`. Missing versions and
uncertain availability use JSON null. Errors have fixed `module-update.*` codes
and sanitized messages; neither command output nor download URLs are exposed.

## Download and package trust

Only the official GitHub latest **non-draft, non-prerelease** release is queried.
The tag must be a bounded stable version. The core asset name is exactly
`MagicNet-core.zip`, and checksum asset exactly `SHA256SUMS`, with fixed official
release download paths. The GitHub asset's SHA-256 digest and the exact
`SHA256SUMS` entry must both match the downloaded ZIP. This is GitHub HTTPS and
two matching release digests, not independent public-key signature verification.

Requests use the existing trusted curl binary with `.curlrc`, proxy and unsafe
loader environment disabled. Each HTTPS redirect is explicitly validated;
only GitHub's official release asset hosts are permitted, resolved public
addresses are pinned, and HTTP downgrade, userinfo, malformed headers and
excessive redirects are rejected. Metadata, checksum, archive and command
output have bounds. Disk headroom is checked before downloads and installation.

ZIP paths, duplicate/local-header ambiguity, entry counts, total extracted
size, file types, module identity, version, component manifest and architecture
are validated before manager execution. The sole allowed core link is
`cli -> bin/magicnet-cli`; that executable is an integrity-checked component.
The core component bootstrap ELF and manifest architecture must match the
device. Existing component installation validates immutable component hashes.

## Manager installation and recovery

Root and a real KernelSU, Magisk or APatch manager are required. Managers are
invoked at fixed absolute paths with argument arrays and the verified private
archive. KernelSU's kernel interface is checked, not inferred from a binary
existing. The existing installer performs its documented configuration
migration and component checks; the updater does not copy stale PID/owner state
or replace the active module directory itself.

An existing pending `modules_update/MagicNet`, active `update`, `disable` or
`remove` marker prevents a new install. No foreign pending package is deleted.
The installer is noninteractive, and successful exit is insufficient on its
own: the staged module identity/version plus the active manager update marker
must be verified. Then the result is `reboot_required`, never active success.
KernelSU may rewrite active `module.prop` during staging, so the status keeps
the pre-install effective baseline until the staged directory has disappeared
after a known different boot and the new installed metadata, component-manifest
version and actual installed CLI hash match. A missing manifest or mismatched
active payload is unknown, not a successful version observation. The updater
never reboots automatically.

Before manager execution, download and verification failures leave active code
and user configuration intact. Once a root manager starts, it owns its staging
transaction. A partial failure or interrupted manager is **not** rolled back by
deleting paths merely because they appeared during the call: no exclusive
ownership can be proven against independent manager activity. Pending evidence
is retained, `recovery_required` is true, and further installation is refused
until the manager resolves it. Existing installer ordinary-error rollback
remains in force; this API does not claim crash-safe atomicity for the manager.

Error codes include `invalid_request`, `busy`, `conflict`, `unavailable`,
`not_root`, `unsupported_manager`, `disabled`, `pending_update`, `network`,
`invalid_release`, `integrity`, `invalid_archive`, `incompatible`, `no_space`,
`io`, `interrupted`, `install_failed`, `staging_unverified` and
`recovery_required`, all prefixed with `module-update.`.
