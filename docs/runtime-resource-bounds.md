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

Tests cover capacity/reuse, eventual reaping, idle/closed pipes, output
flooding, escaped pipe writers, scoped Wi-Fi publication, shared config
observations, oversized/FIFO JSON inputs and a real CLI blocked on a lock.
These are host regressions, not Android memory measurements. This change
does not diagnose the device's sing-box heap or promise a particular RSS.
CLI observation/dispatch publication policy is addressed separately by
PR #284; this patch intentionally does not duplicate that change.
