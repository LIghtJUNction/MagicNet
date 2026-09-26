//! Immutable generations, explicit activation and recoverable lifecycle.
use super::*;

impl<P: Platform> Engine<P> {
    pub(super) fn activate(&self, settings: &mut Settings) -> Result<Value> {
        if settings.mode == crate::model::Mode::Ebpf {
            return Err(Error::new(
                "acceptance_required",
                "The rewritten eBPF adapter is not accepted yet; the mode was not changed",
            ));
        }
        let previous = self.runtime()?;
        let observed = previous
            .identity
            .as_ref()
            .map(|id| self.platform.observe(&self.root, id))
            .unwrap_or(Observation::Absent);
        if matches!(observed, Observation::Unknown | Observation::Foreign) {
            return Err(Error::new(
                "ownership_unknown",
                "The existing process must be reconciled before activation",
            ));
        }
        if observed == Observation::Running && previous.revision == settings.revision {
            return self.read("status");
        }
        let mut sets = Vec::new();
        for source in settings.sources.iter().filter(|source| source.enabled) {
            let cache = self
                .root
                .read_json::<Value>(&format!(".config/nodes/{}.json", source.id))?
                .ok_or_else(|| {
                    Error::new(
                        "source_not_ready",
                        "A source has no validated node cache; refresh before applying",
                    )
                })?;
            sets.push(cache);
        }
        if let Some(local) = self.root.read_json::<Value>(".config/nodes/local.json")? {
            sets.push(local);
        }
        let config = subscription::attach(&settings.template, &sets)?;
        self.prune_artifacts()?;
        let candidate = kamfw::random_id()?;
        self.root.write_json(
            &format!(".state/generations/{candidate}/config.json"),
            &config,
        )?;
        self.platform.validate(&self.root, &candidate)?;
        if self.root.read(STOP, 256)?.is_some() {
            return Err(Error::new("cancelled", "A stop superseded this activation"));
        }
        let switch = Switch {
            schema: 1,
            previous,
            was_running: observed == Observation::Running,
            candidate: candidate.clone(),
        };
        self.root.write_json(SWITCH, &switch)?;
        let activation = (|| {
            if switch.was_running {
                self.platform.stop(
                    &self.root,
                    switch.previous.identity.as_ref().ok_or_else(|| {
                        Error::new("invalid_runtime", "An active runtime has no owner")
                    })?,
                )?;
            }
            let identity = self.platform.launch(&self.root, &candidate)?;
            self.root
                .write_json(".state/pending-process.json", &identity)?;
            self.platform.ready(&self.root, &candidate, &identity)?;
            if self.root.read(STOP, 256)?.is_some() {
                return Err(Error::new("cancelled", "A stop superseded this activation").changed());
            }
            settings.enabled = true;
            settings.revision += 1;
            let runtime = Runtime {
                generation: Some(candidate.clone()),
                identity: Some(identity),
                revision: settings.revision,
                phase: "running".into(),
            };
            self.commit(&[
                self.change(SETTINGS, Some(serde_json::to_vec(settings)?))?,
                self.change(RUNTIME, Some(serde_json::to_vec(&runtime)?))?,
                self.change(".state/last-good.json", Some(serde_json::to_vec(&runtime)?))?,
            ])?;
            self.root.remove(SWITCH)?;
            self.root.remove(".state/pending-process.json")?;
            Ok(
                json!({"phase":"running","revision":settings.revision,"network_health":"not_verified"}),
            )
        })();
        if activation.is_err() && self.recover().is_err() {
            return Err(Error::new("rollback_incomplete", "Activation failed and recovery remains incomplete; ownership evidence was retained").changed());
        }
        activation
    }

    /// Must be called only while holding the native exclusive lock.
    pub(super) fn recover(&self) -> Result<()> {
        Transaction::recover(&self.root)?;
        let stopping = self.root.read(STOP, 256)?.is_some();
        let Some(switch) = self.root.read_json::<Switch>(SWITCH)? else {
            if stopping {
                self.settle_stop()?;
            }
            return Ok(());
        };
        if switch.schema != 1 || !kamfw::fs::valid_id(&switch.candidate) {
            return Err(Error::new(
                "invalid_recovery",
                "The runtime recovery journal is invalid",
            ));
        }
        let current = self.runtime()?;
        if current.generation.as_deref() == Some(&switch.candidate) {
            if stopping {
                self.settle_stop()?;
            }
            self.root.remove(SWITCH)?;
            self.root.remove(".state/pending-process.json")?;
            return Ok(());
        }
        // Discovery matches the exact immutable generation path. A crash
        // between spawn and pidfile publication cannot orphan an owned child.
        if let Some(identity) = self.platform.find(&self.root, &switch.candidate)? {
            self.platform.stop(&self.root, &identity)?;
        }
        let mut restored = switch.previous.clone();
        if switch.was_running && !stopping {
            let identity = restored
                .identity
                .as_ref()
                .ok_or_else(|| Error::new("invalid_recovery", "The rollback owner is missing"))?;
            match self.platform.observe(&self.root, identity) {
                Observation::Running => (),
                Observation::Absent => {
                    let generation = restored
                        .generation
                        .as_deref()
                        .filter(|s| kamfw::fs::valid_id(s))
                        .ok_or_else(|| {
                            Error::new("invalid_recovery", "The rollback generation is missing")
                        })?;
                    let identity = self
                        .platform
                        .find(&self.root, generation)?
                        .map(Ok)
                        .unwrap_or_else(|| self.platform.launch(&self.root, generation))?;
                    self.platform.ready(&self.root, generation, &identity)?;
                    restored.identity = Some(identity);
                }
                _ => {
                    return Err(Error::new(
                        "ownership_unknown",
                        "The rollback process cannot be safely identified",
                    )
                    .changed())
                }
            }
        }
        self.root.write_json(RUNTIME, &restored)?;
        if stopping {
            self.settle_stop()?;
        }
        self.root.remove(SWITCH)?;
        self.root.remove(".state/pending-process.json")?;
        Ok(())
    }

    pub(super) fn settle_stop(&self) -> Result<()> {
        let runtime = self.runtime()?;
        let mut settings = self.settings()?;
        if settings.enabled {
            settings.enabled = false;
            settings.revision += 1;
            self.commit(&[self.change(SETTINGS, Some(serde_json::to_vec(&settings)?))?])?;
        }
        if let Some(identity) = runtime.identity.as_ref() {
            match self.platform.observe(&self.root, identity) {
                Observation::Running => self.platform.stop(&self.root, identity)?,
                Observation::Absent => (),
                _ => {
                    return Err(Error::new(
                        "ownership_unknown",
                        "Stop recovery retained an unverified process identity",
                    )
                    .changed())
                }
            }
        }
        self.root.write_json(
            RUNTIME,
            &Runtime {
                revision: settings.revision,
                phase: "stopped".into(),
                ..Runtime::default()
            },
        )
    }
}
