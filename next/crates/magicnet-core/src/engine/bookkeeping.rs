//! Operation receipts, canonical state publication and bounded retention.
use super::*;

impl<P: Platform> Engine<P> {
    pub(super) fn prune_artifacts(&self) -> Result<()> {
        let mut protected = std::collections::BTreeSet::new();
        if let Some(id) = self.runtime()?.generation {
            protected.insert(id);
        }
        if let Some(saved) = self.root.read_json::<Runtime>(".state/last-good.json")? {
            if let Some(id) = saved.generation {
                protected.insert(id);
            }
        }
        if let Some(switch) = self.root.read_json::<Switch>(SWITCH)? {
            protected.insert(switch.candidate);
            if let Some(id) = switch.previous.generation {
                protected.insert(id);
            }
        }
        for entry in self.root.list(".state/generations", 128)? {
            if entry.kind != kamfw::EntryKind::Directory || !kamfw::fs::valid_id(&entry.name) {
                return Err(Error::new(
                    "unknown_artifact",
                    "An unrecognized generation entry was retained",
                ));
            }
            let id = &entry.name;
            if protected.contains(id) || self.platform.find(&self.root, id)?.is_some() {
                continue;
            }
            let dir = format!(".state/generations/{id}");
            let contents = self.root.list(&dir, 8)?;
            if contents
                .iter()
                .any(|entry| entry.kind != kamfw::EntryKind::File || entry.name != "config.json")
            {
                continue;
            }
            let lease_path = format!(".state/leases/{id}");
            let lease = match Guard::acquire(
                &self.root,
                &lease_path,
                LockMode::Exclusive,
                Duration::ZERO,
                false,
            ) {
                Err(error) if error.code == "busy" => continue,
                result => result?,
            };
            if self.platform.find(&self.root, id)?.is_some() {
                continue;
            }
            self.root.remove(&format!("{dir}/config.json"))?;
            self.root.remove_dir(&dir)?;
            self.root
                .remove_socket(&format!(".state/control/{id}.sock"))?;
            self.root.remove(&format!(".state/workers/{id}.json"))?;
            drop(lease);
            // The immutable generation no longer exists and is not a recovery
            // target. It can never be launched again, unlike the global lock.
            self.root.remove(&lease_path)?;
        }
        if self.root.list(".state/generations", 128)?.len() >= 64 {
            return Err(Error::new(
                "artifact_limit",
                "Too many retained generations require recovery before another activation",
            ));
        }
        Ok(())
    }

    pub(super) fn operation_view(&self) -> Result<Value> {
        let Some(operation) = self.root.read_json::<Operation>(".state/operation.json")? else {
            return Ok(Value::Null);
        };
        let phase = if operation.phase == "running" {
            match operation.owner.as_ref().map(Identity::observe) {
                Some(Observation::Running) => "running",
                Some(Observation::Absent | Observation::Foreign) => "interrupted",
                _ => "unknown",
            }
        } else {
            operation.phase.as_str()
        };
        Ok(
            json!({"id":operation.id,"method":operation.method,"phase":phase,
            "outcome":operation.outcome}),
        )
    }

    // Owning the exclusive lock proves that a previous writer no longer owns
    // this runtime, even on devices where /proc observations are restricted.
    // Settle its receipt only after resource/transaction recovery succeeded.
    pub(super) fn settle_interrupted_operation(&self) -> Result<()> {
        let Some(mut operation) = self.root.read_json::<Operation>(".state/operation.json")? else {
            return Ok(());
        };
        if operation.phase != "running" {
            return Ok(());
        }
        operation.phase = "interrupted".into();
        operation.outcome = Some(json!({"ok":false,"error":Error::new(
            "interrupted", "The previous writer exited before publishing its result; recovery has completed").changed()}));
        if !kamfw::fs::valid_id(&operation.id) {
            return Err(Error::new(
                "invalid_operation",
                "The operation journal has an invalid identity",
            ));
        }
        self.root.write_json(
            &format!(".state/operations/{}.json", operation.id),
            &operation,
        )?;
        self.root.write_json(".state/operation.json", &operation)
    }

    /// The one public file-backed runtime projection. Private recovery journals
    /// remain implementation details; readers do not combine marker files.
    pub(super) fn publish_canonical(&self) -> Result<()> {
        let status = self.read("status")?;
        let settings = self.settings()?;
        let operation = status.get("operation").filter(|v| !v.is_null());
        let phase = operation
            .and_then(|o| o.get("phase"))
            .and_then(Value::as_str)
            .unwrap_or("idle");
        let phase = match phase {
            "running" | "completed" | "failed" | "interrupted" | "unknown" | "idle" => phase,
            _ => "unknown",
        };
        let configured = if status["configured"] == true {
            "enabled"
        } else {
            "disabled"
        };
        let mode = match settings.mode {
            crate::model::Mode::Tun => "tun",
            crate::model::Mode::Ebpf => "ebpf",
        };
        let effective = status["phase"].as_str().unwrap_or("unknown");
        let recovery = status["recovery_pending"] == true;
        let text = format!("schema=1\nconfigured={configured}\neffective={effective}\nmode={mode}\nconfigured_revision={}\neffective_revision={}\noperation_phase={phase}\nsource_count={}\nrecovery_pending={}\nnetwork_health=unknown\n",
            settings.revision, status["effective_revision"].as_u64().unwrap_or(0),
            settings.sources.len(), u8::from(recovery));
        self.root
            .write(".state/machines/runtime.state", text.as_bytes())
    }

    pub(super) fn prune_operations(&self) -> Result<()> {
        let mut files = self.root.list(".state/operations", 256)?;
        files.retain(|file| {
            file.kind == kamfw::EntryKind::File
                && file
                    .name
                    .strip_suffix(".json")
                    .is_some_and(kamfw::fs::valid_id)
        });
        // IDs are random, not time-sorted. Retention is a bounded replay window,
        // explicitly not an unbounded exactly-once promise.
        while files.len() >= 128 {
            let file = files.remove(0);
            self.root
                .remove(&format!(".state/operations/{}", file.name))?;
        }
        Ok(())
    }
}
