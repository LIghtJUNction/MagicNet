use super::*;
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    path::PathBuf,
};

#[derive(Default)]
struct Fake {
    alive: RefCell<BTreeMap<String, Identity>>,
    events: RefCell<Vec<String>>,
    serial: Cell<u32>,
    validate_error: Cell<bool>,
    ready_error: Cell<bool>,
    stop_error: Cell<bool>,
    unknown: Cell<bool>,
    stop_during_ready: Cell<bool>,
    fetch_count: Cell<usize>,
    fail_fetch: Cell<usize>,
    cancel_fetch: Cell<bool>,
}
impl Fake {
    fn event(&self, text: impl Into<String>) {
        self.events.borrow_mut().push(text.into());
    }
    fn identity(&self) -> Identity {
        let id = self.serial.get() + 1;
        self.serial.set(id);
        Identity {
            pid: 1000 + id,
            boot_id: "test-boot".into(),
            start_ticks: u64::from(id),
            executable_device: 1,
            executable_inode: 2,
            arguments_digest: format!("{id:064x}"),
        }
    }
}
impl Platform for Fake {
    fn validate(&self, _: &Root, _: &str) -> Result<()> {
        self.event("validate");
        if self.validate_error.get() {
            Err(Error::new("invalid_config", "injected validation failure"))
        } else {
            Ok(())
        }
    }
    fn launch(&self, _: &Root, generation: &str) -> Result<Identity> {
        self.event(format!("launch:{generation}"));
        let id = self.identity();
        self.alive
            .borrow_mut()
            .insert(generation.into(), id.clone());
        Ok(id)
    }
    fn find(&self, _: &Root, generation: &str) -> Result<Option<Identity>> {
        Ok(self.alive.borrow().get(generation).cloned())
    }
    fn observe(&self, identity: &Identity) -> Observation {
        if self.unknown.get() {
            return Observation::Unknown;
        }
        if self.alive.borrow().values().any(|v| v == identity) {
            Observation::Running
        } else {
            Observation::Absent
        }
    }
    fn ready(&self, root: &Root, _: &str, _: &Identity) -> Result<()> {
        self.event("ready");
        if self.stop_during_ready.replace(false) {
            root.write_json(STOP, &json!({"schema":1,"id":kamfw::random_id()?}))?;
        }
        if self.ready_error.replace(false) {
            Err(Error::new("startup_failed", "injected startup failure"))
        } else {
            Ok(())
        }
    }
    fn stop(&self, identity: &Identity) -> Result<()> {
        self.event(format!("stop:{}", identity.pid));
        if self.stop_error.get() {
            return Err(Error::new("stop_timeout", "injected cleanup timeout").changed());
        }
        self.alive.borrow_mut().retain(|_, id| id != identity);
        Ok(())
    }
    fn fetch(
        &self,
        root: &Root,
        _: &str,
        _: &str,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Vec<u8>> {
        let n = self.fetch_count.get() + 1;
        self.fetch_count.set(n);
        if self.cancel_fetch.get() {
            let op: Operation = root.read_json(".state/operation.json")?.unwrap();
            root.write(".state/cancel", op.id.as_bytes())?;
            assert!(cancelled());
            return Err(Error::new("cancelled", "injected cancellation"));
        }
        if n == self.fail_fetch.get() {
            return Err(Error::new(
                "subscription_fetch_failed",
                "injected network failure",
            ));
        }
        Ok(br#"{"outbounds":[{"type":"trojan","server":"example.test","server_port":443,"password":"fixture-secret"}]}"#.to_vec())
    }
    fn decode(&self, _: &Root, bytes: &[u8]) -> Result<Vec<u8>> {
        Ok(bytes.into())
    }
}
struct Fixture {
    path: PathBuf,
    engine: Engine<Fake>,
}
impl Fixture {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("magicnet-engine-{}", kamfw::random_id().unwrap()));
        std::fs::create_dir(&path).unwrap();
        Self {
            engine: Engine {
                root: Root::open(&path).unwrap(),
                platform: Fake::default(),
            },
            path,
        }
    }
    fn request(&self, method: &str, params: Value) -> Request {
        Request {
            schema: 1,
            id: kamfw::random_id().unwrap(),
            method: method.into(),
            expected_revision: Some(self.engine.settings().unwrap().revision),
            params,
        }
    }
    fn call(&self, method: &str, params: Value) -> Value {
        self.engine.handle(&self.request(method, params))
    }
    fn ok(&self, method: &str, params: Value) -> Value {
        let value = self.call(method, params);
        assert_eq!(value["ok"], true, "{value}");
        value["data"].clone()
    }
    fn bytes(&self, path: &str) -> Option<Vec<u8>> {
        self.engine
            .root
            .read(path, kamfw::fs::MAX_DOCUMENT)
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[test]
fn reads_are_write_free_even_without_runtime_directories() {
    let f = Fixture::new();
    for method in [
        "status",
        "settings",
        "capabilities",
        "diagnostics",
        "operation",
    ] {
        f.ok(method, Value::Null);
    }
    assert_eq!(std::fs::read_dir(&f.path).unwrap().count(), 0);
    assert_eq!(
        f.call("status.human-fallback", Value::Null)["error"]["code"],
        "unsupported_command"
    );
    assert_eq!(std::fs::read_dir(&f.path).unwrap().count(), 0);
}
#[test]
fn stale_revision_cannot_replace_a_newer_source_list() {
    let f = Fixture::new();
    let stale = f.request("sources.replace", json!({"text":"https://stale.test/x"}));
    f.ok("sources.replace", json!({"text":"https://current.test/x"}));
    let before = f.bytes(SETTINGS);
    assert_eq!(
        f.engine.handle(&stale)["error"]["code"],
        "revision_conflict"
    );
    assert_eq!(f.bytes(SETTINGS), before);
}
#[test]
fn request_replay_is_not_reapplied_and_id_conflicts_are_rejected() {
    let f = Fixture::new();
    let request = f.request("sources.replace", json!({"text":"https://example.test/x"}));
    let first = f.engine.handle(&request);
    assert_eq!(first["ok"], true);
    let before = f.bytes(SETTINGS);
    assert_eq!(first, f.engine.handle(&request));
    assert_eq!(before, f.bytes(SETTINGS));
    let mut conflict = request.clone();
    conflict.params = json!({"text":"https://other.test/x"});
    assert_eq!(
        f.engine.handle(&conflict)["error"]["code"],
        "request_conflict"
    );
}
#[test]
fn a_failed_source_preserves_every_cached_source_and_revision() {
    let f = Fixture::new();
    f.ok(
        "sources.replace",
        json!({"text":"https://a.test/x\nhttps://b.test/x"}),
    );
    f.ok("sources.refresh", Value::Null);
    let settings = f.engine.settings().unwrap();
    let before = f.bytes(SETTINGS);
    let caches: Vec<_> = settings
        .sources
        .iter()
        .map(|s| {
            (
                format!(".config/nodes/{}.json", s.id),
                f.bytes(&format!(".config/nodes/{}.json", s.id)),
            )
        })
        .collect();
    f.engine
        .platform
        .fail_fetch
        .set(f.engine.platform.fetch_count.get() + 2);
    assert_eq!(f.call("sources.refresh", Value::Null)["ok"], false);
    assert_eq!(before, f.bytes(SETTINGS));
    for (path, old) in caches {
        assert_eq!(old, f.bytes(&path));
    }
}
#[test]
fn deleting_all_urls_really_removes_caches_but_preserves_local_import() {
    let f = Fixture::new();
    f.ok("sources.replace", json!({"text":"https://a.test/x"}));
    f.ok("sources.refresh", Value::Null);
    f.ok("sources.import", json!({"body":r#"{"proxies":[{"type":"trojan","server":"local.test","port":443,"password":"p"}]}"#}));
    let id = f.engine.settings().unwrap().sources[0].id.clone();
    f.ok("sources.replace", json!({"text":""}));
    assert!(f.bytes(&format!(".config/nodes/{id}.json")).is_none());
    assert!(f.bytes(".config/nodes/local.json").is_some());
}
#[test]
fn cancelling_refresh_never_publishes_partial_nodes() {
    let f = Fixture::new();
    f.ok("sources.replace", json!({"text":"https://a.test/x"}));
    let old = f.bytes(SETTINGS);
    f.engine.platform.cancel_fetch.set(true);
    assert_eq!(
        f.call("sources.refresh", Value::Null)["error"]["code"],
        "cancelled"
    );
    assert_eq!(f.bytes(SETTINGS), old);
    assert!(!f.path.join(".config/nodes").exists());
}
#[test]
fn invalid_candidate_never_stops_the_working_runtime() {
    let f = Fixture::new();
    f.ok("service.start", Value::Null);
    f.ok("sources.import", json!({"body":r#"{"outbounds":[{"type":"trojan","server":"example.test","server_port":443,"password":"p"}]}"#}));
    let runtime = f.bytes(RUNTIME);
    let events = f.engine.platform.events.borrow().len();
    f.engine.platform.validate_error.set(true);
    assert_eq!(
        f.call("service.start", Value::Null)["error"]["code"],
        "invalid_config"
    );
    assert_eq!(f.bytes(RUNTIME), runtime);
    assert_eq!(&f.engine.platform.events.borrow()[events..], &["validate"]);
}
#[test]
fn failed_start_stops_candidate_and_restores_old_generation() {
    let f = Fixture::new();
    f.ok("service.start", Value::Null);
    let old: Runtime = f.engine.root.read_json(RUNTIME).unwrap().unwrap();
    let mut settings = f.engine.settings().unwrap();
    settings.user_agent = "changed".into();
    f.ok("settings.replace", serde_json::to_value(settings).unwrap());
    f.engine.platform.ready_error.set(true);
    assert_eq!(
        f.call("service.start", Value::Null)["error"]["code"],
        "startup_failed"
    );
    let restored: Runtime = f.engine.root.read_json(RUNTIME).unwrap().unwrap();
    assert_eq!(restored.generation, old.generation);
    assert_ne!(restored.identity, old.identity);
    assert_eq!(f.engine.platform.alive.borrow().len(), 1);
    assert!(f.bytes(SWITCH).is_none());
}
#[test]
fn stop_during_activation_does_not_resurrect_the_previous_generation() {
    let f = Fixture::new();
    f.ok("service.start", Value::Null);
    let mut settings = f.engine.settings().unwrap();
    settings.user_agent = "changed".into();
    f.ok("settings.replace", serde_json::to_value(settings).unwrap());
    f.engine.platform.stop_during_ready.set(true);
    assert_eq!(
        f.call("service.start", Value::Null)["error"]["code"],
        "cancelled"
    );
    assert!(f.engine.platform.alive.borrow().is_empty());
    assert!(!f.engine.settings().unwrap().enabled);
    assert_eq!(
        f.engine
            .platform
            .events
            .borrow()
            .iter()
            .filter(|e| e.starts_with("launch:"))
            .count(),
        2
    );
}
#[test]
fn stop_timeout_retains_identity_and_disabled_intent_without_forced_kill() {
    let f = Fixture::new();
    f.ok("service.start", Value::Null);
    let owner = f.engine.runtime().unwrap().identity;
    f.engine.platform.stop_error.set(true);
    assert_eq!(
        f.call("service.stop", Value::Null)["error"]["code"],
        "stop_timeout"
    );
    assert!(!f.engine.settings().unwrap().enabled);
    assert_eq!(owner, f.engine.runtime().unwrap().identity);
    assert!(f.bytes(STOP).is_some());
    assert_eq!(f.engine.platform.alive.borrow().len(), 1);
}
#[test]
fn unverified_owner_is_not_stopped_or_reported_healthy() {
    let f = Fixture::new();
    f.ok("service.start", Value::Null);
    f.engine.platform.unknown.set(true);
    assert_eq!(
        f.call("service.stop", Value::Null)["error"]["code"],
        "ownership_unknown"
    );
    assert_eq!(f.ok("status", Value::Null)["phase"], "unknown");
    assert!(!f
        .engine
        .platform
        .events
        .borrow()
        .iter()
        .any(|e| e.starts_with("stop:")));
}
#[test]
fn replaying_an_old_stop_does_not_cancel_a_subsequent_start() {
    let f = Fixture::new();
    f.ok("service.start", Value::Null);
    let stop = f.request("service.stop", Value::Null);
    assert_eq!(f.engine.handle(&stop)["ok"], true);
    f.ok("service.start", Value::Null);
    assert!(f.bytes(STOP).is_none());
    let before = f.bytes(RUNTIME);
    assert_eq!(f.engine.handle(&stop)["ok"], true);
    assert_eq!(f.bytes(RUNTIME), before);
    assert!(f.bytes(STOP).is_none());
    assert_eq!(f.engine.platform.alive.borrow().len(), 1);
}
#[test]
fn repeated_stop_has_no_additional_dataplane_or_settings_effect() {
    let f = Fixture::new();
    f.ok("service.start", Value::Null);
    f.ok("service.stop", Value::Null);
    let settings = f.bytes(SETTINGS);
    let events = f.engine.platform.events.borrow().len();
    f.ok("service.stop", Value::Null);
    assert_eq!(settings, f.bytes(SETTINGS));
    assert_eq!(events, f.engine.platform.events.borrow().len());
}
#[test]
fn recovery_discovers_child_spawned_before_pid_publication() {
    let f = Fixture::new();
    let candidate = kamfw::random_id().unwrap();
    f.engine
        .root
        .write_json(
            SWITCH,
            &Switch {
                schema: 1,
                previous: Runtime::default(),
                was_running: false,
                candidate: candidate.clone(),
            },
        )
        .unwrap();
    f.engine
        .platform
        .launch(&f.engine.root, &candidate)
        .unwrap();
    assert!(f.bytes(".state/pending-process.json").is_none());
    f.ok("runtime.recover", Value::Null);
    assert!(f.engine.platform.alive.borrow().is_empty());
    assert!(f.bytes(SWITCH).is_none());
}
#[test]
fn status_is_nonblocking_while_a_writer_owns_the_lock() {
    let f = Fixture::new();
    let guard = Guard::acquire(
        &f.engine.root,
        LOCK,
        LockMode::Exclusive,
        Duration::ZERO,
        true,
    )
    .unwrap()
    .unwrap();
    f.ok("status", Value::Null);
    assert_eq!(f.call("settings", Value::Null)["error"]["code"], "busy");
    drop(guard);
}
#[test]
fn diagnostics_do_not_expose_urls_nodes_or_credentials() {
    let f = Fixture::new();
    f.ok(
        "sources.replace",
        json!({"text":"https://a.test/private-token"}),
    );
    f.ok("sources.refresh", Value::Null);
    let output = f.ok("diagnostics", Value::Null).to_string();
    for private in [
        "https://",
        "private-token",
        "fixture-secret",
        "example.test",
    ] {
        assert!(!output.contains(private));
    }
    assert!(output.contains("not_tested"));
}
