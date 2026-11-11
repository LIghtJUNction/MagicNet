# System certificate disable policy

Root-only script: `./certificate-policy preview|disable|restore|apply|status`.
`preview` lists matching public certificate metadata without changing trust. `disable`
persists enabled intent and applies policy; `restore` persists disabled intent and
restores only owned markers. `apply` obeys intent; boot-completed invokes it. The boot wrapper returns immediately
when intent is absent or false, without touching trust markers or broadcasting changes.
Uninstall invokes restore before other teardown. No CA/private key is installed.

Configuration: `.config/magicnet/certificate-policy/enabled` (`true`/`false`, absent
means false), and `rules`. One literal rule per line; blank lines and `#` comments
ignored. Rules combine with OR:

```
sha256=5cc3d78e4e1d5e45547a04e6873e64f90cf9536d1ccc2ef800f355c4c5fd70fd
subject=CN=CFCA EV ROOT,O=China Financial Certification Authority,C=CN
keyword=china
```

Fingerprints match DER SHA-256 (case insensitive, colons optional); subjects match
full RFC2253 strings exactly. Keywords match case-insensitive literal substrings
of subject only, not issuer (avoids disabling unrelated leaf chains), with no regex.
Defaults match China, BJCA, GDCA, UniTrust and TrustAsia. Hong Kong/Taiwan and the
known local Reqable/HttpCanary roots are outside that default list. Organization
strings are selection criteria, not proof of ownership, interception or coercion.

Uses Android user 0 `cacerts-removed`, never deletes source roots or changes other
users. Existing user-disabled certificates are not adopted. Owned public certificate
copies form a write-ahead recovery journal under `.state/certificate-policy/owned`.
Each marker is atomically published; the operation uses an OS file lock. Partial
operations remain pending and are recoverable by apply/restore, not all-at-once
atomic across files. Changed markers fail safely without deleting someone else's
content. `.state/machines/certificate-policy.state` exposes schema/phase/counts;
config holds intent. The wrapper refreshes SELinux labels and broadcasts trust
store changes; active apps may require restarting. Private app/Go/browser stores
may ignore Android disable markers. A failed restore must be resolved before
allowing the module manager to delete its ownership journal.

The ten markers previously created manually during device diagnostics are pre-existing
user disables. They are deliberately not silently adopted by this implementation.
