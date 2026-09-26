//! One owner for intent, lifecycle, recovery, and the machine interface.
use crate::{
    model::{Settings, SETTINGS},
    subscription,
};
use kamfw::process::{Identity, Observation};
use kamfw::{Change, Error, Guard, LockMode, Result, Root, Store, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;

const RUNTIME: &str = ".state/runtime.json";
const SWITCH: &str = ".state/switch.json";
const LOCK: &str = ".state/lock";
const STOP: &str = ".state/stop-request.json";

pub trait Platform {
    fn validate(&self, root: &Root, generation: &str) -> Result<()>;
    fn launch(&self, root: &Root, generation: &str) -> Result<Identity>;
    fn find(&self, root: &Root, generation: &str) -> Result<Option<Identity>>;
    fn observe(&self, identity: &Identity) -> Observation;
    fn ready(&self, root: &Root, generation: &str, identity: &Identity) -> Result<()>;
    fn stop(&self, identity: &Identity) -> Result<()>;
    fn fetch(
        &self,
        root: &Root,
        url: &str,
        user_agent: &str,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Vec<u8>>;
    fn decode(&self, root: &Root, bytes: &[u8]) -> Result<Vec<u8>>;
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Runtime {
    pub generation: Option<String>,
    pub identity: Option<Identity>,
    pub revision: u64,
    pub phase: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Switch {
    schema: u32,
    previous: Runtime,
    was_running: bool,
    candidate: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub schema: u32,
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub expected_revision: Option<u64>,
    #[serde(default)]
    pub params: Value,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Operation {
    schema: u32,
    id: String,
    method: String,
    digest: String,
    phase: String,
    outcome: Option<Value>,
}

pub struct Engine<P> {
    pub root: Root,
    pub platform: P,
}
impl<P: Platform> Engine<P> {
    pub fn settings(&self) -> Result<Settings> {
        let settings: Settings = self.root.read_json(SETTINGS)?.unwrap_or_default();
        settings.validate()?;
        Ok(settings)
    }
    fn runtime(&self) -> Result<Runtime> {
        let runtime: Runtime = self.root.read_json(RUNTIME)?.unwrap_or_default();
        if runtime
            .generation
            .as_ref()
            .is_some_and(|id| !kamfw::fs::valid_id(id))
            || runtime.generation.is_some() != runtime.identity.is_some()
        {
            return Err(Error::new(
                "invalid_runtime",
                "The saved process identity is incomplete",
            ));
        }
        Ok(runtime)
    }
    fn change(&self, path: &str, value: Option<Vec<u8>>) -> Result<Change> {
        Ok(Change {
            path: path.into(),
            expected: self
                .root
                .read(path, kamfw::fs::MAX_DOCUMENT)?
                .as_ref()
                .map(|v| kamfw::sha256(v)),
            value,
        })
    }
    fn commit(&self, changes: &[Change]) -> Result<()> {
        Transaction::commit(&self.root, &kamfw::random_id()?, changes).map(|_| ())
    }
    pub fn read(&self, method: &str) -> Result<Value> {
        match method {
            "capabilities" => Ok(
                json!({"schema":1,"read":["capabilities","status","settings","operation","diagnostics"],
                "write":["settings.replace","sources.replace","sources.import","sources.refresh","service.start","service.stop","runtime.recover"],
                "transport":"stdin-json","lifecycle":"experimental","android_acceptance":"not_verified",
                "unported":["ebpf","tailscale_lifecycle","mcp","encrypted_backup","oem_network_policy","wifi","hotspot","legacy_migration"]}),
            ),
            "settings" => {
                let _guard = Guard::acquire(
                    &self.root,
                    LOCK,
                    LockMode::Shared,
                    Duration::from_millis(50),
                    false,
                )?;
                Ok(serde_json::to_value(self.settings()?)?)
            }
            "status" => {
                // Each document is atomic. Expose both revisions rather than
                // pretending that independent lock-free reads form a snapshot.
                let runtime = self.runtime()?;
                let settings = self.settings()?;
                let observed = runtime
                    .identity
                    .as_ref()
                    .map(|id| self.platform.observe(id))
                    .unwrap_or(Observation::Absent);
                let phase = match observed {
                    Observation::Running => "running",
                    Observation::Absent => "stopped",
                    Observation::Foreign => "ownership_changed",
                    Observation::Unknown => "unknown",
                };
                Ok(
                    json!({"phase":phase,"configured":settings.enabled && self.root.read(STOP, 256)?.is_none(),"configured_revision":settings.revision,
                    "effective_revision":runtime.revision,"mode":settings.mode,"source_count":settings.sources.len(),
                    "pending_changes":settings.revision != runtime.revision,"recovery_pending":self.root.read(SWITCH, 65536)?.is_some() || !self.root.list(".state/transactions", 64)?.is_empty(),
                    "operation":self.root.read_json::<Operation>(".state/operation.json")?.map(|o| json!({"id":o.id,"method":o.method,"phase":o.phase})),
                    "observation":"process_identity_only","network_health":"unknown"}),
                )
            }
            "operation" => Ok(self
                .root
                .read_json::<Operation>(".state/operation.json")?
                .map(serde_json::to_value)
                .transpose()?
                .unwrap_or(Value::Null)),
            "diagnostics" => Ok(
                json!({"schema":1,"scope":"read_only","status":self.read("status")?,
                "private_data":"omitted","android_app_connectivity":"not_tested","kernel_rules":"not_verified"}),
            ),
            _ => Err(Error::new(
                "unsupported_command",
                "This read command is not implemented; no mutating fallback was executed",
            )),
        }
    }

    pub fn handle(&self, request: &Request) -> Value {
        let result = self.execute(request);
        match result {
            Ok(data) => {
                json!({"schema":1,"ok":true,"command":request.method,"request_id":request.id,"data":data})
            }
            Err(error) => {
                json!({"schema":1,"ok":false,"command":request.method,"request_id":request.id,"error":error})
            }
        }
    }

    fn execute(&self, request: &Request) -> Result<Value> {
        if request.schema != 1 || !kamfw::fs::valid_id(&request.id) {
            return Err(Error::new(
                "invalid_request",
                "The request needs schema 1 and a 128-bit hexadecimal ID",
            ));
        }
        if [
            "capabilities",
            "status",
            "settings",
            "operation",
            "diagnostics",
        ]
        .contains(&request.method.as_str())
        {
            return self.read(&request.method);
        }
        if ![
            "settings.replace",
            "sources.replace",
            "sources.import",
            "sources.refresh",
            "service.start",
            "service.stop",
            "runtime.recover",
        ]
        .contains(&request.method.as_str())
        {
            return Err(Error::new(
                "unsupported_command",
                "The requested operation is not implemented",
            ));
        }
        let digest = kamfw::sha256(&serde_json::to_vec(request)?);
        let record_path = format!(".state/operations/{}.json", request.id);
        // A replayed stop must not cancel a later, unrelated activation.
        if let Some(previous) = self.root.read_json::<Operation>(&record_path)? {
            if previous.digest != digest {
                return Err(Error::new(
                    "request_conflict",
                    "This request ID was already used for a different operation",
                ));
            }
            if let Some(outcome) = previous.outcome {
                if outcome["ok"] == true {
                    return Ok(outcome["data"].clone());
                }
                return Err(Error::new("previous_failure", "The earlier attempt failed; inspect its recorded outcome and use a new request ID"));
            }
        }
        // Stop may cancel a long-running fetch without unlinking its live lock.
        if request.method == "service.stop" {
            self.root
                .write_json(STOP, &json!({"schema":1,"id":request.id}))?;
            if let Some(active) = self.root.read_json::<Operation>(".state/operation.json")? {
                if active.phase == "running" {
                    self.root.write(".state/cancel", active.id.as_bytes())?;
                }
            }
        }
        let guard = Guard::acquire(
            &self.root,
            LOCK,
            LockMode::Exclusive,
            Duration::from_secs(15),
            true,
        )?
        .ok_or_else(|| Error::new("lock_unavailable", "The runtime lock could not be opened"))?;
        guard.require_writer(&self.root)?;

        if let Some(previous) = self.root.read_json::<Operation>(&record_path)? {
            if previous.digest != digest {
                return Err(Error::new(
                    "request_conflict",
                    "This request ID was already used for a different operation",
                ));
            }
            if let Some(outcome) = previous.outcome {
                if outcome["ok"] == true {
                    return Ok(outcome["data"].clone());
                }
                return Err(Error::new("previous_failure", "The earlier attempt failed; inspect its recorded outcome and use a new request ID"));
            }
            self.recover()?;
            return Err(Error::new("interrupted", "This request was interrupted and recovered; review state before retrying with a new ID"));
        }
        self.recover()?;
        let mut settings = self.settings()?;
        if !matches!(request.method.as_str(), "service.stop" | "runtime.recover")
            && request.expected_revision != Some(settings.revision)
        {
            return Err(Error::new(
                "revision_conflict",
                "The settings changed after this draft was read",
            )
            .retry());
        }
        self.prune_operations()?;
        let mut operation = Operation {
            schema: 1,
            id: request.id.clone(),
            method: request.method.clone(),
            digest,
            phase: "running".into(),
            outcome: None,
        };
        self.root.write_json(&record_path, &operation)?;
        self.root.write_json(".state/operation.json", &operation)?;
        let result = self.mutate(request, &mut settings);
        operation.phase = if result.is_ok() {
            "completed"
        } else {
            "failed"
        }
        .into();
        operation.outcome = Some(match &result {
            Ok(data) => json!({"ok":true,"data":data}),
            Err(error) => json!({"ok":false,"error":error}),
        });
        self.root
            .write_json(&record_path, &operation)
            .map_err(|e| e.changed())?;
        self.root
            .write_json(".state/operation.json", &operation)
            .map_err(|e| e.changed())?;
        result
    }

    fn mutate(&self, request: &Request, settings: &mut Settings) -> Result<Value> {
        match request.method.as_str() {
            "settings.replace" => {
                let mut candidate: Settings = serde_json::from_value(request.params.clone())?;
                candidate.validate()?;
                if candidate.enabled != settings.enabled {
                    return Err(Error::new(
                        "invalid_intent",
                        "Use service.start or service.stop to change the lifecycle intent",
                    ));
                }
                candidate.revision = settings.revision + 1;
                self.commit(&[self.change(SETTINGS, Some(serde_json::to_vec(&candidate)?))?])?;
                Ok(json!({"revision":candidate.revision,"applied":false}))
            }
            "sources.replace" => {
                let text = request
                    .params
                    .get("text")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        Error::new("invalid_sources", "A complete URL list is required")
                    })?;
                let old_ids: Vec<String> = settings.sources.iter().map(|s| s.id.clone()).collect();
                settings.replace_sources(text)?;
                settings.revision += 1;
                let mut changes = vec![self.change(SETTINGS, Some(serde_json::to_vec(settings)?))?];
                for id in old_ids {
                    if !settings.sources.iter().any(|s| s.id == id) {
                        changes.push(self.change(&format!(".config/nodes/{id}.json"), None)?);
                    }
                }
                self.commit(&changes)?;
                Ok(
                    json!({"revision":settings.revision,"source_count":settings.sources.len(),"applied":false}),
                )
            }
            "sources.import" => {
                let body = request
                    .params
                    .get("body")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        Error::new(
                            "invalid_subscription",
                            "A local subscription document is required",
                        )
                    })?;
                let id = "00000000000000000000000000000001";
                let decoded = self.platform.decode(&self.root, body.as_bytes())?;
                let parsed = subscription::parse_json(&decoded, id)?;
                settings.revision += 1;
                self.commit(&[
                    self.change(
                        ".config/nodes/local.json",
                        Some(serde_json::to_vec(&parsed.nodes)?),
                    )?,
                    self.change(SETTINGS, Some(serde_json::to_vec(settings)?))?,
                ])?;
                Ok(
                    json!({"revision":settings.revision,"nodes":parsed.nodes.len(),"rejected":parsed.rejected,"applied":false}),
                )
            }
            "sources.refresh" => {
                let mut changes = Vec::new();
                let mut nodes = 0;
                let mut rejected = 0;
                let cancelled = || {
                    self.root
                        .read(".state/cancel", 64)
                        .ok()
                        .flatten()
                        .is_some_and(|id| id == request.id.as_bytes())
                };
                for source in settings.sources.iter().filter(|source| source.enabled) {
                    let bytes = self.platform.fetch(
                        &self.root,
                        &source.url,
                        &settings.user_agent,
                        &cancelled,
                    )?;
                    let decoded = self.platform.decode(&self.root, &bytes)?;
                    let parsed = subscription::parse_json(&decoded, &source.id)?;
                    nodes += parsed.nodes.len();
                    rejected += parsed.rejected;
                    changes.push(self.change(
                        &format!(".config/nodes/{}.json", source.id),
                        Some(serde_json::to_vec(&parsed.nodes)?),
                    )?);
                }
                if changes.is_empty() {
                    return Err(Error::new(
                        "no_sources",
                        "No enabled subscription sources are configured",
                    ));
                }
                settings.revision += 1;
                changes.push(self.change(SETTINGS, Some(serde_json::to_vec(settings)?))?);
                self.commit(&changes)?;
                Ok(
                    json!({"revision":settings.revision,"nodes":nodes,"rejected":rejected,"applied":false}),
                )
            }
            "service.start" => {
                // A new explicit start can clear a settled stop, never an
                // in-flight operation's cancellation marker.
                self.root.remove(STOP)?;
                self.activate(settings)
            }
            "service.stop" => {
                self.settle_stop()?;
                Ok(
                    json!({"phase":"stopped","revision":self.settings()?.revision,"network_restoration":"not_verified"}),
                )
            }
            "runtime.recover" => {
                self.recover()?;
                self.read("status")
            }
            _ => Err(Error::new("unsupported_command", "Unknown operation")),
        }
    }

    fn activate(&self, settings: &mut Settings) -> Result<Value> {
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
            .map(|id| self.platform.observe(id))
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
                self.platform
                    .stop(switch.previous.identity.as_ref().ok_or_else(|| {
                        Error::new("invalid_runtime", "An active runtime has no owner")
                    })?)?;
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
    fn recover(&self) -> Result<()> {
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
            self.platform.stop(&identity)?;
        }
        let mut restored = switch.previous.clone();
        if switch.was_running && !stopping {
            let identity = restored
                .identity
                .as_ref()
                .ok_or_else(|| Error::new("invalid_recovery", "The rollback owner is missing"))?;
            match self.platform.observe(identity) {
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

    fn settle_stop(&self) -> Result<()> {
        let runtime = self.runtime()?;
        let mut settings = self.settings()?;
        if settings.enabled {
            settings.enabled = false;
            settings.revision += 1;
            self.commit(&[self.change(SETTINGS, Some(serde_json::to_vec(&settings)?))?])?;
        }
        if let Some(identity) = runtime.identity.as_ref() {
            match self.platform.observe(identity) {
                Observation::Running => self.platform.stop(identity)?,
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

    fn prune_operations(&self) -> Result<()> {
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

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
