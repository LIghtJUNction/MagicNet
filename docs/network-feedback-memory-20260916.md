# Play feedback, memory and Tailscale investigation (2026-09-16)

## What the affected-device reports establish

Issues #304 and #305 report that Play Store does not load. Their exported bodies
cut a routing row and the middle of the support bundle. Remaining advertising
rejects and unrelated domestic connections do not establish the failed Play/GMS
path. Generic `app_process64` text is not a package identity; static selector names
such as `cn-direct` should not have been hidden as provider node names.

The feedback collector now reserves separate budgets for readiness, actual
selector paths, measured memory, Google-prioritized route samples and error logs.
It resolves only the foreground user's Play Store/GMS/GSF packages. Missing data
is explicitly unavailable. Full redacted focused/support evidence remains on the
output page for copying into the issue. Collection is read-only and on demand;
it does not change the user's routes, proxy choice or advertising policy.

For the next affected-device report: reproduce the Play failure, immediately open
WebUI feedback, choose routing feedback and the Google Play failure description.
The compact draft is copied and prefilled in GitHub. Copy the full output-page
context into a comment when the compact draft marks omitted lines. This is still
an explicit public report of package names and destination domains, not consent
to publish account credentials, private subscriptions, IPs or provider node names.
Active connections can miss failed short-lived attempts; no sample means unknown,
not a successful Play login/download test.

## Measured memory, not an assumed leak

The first controlled run is [35124386038](https://github.com/LIghtJUNction/MagicNet/actions/runs/35124386038),
artifact `core-memory-evidence/core-memory.json`. It builds fork revision
`495fb0c8006c99ff37d87136267136022c7ea739` with the configured build tags. Binary SHA256:
`33092dbb212dc9cdf2f6945fd92b071649dd25bc529d1e060e18a8a4c874237a`.

Each case starts two separate processes, waits for the private loopback API,
takes eight half-second samples, and uses the median of the last four. The core
has no TUN, proxy credentials, remote request or Tailscale account. All rule inputs
are local and hashed. Numbers below are **Linux idle RSS**, not Android or heap
measurements; the 54 source-config rule entries are not the packaged SRS count.

| Offline case | Rule entries | RSS, run 1 / 2 (MiB) | Anonymous RSS, run 1 / 2 (MiB) |
| --- | ---: | ---: | ---: |
| Minimal core | 0 | 59.97 / 58.99 | 13.17 / 12.93 |
| Advertising rules | 2 | 65.00 / 64.48 | 18.57 / 17.80 |
| China rules | 7 | 64.87 / 63.35 | 17.32 / 16.73 |
| All local rules | 54 | 74.02 / 76.23 | 27.66 / 29.62 |
| All rules, `GOMEMLIMIT=64MiB` | 54 | 76.31 / 75.96 | 28.70 / 29.23 |

In this experiment the core baseline accounts for most RSS: about 46 MiB is
file-backed and about 13 MiB anonymous before rules. Loading all rules adds about
14-17 MiB. A 64 MiB Go soft limit did not reduce RSS in these samples. File-backed
RSS and anonymous RSS must not be relabelled as live Go heap or private physical
memory. No production memory default has been changed from these short samples.
See the [Go memory-limit guide](https://go.dev/doc/gc-guide#Memory_limit) for the
managed-memory soft-limit scope; it is not a process RSS ceiling.

The affected phone's approximately 100 MB cannot be fully attributed from the old
reports. The new owned-process snapshot includes RSS, anonymous/file/shared pages,
PSS, private pages, swap, threads, the whitelisted Go knobs and configuration
counts. It verifies executable identity and process start time, and leaves missing
values unknown. TUN buffers, live connections, Android mappings and Tailscale have
not been profiled here. This experiment neither proves nor rules out a device leak.

## Confirmed Tailscale repair and UI scope

The same pinned compiled core rejects the old endpoint-only removal candidate
because its materialized DNS/route references remain, and accepts the repaired
candidate. The new removal deletes only exact generated rules; custom references
require explicit editing instead of silent policy deletion. Key and browser setup
both provision the private status credential. Resuming an unchanged configured
browser login does not restart all network connections. Removal is confirmed first;
a failed restart can be retried without another config save or auth key.

The browser suite exercises these paths at 320, 360, 390, 430 pixel, landscape and
desktop viewports. Actual narrow-phone and desktop screenshots were inspected.
This is targeted Tailscale/feedback layout work plus shared wrapping action labels,
not a claim that every WebUI page has been completely redesigned or that a real
Tailscale account was connected.

## Remaining acceptance boundaries

The AVD storage correction uses an explicit directory and validates both the SDK
config and descriptor before appending settings. Its separate real-SDK test covers
creation/discovery, not kernel boot or network operation. Play/GMS (#253), physical
config recovery (#254), staged TUN-stack migration (#261) and repository protection
administration (#281) retain their own acceptance criteria. Release and host-test
success must not be used as evidence that the affected phone's Play Store works.
