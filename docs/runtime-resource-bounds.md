# Runtime resource bounds

Command/proc readers reserve a slot before spawning a helper. At most 64
active or deferred helpers share one reaper thread per CLI process. A child
stuck in uninterruptible kernel sleep retains its slot; saturation rejects
new work rather than allocating another thread or an unbounded PID queue.
The reaper waits only for handed-off PIDs and sleeps indefinitely when idle.
Shell lifecycle workers and their parent-death watchdogs use the same pool.

Captured command output uses nonblocking pipes owned by the caller, not
detached stdout/stderr threads. Each drain pass has a fixed work budget;
flooding one stream cannot suppress the other stream or the monotonic
deadline. Timeout cleanup closes the captured descriptors and preserves
the available prefix with an explicit truncation indication. Escaped
descendants retaining pipe writers cannot keep a reader thread alive.

Full state reconciliation parses the sing-box JSON once and borrows that
observation for transparent/Tailscale records. Wi-Fi policy application
publishes only Wi-Fi and supervisor records, sharing the Wi-Fi process
observation. The configured polling interval is deliberately unchanged.
Existing per-domain state format, privacy, change detection and transaction
publication are retained. JSON observation enforces a byte bound on the
read itself and rejects symlinks/nonregular files without opening a FIFO
in blocking mode. Log-tail reads also enforce their limit on the read.

Config apply and transparent transitions now use the existing bounded
lifecycle lock acquisition instead of indefinite flock(LOCK_EX).

Explicit `service start|stop|restart` actions allow up to ten seconds to acquire
that lock so a periodic hotspot reconciliation can finish. Contention emits one
`lifecycle.waiting` message on stderr; expiry retains the existing `config apply
is still busy` diagnostic and nonzero CLI exit status. Other configuration
mutations keep their two-second budget. The lock is still held across all existing startup checks,
transaction recovery and lifecycle work; a running PID never bypasses them.
The ten seconds bound acquisition only, not the duration of the lifecycle action.

Tests cover capacity/reuse, eventual reaping, idle/closed pipes, output
flooding, escaped pipe writers, scoped Wi-Fi publication, shared config
observations, oversized/FIFO JSON inputs and a real CLI blocked on a lock.
These are host regressions, not Android memory measurements. This change
does not diagnose the device's sing-box heap or promise a particular RSS.
CLI observation/dispatch publication policy is addressed separately by
PR #284; this patch intentionally does not duplicate that change.

On kernels without `close_range`, fork-only descriptor cleanup enumerates
`/proc/self/fd` using raw `getdents64` and a fixed stack buffer. It closes
existing handles, including descriptors above a lowered soft limit, rather
than scanning every unused slot on every proc read. Only unavailable procfs
falls back to the hard-limit sweep. No allocating directory iterator or
mutex is used in the fork child. Regression tests force `ENOSYS` for
`close_range` inside child-only seccomp filters and exercise identical
keepers, descriptor zero, high descriptors and truncated directory records.

## WebUI command output

The native spawn collector retains at most 8,388,608 UTF-16 code units and
65,536 data events across stdout and stderr, including each stream's join
separators. Empty events count toward the entry limit. Overflow clears both
buffers and discards subsequent data, but does not release the serial execution
slot until native exit/error. Completion reports an explicit output-limit error,
never successful partial machine JSON. Every completion path clears the buffers
and unregisters the callback. Caller timeout still does not cancel a native
command or release its slot. These limits bound retained collector data, not
incoming native allocations, downstream copies or total WebView RSS.

## Wi-Fi policy lists and local curl

SSID/BSSID list readers, editors and the resident policy loop share the existing
64 KiB descriptor-verified limit. Malformed or oversized lists fail explicitly
instead of becoming empty policies. Rejected list edits preserve the previous
file; invalid application input cannot query/change the Clash mode or publish
new Wi-Fi runtime state. Editors also enforce the limit before persisting a list.

Local API curl calls, including node delay and authenticated Tailscale status,
reuse the shared child budget, parent-death signal, process group, nonblocking
captures and parent-side deadline. A timeout or either stream's truncation is an
API error, not a successful partial response. Existing curl timeouts are retained;
the parent allows one second of shutdown grace (the shared print path allows up
to six seconds for its four/five-second curl requests).

Private curl configuration stays on stdin, never argv. Input is borrowed and
capped at 64 KiB before spawn, written nonblocking with a finite per-iteration
budget alongside both output drains, and closed immediately after delivery to
provide EOF. Empty input also closes immediately; premature closure is a delivery
error. No detached writer thread is created. Tailscale API configuration reads
use the existing 4 MiB bounded JSON reader.

Host regressions cover exact output/list/input boundaries, empty-event floods,
late native completion after caller timeout, private stdin/argv separation,
bidirectional pipe pressure, early stdin closure, repeated FD/thread counts,
rejected partial JSON and killing a real CLI while its curl stand-in is active.
They do not measure the Android sing-box heap or certify the project leak-free.

## Hotspot policy transactions

Both `cli hotspot enable|disable` and generic hotspot selector writes use the
same bounded lifecycle lock. The previous persisted choice is read without
quarantining malformed input or following symlinks; unknown intent is an error,
not an implicit direct policy. A failed save cannot change the runtime selector,
Android offload settings, routes or the watcher. Selector store reads and writes
share a 4 MiB limit, including optional legacy migration cleanup.

After saving the new intent, configuration apply reuses the held guard. On
failure, compensation restores the previous choice (including an absent key),
keeps unrelated selectors, and restores the observed runtime selection separately
from configured intent. API or persistence failures do not skip independent
resource cleanup; unsuccessful compensation is reported explicitly. Periodic
`hotspot reconcile` uses a nonblocking attempt on the same lifecycle lock and
skips a contended cycle without running route/policy changes. It does not report
the dataplane ready or turn an I/O failure into a successful skip. The watcher
will retry on its next cycle. An attempted reconcile publishes canonical
observations after releasing the lock, on both success and failure, through the
existing publisher. A skipped cycle does not run that publisher. Other hotspot
actions retain their generic post-command publication. This does not claim an
atomic snapshot across external resources or replace the startup recovery path.

Temporary-module regressions cover both directions, repeated enable, each
forward failure, concurrent lifecycle operations, API/save compensation failure,
invalid or symlinked stores, and the generic selector entry point. They do not
change host Android settings or exercise real tethering hardware.
