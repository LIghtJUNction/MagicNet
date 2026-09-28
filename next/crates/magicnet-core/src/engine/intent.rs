//! STOP has a short, separate lock so it can interrupt a busy writer. No
//! caller holds this lock while waiting for the main runtime lock.
use super::*;

const INTENT_LOCK: &str = ".state/intent.lock";

impl<P: Platform> Engine<P> {
    pub(super) fn stop_snapshot(&self) -> Result<Option<Vec<u8>>> {
        let _guard = Guard::acquire(
            &self.root,
            INTENT_LOCK,
            LockMode::Shared,
            Duration::from_secs(1),
            false,
        )?;
        self.root.read(STOP, 256)
    }

    pub(super) fn request_stop(&self, id: &str) -> Result<()> {
        let _guard = Guard::acquire(
            &self.root,
            INTENT_LOCK,
            LockMode::Exclusive,
            Duration::from_secs(1),
            true,
        )?
        .ok_or_else(|| Error::new("lock_unavailable", "The stop-intent lock is unavailable"))?;
        self.root.write_json(STOP, &json!({"schema":1,"id":id}))?;
        if let Some(active) = self
            .root
            .read_json::<Operation>(".state/operation.json")
            .map_err(|error| error.changed())?
        {
            if active.phase == "running" {
                self.root
                    .write(".state/cancel", active.id.as_bytes())
                    .map_err(|error| error.changed())?;
            }
        }
        Ok(())
    }

    pub(super) fn authorize_start(&self, id: &str, snapshot: &Option<Vec<u8>>) -> Result<()> {
        let _guard = Guard::acquire(
            &self.root,
            INTENT_LOCK,
            LockMode::Exclusive,
            Duration::from_secs(1),
            true,
        )?
        .ok_or_else(|| Error::new("lock_unavailable", "The stop-intent lock is unavailable"))?;
        if self.root.read("disable", 1)?.is_some() || self.root.read("remove", 1)?.is_some() {
            return Err(Error::new(
                "module_disabled",
                "Enable the module in its manager before starting it",
            ));
        }
        if self.root.read(STOP, 256)? != *snapshot
            || self
                .root
                .read(".state/cancel", 64)?
                .is_some_and(|value| value == id.as_bytes())
        {
            return Err(Error::new(
                "cancelled",
                "A newer stop superseded this queued activation",
            ));
        }
        // Comparison and removal share the same small lock used by STOP.
        // This is not an unprotected read-then-unlink of concurrent intent.
        self.root.remove(STOP)
    }
}
