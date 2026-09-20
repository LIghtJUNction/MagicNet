//! Persistent JSON Merge Patch intent and reversible runtime materialization.
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use crate::{replace_module_text_files_transactionally, run_bounded_command, App};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub(crate) const INTENT: &str = ".config/magicnet/config-override.json";
pub(crate) const ACTIVE_INTENT: &str = ".config/magicnet/config-override-active.json";
const CHECKPOINT: &str = ".state/override-materialization/checkpoint.json";
const CONFIG: &str = ".config/sing-box/config.json";
const LIMIT: u64 = 4 * 1024 * 1024;

type Result<T> = std::result::Result<T, &'static str>;

fn patch_hash(patch: &Value) -> String {
    format!("{:x}", Sha256::digest(patch.to_string().as_bytes()))
}

fn activation_blocked(checkpoint: &Value, desired: &Value) -> bool {
    checkpoint["failed_revision"] == desired["revision"]
        && checkpoint["failed_patch_hash"] == patch_hash(&desired["patch"])
}

struct Lock(File);
impl Drop for Lock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
fn lock(app: &App) -> Result<Lock> {
    fs::create_dir_all(app.moddir.join(".state")).map_err(|_| "override.io")?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(app.moddir.join(".state/override.lock"))
        .map_err(|_| "override.io")?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("override.busy");
    }
    Ok(Lock(file))
}

fn read(app: &App, path: &str) -> Result<Option<Value>> {
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(app.moddir.join(path))
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("override.io"),
    };
    if !file.metadata().map_err(|_| "override.io")?.is_file() {
        return Err("override.io");
    }
    let mut bytes = Vec::new();
    let limit = if path == CHECKPOINT { LIMIT * 3 } else { LIMIT };
    (&mut file)
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "override.io")?;
    if bytes.len() as u64 > limit {
        return Err("override.too_large");
    }
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| "override.invalid_json")
}

fn checked_intent(value: Option<Value>) -> Result<Value> {
    let value = value.unwrap_or_else(|| json!({"schema":1,"revision":0,"patch":{}}));
    if value["schema"] != 1 || value["revision"].as_u64().is_none() || !value["patch"].is_object() {
        return Err("override.invalid_state");
    }
    Ok(value)
}
fn intent(app: &App) -> Result<Value> {
    checked_intent(read(app, INTENT)?.or(read(app, ACTIVE_INTENT)?))
}
fn active_intent(app: &App) -> Result<Value> {
    checked_intent(read(app, ACTIVE_INTENT)?)
}

pub(crate) fn status(app: &App) -> Result<Value> {
    let desired = intent(app)?;
    let active = active_intent(app)?;
    let checkpoint = read(app, CHECKPOINT)?;
    let config = read(app, CONFIG)?;
    let materialized = checkpoint.as_ref().is_some_and(|saved| {
        saved.get("effective") == config.as_ref()
            && saved["revision"] == desired["revision"]
            && saved["patch_hash"] == patch_hash(&desired["patch"])
    });
    let empty = desired["patch"]
        .as_object()
        .is_some_and(|patch| patch.is_empty());
    Ok(json!({
        "configured_revision":desired["revision"],
        "active_revision":active["revision"],
        "materialized_revision":checkpoint.as_ref().and_then(|v| v["revision"].as_u64()),
        "configured":!empty, "materialized":materialized,
        "pending":!materialized && (!empty || checkpoint.is_some()),
        "activation_blocked":checkpoint.as_ref().is_some_and(|v| activation_blocked(v, &desired)),
        "running_revision":null
    }))
}

pub(crate) fn inspect(app: &App) -> Result<Value> {
    let before = intent(app)?;
    let mut data = status(app)?;
    if before != intent(app)? || before["revision"] != data["configured_revision"] {
        return Err("override.busy");
    }
    data["patch"] = before["patch"].clone();
    Ok(data)
}

pub(crate) fn merge(base: &mut Value, patch: &Value) {
    if let Some(patch) = patch.as_object() {
        if !base.is_object() {
            *base = json!({});
        }
        if let Some(base) = base.as_object_mut() {
            for (key, value) in patch {
                if value.is_null() {
                    base.remove(key);
                } else {
                    merge(base.entry(key).or_insert(Value::Null), value);
                }
            }
        }
    } else {
        *base = patch.clone();
    }
}

// Undo only values still matching our own last materialization. A new value
// from a subscription or another policy writer belongs to that writer.
fn remove_previous(
    current: Option<&Value>,
    base: Option<&Value>,
    applied: Option<&Value>,
) -> Option<Value> {
    if base == applied {
        return current.cloned();
    }
    if current == applied {
        return base.cloned();
    }
    if let (Some(current), Some(applied)) = (
        current.and_then(Value::as_object),
        applied.and_then(Value::as_object),
    ) {
        if base.is_none() || base.is_some_and(Value::is_object) {
            let empty = serde_json::Map::new();
            let original = base.and_then(Value::as_object).unwrap_or(&empty);
            let mut result = current.clone();
            for key in original.keys().chain(applied.keys()) {
                match remove_previous(current.get(key), original.get(key), applied.get(key)) {
                    Some(value) => {
                        result.insert(key.clone(), value);
                    }
                    None => {
                        result.remove(key);
                    }
                }
            }
            return if base.is_none() && result.is_empty() {
                None
            } else {
                Some(Value::Object(result))
            };
        }
    }
    current.cloned()
}

fn candidate(app: &App, patch: &Value) -> Result<(Value, Value)> {
    if !patch.is_object() {
        return Err("override.invalid_patch");
    }
    let current = read(app, CONFIG)?.ok_or("override.config_missing")?;
    if !current.is_object() {
        return Err("override.invalid_state");
    }
    let checkpoint = read(app, CHECKPOINT)?;
    let base = match checkpoint {
        Some(saved)
            if saved["schema"] == 1
                && saved["base"].is_object()
                && saved["effective"].is_object() =>
        {
            remove_previous(Some(&current), saved.get("base"), saved.get("effective"))
                .ok_or("override.invalid_state")?
        }
        Some(_) => return Err("override.invalid_state"),
        None => current,
    };
    let mut effective = base.clone();
    merge(&mut effective, patch);
    // The managed response pipeline follows the user's final resolver too.
    if let Some(final_server) = effective
        .pointer("/dns/final")
        .and_then(Value::as_str)
        .map(str::to_owned)
    {
        if let Some(rules) = effective
            .pointer_mut("/dns/rules")
            .and_then(Value::as_array_mut)
        {
            for rule in rules {
                if rule["action"] == "evaluate" && rule["tag"] == "magicnet-final-dns" {
                    rule["server"] = Value::String(final_server.clone());
                }
            }
        }
    }
    protect_managed(&base, &effective)?;
    if effective.to_string().len() as u64 > LIMIT {
        return Err("override.too_large");
    }
    Ok((base, effective))
}

fn protect_managed(base: &Value, effective: &Value) -> Result<()> {
    // Preserve the entire managed capture/listener boundary, including root UID
    // exclusions, DNS listeners and loopback addresses, not only its mode label.
    for path in [
        "/inbounds",
        "/experimental/clash_api",
        "/experimental/cache_file",
    ] {
        if base.pointer(path) != effective.pointer(path) {
            return Err("override.protected_field");
        }
    }
    // The hotspot watcher owns this selector and its discovered source rule.
    // Overriding them would make the watcher continuously undo/reapply intent.
    let hotspot_selector = |config: &Value| {
        config["outbounds"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter(|item| item["tag"] == "hotspot")
                    .cloned()
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };
    let hotspot_rules = |config: &Value| {
        config
            .pointer("/route/rules")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter(|item| {
                        item["outbound"] == "hotspot"
                            && item["inbound"] == json!(["tun-in"])
                            && item["source_ip_cidr"].is_array()
                            && item.as_object().is_some_and(|object| object.len() == 3)
                    })
                    .cloned()
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };
    if hotspot_selector(base) != hotspot_selector(effective)
        || hotspot_rules(base) != hotspot_rules(effective)
    {
        return Err("override.protected_field");
    }
    Ok(())
}

fn validate(app: &App, config: &Value) -> Result<()> {
    crate::config_editor::validate_override_text(app, &config.to_string())
        .map_err(|_| "override.validation_failed")
}

pub(crate) fn preview(app: &App, request: &Value) -> Result<Value> {
    let _guard = lock(app)?;
    let desired = intent(app)?;
    let patch = request.get("patch").ok_or("override.invalid_request")?;
    let (base, effective) = candidate(app, patch)?;
    validate(app, &effective)?;
    let changed_sections = base
        .as_object()
        .into_iter()
        .flat_map(|o| o.keys())
        .chain(effective.as_object().into_iter().flat_map(|o| o.keys()))
        .filter(|key| base.get(*key) != effective.get(*key))
        .collect::<std::collections::BTreeSet<_>>();
    Ok(
        json!({"valid":true,"configured_revision":desired["revision"],"changed_section_count":changed_sections.len()}),
    )
}

pub(crate) fn save(app: &App, request: &Value, reset: bool) -> Result<Value> {
    let _lifecycle = crate::service::config_apply_lock(app).map_err(|_| "override.busy")?;
    let _guard = lock(app)?;
    let old = intent(app)?;
    let revision = old["revision"].as_u64().ok_or("override.invalid_state")?;
    let expected = request["expected_revision"]
        .as_u64()
        .ok_or("override.invalid_request")?;
    let patch = if reset {
        json!({})
    } else {
        request
            .get("patch")
            .cloned()
            .ok_or("override.invalid_request")?
    };
    if !patch.is_object() {
        return Err("override.invalid_patch");
    }
    if old["patch"] == patch {
        return status(app);
    }
    if expected != revision {
        return Err("override.conflict");
    }
    let (_, effective) = candidate(app, &patch)?;
    validate(app, &effective)?;
    let next = json!({"schema":1,"revision":revision.checked_add(1).ok_or("override.invalid_state")?,"patch":patch});
    replace_module_text_files_transactionally(app, &[(Path::new(INTENT), &next.to_string())])
        .map_err(|_| "override.persist_failed")?;
    status(app)
}

// Called under the existing shell config lock, after runtime policy writers and
// before core launch. Never invokes another lifecycle command from inside it.
pub(crate) fn materialize(app: &App) -> Result<()> {
    if !app.moddir.join(ACTIVE_INTENT).exists() && !app.moddir.join(CHECKPOINT).exists() {
        return Ok(());
    }
    let _guard = lock(app)?;
    let desired = active_intent(app)?;
    if read(app, CHECKPOINT)?.is_some_and(|saved| activation_blocked(&saved, &desired)) {
        return Ok(());
    }
    if let Some(saved) = read(app, CHECKPOINT)? {
        if saved["revision"] == desired["revision"]
            && saved["patch_hash"] == patch_hash(&desired["patch"])
            && read(app, CONFIG)?.as_ref() == saved.get("effective")
        {
            return Ok(());
        }
    }
    let (base, effective) = candidate(app, &desired["patch"])?;
    validate(app, &effective)?;
    let checkpoint = json!({"schema":1,"revision":desired["revision"],"patch_hash":patch_hash(&desired["patch"]),"base":base,"effective":effective});
    replace_module_text_files_transactionally(
        app,
        &[
            (Path::new(CONFIG), &effective.to_string()),
            (Path::new(CHECKPOINT), &checkpoint.to_string()),
        ],
    )
    .map_err(|_| "override.persist_failed")
}

pub(crate) fn read_request(app: &App, path: &Path) -> Result<Value> {
    let bytes = crate::config_editor::read_private_payload(app, path, LIMIT)
        .map_err(|_| "override.invalid_payload")?;
    serde_json::from_slice(&bytes).map_err(|_| "override.invalid_json")
}

fn activate_intent(app: &App, expected_revision: Option<u64>) -> Result<Value> {
    let _lifecycle = crate::service::config_apply_lock(app).map_err(|_| "override.busy")?;
    let _guard = lock(app)?;
    let desired = intent(app)?;
    if expected_revision.is_some_and(|revision| desired["revision"].as_u64() != Some(revision)) {
        return Err("override.conflict");
    }
    let mut replacements = vec![(std::path::PathBuf::from(ACTIVE_INTENT), desired.to_string())];
    if let Some(mut checkpoint) = read(app, CHECKPOINT)? {
        if let Some(object) = checkpoint.as_object_mut() {
            object.remove("failed_revision");
            object.remove("failed_patch_hash");
        }
        replacements.push((std::path::PathBuf::from(CHECKPOINT), checkpoint.to_string()));
    }
    let refs = replacements
        .iter()
        .map(|(path, text)| (path.as_path(), text.as_str()))
        .collect::<Vec<_>>();
    replace_module_text_files_transactionally(app, &refs).map_err(|_| "override.persist_failed")?;
    Ok(desired)
}

pub(crate) fn apply(app: &App, expected_revision: Option<u64>) -> Result<Value> {
    let activated = activate_intent(app, expected_revision)?;
    // Lifecycle admission/rollback is owned by the common service controller.
    let mut command = Command::new(app.moddir.join("bin/magicnet-cli"));
    command.args(["config", "apply"]).env("MODDIR", &app.moddir);
    let output = run_bounded_command(command, Duration::from_secs(180), 256 * 1024)
        .map_err(|_| "override.apply_failed")?;
    if output.timed_out || !output.status.is_some_and(|status| status.success()) {
        return Err("override.apply_failed");
    }
    let mut data = status(app)?;
    let checkpoint = read(app, CHECKPOINT)?.ok_or("override.apply_failed")?;
    if checkpoint["revision"] != activated["revision"]
        || checkpoint["patch_hash"] != patch_hash(&activated["patch"])
        || checkpoint.get("effective") != read(app, CONFIG)?.as_ref()
        || activation_blocked(&checkpoint, &activated)
    {
        return Err("override.apply_failed");
    }
    data["service_running"] = match crate::owned_singbox_pids(app) {
        Ok(pids) => Value::Bool(!pids.is_empty()),
        Err(_) => Value::Null,
    };
    Ok(data)
}

pub(crate) struct RuntimeSnapshot {
    pub(crate) was_running: bool,
    config: Value,
    checkpoint: Value,
    revision: Value,
    patch_hash: String,
}

pub(crate) fn runtime_snapshot(app: &App) -> Result<Option<RuntimeSnapshot>> {
    if !app.moddir.join(ACTIVE_INTENT).exists() {
        return Ok(None);
    }
    if app
        .moddir
        .join(".state/sing-box/subscription-update.lock")
        .exists()
    {
        return Err("override.busy");
    }
    let _guard = lock(app)?;
    let config = read(app, CONFIG)?.ok_or("override.config_missing")?;
    let checkpoint = read(app, CHECKPOINT)?.unwrap_or_else(|| {
        json!({
            "schema":1,"revision":0,"base":config,"effective":config
        })
    });
    let desired = active_intent(app)?;
    Ok(Some(RuntimeSnapshot {
        was_running: !crate::owned_singbox_pids(app)
            .map_err(|_| "override.observation_failed")?
            .is_empty(),
        config,
        checkpoint,
        revision: desired["revision"].clone(),
        patch_hash: patch_hash(&desired["patch"]),
    }))
}

pub(crate) fn owns_runtime_change(app: &App, snapshot: &RuntimeSnapshot) -> Result<bool> {
    let current = read(app, CONFIG)?.ok_or("override.config_missing")?;
    if current == snapshot.config {
        return Ok(false);
    }
    if app
        .moddir
        .join(".state/sing-box/subscription-update.lock")
        .exists()
    {
        return Err("override.rollback_conflict");
    }
    let checkpoint = read(app, CHECKPOINT)?.ok_or("override.rollback_conflict")?;
    if checkpoint["effective"] != current
        || checkpoint["revision"] != snapshot.revision
        || checkpoint["patch_hash"] != snapshot.patch_hash
    {
        return Err("override.rollback_conflict");
    }
    Ok(true)
}

pub(crate) fn restore_runtime(app: &App, snapshot: RuntimeSnapshot) -> Result<()> {
    let _guard = lock(app)?;
    let mut checkpoint = snapshot.checkpoint;
    checkpoint["failed_revision"] = snapshot.revision;
    checkpoint["failed_patch_hash"] = Value::String(snapshot.patch_hash);
    replace_module_text_files_transactionally(
        app,
        &[
            (Path::new(CONFIG), &snapshot.config.to_string()),
            (Path::new(CHECKPOINT), &checkpoint.to_string()),
        ],
    )
    .map_err(|_| "override.rollback_failed")
}

pub(crate) fn message(code: &str) -> &'static str {
    match code {
        "override.conflict" => "configuration changed; reload before saving",
        "override.busy" => "another override operation is running; retry later",
        "override.protected_field" => {
            "managed inbounds, hotspot policy and local management settings cannot be overridden"
        }
        "override.validation_failed" => "merged configuration failed sing-box validation",
        "override.apply_failed" => {
            "runtime activation failed; inspect service health before retrying"
        }
        "override.config_missing" => "import a valid base configuration first",
        _ => "override operation failed; check the request and local configuration",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_saved_draft_does_not_activate_when_the_file_watcher_runs() {
        let app = fixture();
        save(
            &app,
            &json!({"expected_revision":0,"patch":{"log":{"level":"info"}}}),
            false,
        )
        .unwrap();
        materialize(&app).unwrap();
        assert_eq!(
            read(&app, CONFIG).unwrap().unwrap()["log"]["level"],
            "error"
        );
        assert_eq!(activate_intent(&app, Some(0)), Err("override.conflict"));
        activate_intent(&app, Some(1)).unwrap();
        materialize(&app).unwrap();
        save(
            &app,
            &json!({"expected_revision":1,"patch":{"log":{"level":"debug"}}}),
            false,
        )
        .unwrap();
        materialize(&app).unwrap();
        assert_eq!(read(&app, CONFIG).unwrap().unwrap()["log"]["level"], "info");
        assert_eq!(status(&app).unwrap()["pending"], true);
        fs::remove_dir_all(app.moddir).unwrap();
    }

    #[test]
    fn restoring_different_intent_at_the_same_revision_is_not_marked_applied() {
        let app = fixture();
        save(
            &app,
            &json!({"expected_revision":0,"patch":{"log":{"level":"info"}}}),
            false,
        )
        .unwrap();
        activate_intent(&app, None).unwrap();
        materialize(&app).unwrap();
        fs::write(
            app.moddir.join(INTENT),
            json!({"schema":1,"revision":1,"patch":{"log":{"level":"warn"}}}).to_string(),
        )
        .unwrap();
        assert_eq!(status(&app).unwrap()["pending"], true);
        activate_intent(&app, None).unwrap();
        materialize(&app).unwrap();
        assert_eq!(read(&app, CONFIG).unwrap().unwrap()["log"]["level"], "warn");
        fs::remove_dir_all(app.moddir).unwrap();
    }

    #[test]
    fn reset_of_an_added_object_keeps_another_writers_new_child() {
        let base = json!({});
        let applied = json!({"dns":{"cache_capacity":8192}});
        let current = json!({"dns":{"cache_capacity":8192,"timeout":"6s"}});
        assert_eq!(
            remove_previous(Some(&current), Some(&base), Some(&applied)),
            Some(json!({"dns":{"timeout":"6s"}}))
        );
    }
    fn fixture() -> App {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!(
            "magicnet-override-{}-{}",
            std::process::id(),
            std::time::UNIX_EPOCH.elapsed().unwrap().as_nanos()
        ));
        fs::create_dir_all(root.join(".config/sing-box")).unwrap();
        fs::create_dir_all(root.join("bin")).unwrap();
        fs::write(root.join(CONFIG), json!({"log":{"level":"error"},"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[]}).to_string()).unwrap();
        fs::write(root.join("bin/sing-box"), "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(root.join("bin/sing-box"), fs::Permissions::from_mode(0o700)).unwrap();
        App::for_test(root)
    }
    #[test]
    fn save_materialize_and_reset_preserve_the_base() {
        let app = fixture();
        let original = read(&app, CONFIG).unwrap().unwrap();
        let first = save(
            &app,
            &json!({"expected_revision":0,"patch":{"log":{"level":"info"}}}),
            false,
        )
        .unwrap();
        assert_eq!(first["configured_revision"], 1);
        assert_eq!(read(&app, CONFIG).unwrap().unwrap(), original);
        activate_intent(&app, None).unwrap();
        materialize(&app).unwrap();
        assert_eq!(read(&app, CONFIG).unwrap().unwrap()["log"]["level"], "info");
        assert_eq!(status(&app).unwrap()["pending"], false);
        let same = save(
            &app,
            &json!({"expected_revision":0,"patch":{"log":{"level":"info"}}}),
            false,
        )
        .unwrap();
        assert_eq!(same["configured_revision"], 1);
        assert_eq!(
            save(
                &app,
                &json!({"expected_revision":0,"patch":{"log":{"level":"debug"}}}),
                false
            ),
            Err("override.conflict")
        );
        save(&app, &json!({"expected_revision":1}), true).unwrap();
        activate_intent(&app, None).unwrap();
        materialize(&app).unwrap();
        assert_eq!(read(&app, CONFIG).unwrap().unwrap(), original);
        fs::remove_dir_all(app.moddir).unwrap();
    }
    #[test]
    fn invalid_patch_and_validator_failure_publish_nothing() {
        let app = fixture();
        let before = fs::read(app.moddir.join(CONFIG)).unwrap();
        assert_eq!(
            save(
                &app,
                &json!({"expected_revision":0,"patch":{"inbounds":null}}),
                false
            ),
            Err("override.protected_field")
        );
        fs::write(
            app.moddir.join("bin/sing-box"),
            "#!/bin/sh\necho private-secret >&2\nexit 1\n",
        )
        .unwrap();
        assert_eq!(
            save(
                &app,
                &json!({"expected_revision":0,"patch":{"log":{"level":"invalid"}}}),
                false
            ),
            Err("override.validation_failed")
        );
        assert!(!app.moddir.join(INTENT).exists());
        assert_eq!(fs::read(app.moddir.join(CONFIG)).unwrap(), before);
        fs::remove_dir_all(app.moddir).unwrap();
    }
    #[test]
    fn failed_activation_restores_runtime_and_holds_background_retry() {
        let app = fixture();
        save(
            &app,
            &json!({"expected_revision":0,"patch":{"log":{"level":"info"}}}),
            false,
        )
        .unwrap();
        activate_intent(&app, None).unwrap();
        let snapshot = runtime_snapshot(&app).unwrap().unwrap();
        activate_intent(&app, None).unwrap();
        materialize(&app).unwrap();
        restore_runtime(&app, snapshot).unwrap();
        assert_eq!(status(&app).unwrap()["activation_blocked"], true);
        materialize(&app).unwrap();
        assert_eq!(
            read(&app, CONFIG).unwrap().unwrap()["log"]["level"],
            "error"
        );
        assert_eq!(status(&app).unwrap()["pending"], true);
        fs::remove_dir_all(app.moddir).unwrap();
    }
    #[test]
    fn inspections_do_not_create_observation_or_lock_files() {
        let app = fixture();
        inspect(&app).unwrap();
        assert!(!app.moddir.join(".state").exists());
        fs::remove_dir_all(app.moddir).unwrap();
    }
    #[test]
    fn merge_patch_replaces_arrays_deletes_null_and_preserves_siblings() {
        let mut base =
            json!({"log":{"level":"error","timestamp":true},"route":{"rules":[1]},"old":true});
        merge(
            &mut base,
            &json!({"log":{"level":"info"},"route":{"rules":[2]},"old":null}),
        );
        assert_eq!(
            base,
            json!({"log":{"level":"info","timestamp":true},"route":{"rules":[2]}})
        );
    }
    #[test]
    fn reset_preserves_fresh_subscription_values() {
        let base = json!({"log":{"level":"error"},"outbounds":["old"],"route":{"final":"proxy"}});
        let mut applied = base.clone();
        merge(
            &mut applied,
            &json!({"log":{"level":"info"},"route":{"final":"direct"}}),
        );
        let mut current = applied.clone();
        current["outbounds"] = json!(["new"]);
        let restored = remove_previous(Some(&current), Some(&base), Some(&applied)).unwrap();
        assert_eq!(
            restored,
            json!({"log":{"level":"error"},"outbounds":["new"],"route":{"final":"proxy"}})
        );
    }
    #[test]
    fn reset_removes_added_keys_and_restores_deleted_keys() {
        let base = json!({"log":{"level":"error","timestamp":true}});
        let mut applied = base.clone();
        merge(
            &mut applied,
            &json!({"log":{"timestamp":null,"disabled":true}}),
        );
        assert_eq!(
            remove_previous(Some(&applied), Some(&base), Some(&applied)),
            Some(base)
        );
    }
    #[test]
    fn managed_boundary_cannot_be_removed_or_changed() {
        let base = json!({"inbounds":[{"type":"tun","interface_name":"magicnet0"}],"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}},"outbounds":[{"tag":"hotspot","type":"selector","default":"direct"}],"route":{"rules":[{"inbound":["tun-in"],"source_ip_cidr":["192.0.2.0/24"],"outbound":"hotspot"}]}});
        for patch in [
            json!({"inbounds":[]}),
            json!({"experimental":null}),
            json!({"outbounds":[]}),
            json!({"route":{"rules":[]}}),
        ] {
            let mut effective = base.clone();
            merge(&mut effective, &patch);
            assert_eq!(
                protect_managed(&base, &effective),
                Err("override.protected_field")
            );
        }
    }
}
