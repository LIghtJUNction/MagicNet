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

mod bookkeeping;
mod configuration;
mod lifecycle;

const RUNTIME: &str = ".state/runtime.json";
const SWITCH: &str = ".state/switch.json";
const LOCK: &str = ".state/lock";
const STOP: &str = ".state/stop-request.json";

pub trait Platform {
    fn validate(&self, root: &Root, generation: &str) -> Result<()>;
    fn launch(&self, root: &Root, generation: &str) -> Result<Identity>;
    fn find(&self, root: &Root, generation: &str) -> Result<Option<Identity>>;
    fn observe(&self, root: &Root, identity: &Identity) -> Observation;
    fn ready(&self, root: &Root, generation: &str, identity: &Identity) -> Result<()>;
    fn stop(&self, root: &Root, identity: &Identity) -> Result<()>;
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
    #[serde(default)]
    owner: Option<Identity>,
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
                    .map(|id| self.platform.observe(&self.root, id))
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
                    "operation":self.operation_view()?.as_object().map(|o| json!({"id":o["id"],"method":o["method"],"phase":o["phase"]})),
                    "observation":"process_identity_only","network_health":"unknown"}),
                )
            }
            "operation" => self.operation_view(),
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

        let result = self.execute_locked(request, &record_path, digest);
        // Recovery and STOP can mutate intent before a new operation receipt
        // exists. Publish under the same lock even on those early error paths.
        match self.publish_canonical() {
            Ok(()) => result,
            Err(error) => Err(error.changed()),
        }
    }

    fn execute_locked(
        &self,
        request: &Request,
        record_path: &str,
        digest: String,
    ) -> Result<Value> {
        if let Some(previous) = self.root.read_json::<Operation>(record_path)? {
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
            self.settle_interrupted_operation()?;
            self.publish_canonical()?;
            return Err(Error::new("interrupted", "This request was interrupted and recovered; review state before retrying with a new ID"));
        }
        if let Err(error) = self.recover() {
            let operation = Operation {
                schema: 1,
                id: request.id.clone(),
                method: request.method.clone(),
                digest,
                phase: "failed".into(),
                owner: Some(Identity::capture(std::process::id())?),
                outcome: Some(json!({"ok":false,"error":error})),
            };
            self.root.write_json(record_path, &operation)?;
            self.root.write_json(".state/operation.json", &operation)?;
            return Err(error);
        }
        self.settle_interrupted_operation()?;
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
            owner: Some(Identity::capture(std::process::id())?),
        };
        self.root.write_json(record_path, &operation)?;
        self.root.write_json(".state/operation.json", &operation)?;
        self.publish_canonical()?;
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
            .write_json(record_path, &operation)
            .map_err(|e| e.changed())?;
        self.root
            .write_json(".state/operation.json", &operation)
            .map_err(|e| e.changed())?;
        result
    }
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
