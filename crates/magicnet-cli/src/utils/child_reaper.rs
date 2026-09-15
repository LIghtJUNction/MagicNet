//! One fixed-capacity reaper for helpers that cannot exit within their deadline.
//!
//! Reserve before fork/spawn. An unreaped child keeps its reservation, so
//! repeated kernel stalls apply backpressure instead of growing threads or
//! an unbounded PID queue. Only explicitly handed-off children are reaped.
use std::io;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::OnceLock;
use std::thread::{self, Thread};
use std::time::Duration;

const CAPACITY: usize = 64;
const RESERVED: i32 = -1;
static SLOTS: [AtomicI32; CAPACITY] = [const { AtomicI32::new(0) }; CAPACITY];
static WORKER: OnceLock<Result<Thread, String>> = OnceLock::new();

pub(crate) struct ChildReservation {
    index: usize,
    deferred: bool,
}

fn reserve_slot(slots: &[AtomicI32]) -> Option<usize> {
    slots.iter().position(|slot| {
        slot.compare_exchange(0, RESERVED, Ordering::AcqRel, Ordering::Relaxed)
            .is_ok()
    })
}

pub(crate) fn reserve_child() -> Result<ChildReservation, String> {
    WORKER
        .get_or_init(|| {
            thread::Builder::new()
                .name("mn-child-reaper".to_string())
                .stack_size(128 * 1024)
                .spawn(reap_loop)
                .map(|handle| handle.thread().clone())
                .map_err(|err| format!("start child reaper: {err}"))
        })
        .as_ref()
        .map_err(Clone::clone)?;
    let index = reserve_slot(&SLOTS).ok_or_else(|| {
        "child cleanup capacity exhausted; refusing to spawn another helper".to_string()
    })?;
    Ok(ChildReservation {
        index,
        deferred: false,
    })
}

impl ChildReservation {
    pub(crate) fn defer(mut self, pid: libc::pid_t) {
        debug_assert!(pid > 0);
        // This reservation has exactly one owner. Hand-off happens only
        // after that owner stops calling wait/try_wait for this child.
        SLOTS[self.index].store(pid, Ordering::Release);
        self.deferred = true;
        if let Some(Ok(worker)) = WORKER.get() {
            worker.unpark();
        }
    }
}

impl Drop for ChildReservation {
    fn drop(&mut self) {
        if !self.deferred {
            SLOTS[self.index].store(0, Ordering::Release);
        }
    }
}

fn reap_loop() {
    loop {
        let mut pending = false;
        for slot in &SLOTS {
            let pid = slot.load(Ordering::Acquire);
            if pid <= 0 {
                continue;
            }
            let result = unsafe { libc::waitpid(pid, std::ptr::null_mut(), libc::WNOHANG) };
            if result == pid
                || (result < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD))
            {
                slot.store(0, Ordering::Release);
            } else {
                // EINTR also waits until the next pass; signals cannot
                // create a busy loop or defeat a caller's deadline.
                pending = true;
            }
        }
        if pending {
            thread::park_timeout(Duration::from_millis(250));
        } else {
            // unpark's token closes the enqueue-before-park race.
            thread::park();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn capacity_is_reserved_before_spawn_and_can_be_reused() {
        let slots = [AtomicI32::new(0), AtomicI32::new(0)];
        assert_eq!(reserve_slot(&slots), Some(0));
        assert_eq!(reserve_slot(&slots), Some(1));
        assert_eq!(reserve_slot(&slots), None);
        slots[0].store(123, Ordering::Release);
        assert_eq!(
            reserve_slot(&slots),
            None,
            "deferred children retain capacity"
        );
        slots[1].store(0, Ordering::Release);
        assert_eq!(reserve_slot(&slots), Some(1));
    }
    #[test]
    fn shared_worker_eventually_releases_a_handed_off_child() {
        let permit = reserve_child().unwrap();
        let index = permit.index;
        let child = std::process::Command::new("sh")
            .args(["-c", "sleep 0.05"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        permit.defer(pid);
        drop(child);
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while SLOTS[index].load(Ordering::Acquire) == pid {
            assert!(std::time::Instant::now() < deadline, "child was not reaped");
            thread::sleep(Duration::from_millis(10));
        }
    }
}
