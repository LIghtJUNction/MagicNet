//! Explicit machine mutation: official module releases, detached device worker.
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::ToSocketAddrs;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::{run_bounded_command, App};

mod archive;

const INTENT: &str = ".config/magicnet/module-update.conf";
const RECEIPTS: &str = ".state/module-update/receipts.json";
const METADATA: &str = ".state/module-update/release.json";
const LOCK: &str = ".state/module-update/lock";
const API: &str = "https://api.github.com/repos/LIghtJUNction/MagicNet/releases/latest";
const ASSET_API: &str = "https://api.github.com/repos/LIghtJUNction/MagicNet/releases/assets/";
const REPO: &str = "https://github.com/LIghtJUNction/MagicNet/releases/download/";
const MAX_CORE: usize = 12 * 1024 * 1024;
const CHILD_FD: i32 = 198;
type Result<T> = std::result::Result<T, &'static str>;

#[derive(Clone, Debug, PartialEq)]
struct Version {
    version: String,
    code: u64,
}

fn version_tuple(value: &str) -> Option<(u32, u32, u32)> {
    if value.len() > 40 {
        return None;
    }
    let mut parts = value.strip_prefix('v')?.split('.');
    let mut next = || {
        let token = parts.next()?;
        if token.is_empty()
            || !token.bytes().all(|b| b.is_ascii_digit())
            || (token.len() > 1 && token.starts_with('0'))
        {
            return None;
        }
        token.parse::<u32>().ok()
    };
    let out = (next()?, next()?, next()?);
    if parts.next().is_some() {
        None
    } else {
        Some(out)
    }
}

fn safe_id(value: &str) -> bool {
    (8..=64).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}

fn bounded_text(path: &Path, limit: u64) -> Option<String> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > limit {
        return None;
    }
    let mut text = String::new();
    file.take(limit + 1).read_to_string(&mut text).ok()?;
    (text.len() as u64 <= limit).then_some(text)
}

fn tokens(path: &Path) -> BTreeMap<String, String> {
    bounded_text(path, 8192)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            if key.is_empty()
                || value.is_empty()
                || value.len() > 128
                || !key.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
                || !value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
            {
                return None;
            }
            Some((key.into(), value.into()))
        })
        .collect()
}

// module.prop contains a camel-case key; parse it separately as bounded data.
fn module_version(path: &Path) -> Option<Version> {
    let text = bounded_text(path, 4096)?;
    let mut values = BTreeMap::new();
    for line in text.lines() {
        if let Some((key, value)) = line.split_once('=') {
            if matches!(key, "id" | "version" | "versionCode")
                && values.insert(key, value).is_some()
            {
                return None;
            }
        }
    }
    if values.get("id")? != &"MagicNet" {
        return None;
    }
    let version = values.get("version")?.to_string();
    version_tuple(&version)?;
    let code = values.get("versionCode")?.parse::<u64>().ok()?;
    (code > 0).then_some(Version { version, code })
}

fn active_version(app: &App) -> Option<Version> {
    let version = module_version(&app.moddir.join("module.prop"))?;
    let manifest =
        crate::utils::read_json_file_bounded(&app.moddir.join("components.json"), 128 * 1024)?;
    if manifest["schema"] != 1
        || manifest["module"] != "MagicNet"
        || manifest["version"] != version.version
    {
        return None;
    }
    let mut matches = manifest["components"]
        .as_array()?
        .iter()
        .filter(|component| component["id"] == "bin-magicnet-cli")
        .flat_map(|component| component["files"].as_array().into_iter().flatten())
        .filter(|file| file["path"] == "bin/magicnet-cli");
    let descriptor = matches.next()?;
    if matches.next().is_some() {
        return None;
    }
    let expected = descriptor["sha256"].as_str()?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(app.moddir.join("bin/magicnet-cli"))
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file()
        || metadata.len() > 64 * 1024 * 1024
        || descriptor["size"].as_u64() != Some(metadata.len())
    {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(64 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    (sha(&bytes) == expected).then_some(version)
}

fn boot_id() -> String {
    bounded_text(Path::new("/proc/sys/kernel/random/boot_id"), 128)
        .map(|s| s.trim().to_owned())
        .filter(|s| safe_id(s))
        .unwrap_or_else(|| "unknown".into())
}

fn different_boot(previous: &str, current: &str) -> bool {
    previous != "unknown" && current != "unknown" && previous != current
}

fn pending(app: &App) -> PathBuf {
    app.moddir
        .parent()
        .and_then(Path::parent)
        .unwrap_or(Path::new("/data/adb"))
        .join("modules_update/MagicNet")
}
fn exists(path: &Path) -> bool {
    path_present(path).unwrap_or(true)
}
fn path_present(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("module-update.io"),
    }
}
fn staging_present(app: &App) -> Result<bool> {
    let stage = path_present(&pending(app))?;
    let update = path_present(&app.moddir.join("update"))?;
    Ok(stage || update)
}
fn marked(app: &App, name: &str) -> bool {
    exists(&app.moddir.join(name))
}

fn private_dir(app: &App) -> Result<PathBuf> {
    let mut path = app.moddir.clone();
    for component in [".state", "module-update"] {
        path.push(component);
        match fs::symlink_metadata(&path) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => {}
            Ok(_) => return Err("module-update.io"),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&path).map_err(|_| "module-update.io")?;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                    .map_err(|_| "module-update.io")?;
            }
            Err(_) => return Err("module-update.io"),
        }
    }
    Ok(path)
}

fn cleanup_downloads(app: &App) -> Result<()> {
    let directory = private_dir(app)?;
    for name in ["headers", "package.zip"] {
        let path = directory.join(name);
        match fs::symlink_metadata(&path) {
            Ok(meta) if meta.is_file() && !meta.file_type().is_symlink() => {
                fs::remove_file(&path).map_err(|_| "module-update.io")?;
            }
            Ok(_) => return Err("module-update.io"),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("module-update.io"),
        }
    }
    Ok(())
}

fn lock(app: &App) -> Result<File> {
    private_dir(app)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(app.moddir.join(LOCK))
        .map_err(|_| "module-update.io")?;
    if !file.metadata().map_err(|_| "module-update.io")?.is_file() {
        return Err("module-update.io");
    }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("module-update.busy");
    }
    Ok(file)
}

fn lock_busy(app: &App) -> Result<bool> {
    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(app.moddir.join(LOCK))
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err("module-update.io"),
    };
    if !file.metadata().map_err(|_| "module-update.io")?.is_file() {
        return Err("module-update.io");
    }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(false);
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
        Ok(true)
    } else {
        Err("module-update.io")
    }
}

fn canonical(app: &App) -> BTreeMap<String, String> {
    tokens(&app.moddir.join(crate::state::module_update_path()))
}
fn put(record: &mut BTreeMap<String, String>, key: &str, value: impl ToString) {
    record.insert(key.into(), value.to_string());
}
fn publish(app: &App, record: &BTreeMap<String, String>) -> Result<()> {
    let text = record
        .iter()
        .map(|(k, v)| format!("{k}={v}\n"))
        .collect::<String>();
    crate::write_text_file(app, &crate::state::module_update_path(), &text)
        .map_err(|_| "module-update.io")
}
fn phase(app: &App, record: &mut BTreeMap<String, String>, value: &str) -> Result<()> {
    put(record, "phase", value);
    put(record, "error_code", "none");
    publish(app, record)
}
fn record_version(record: &BTreeMap<String, String>, prefix: &str) -> Option<Version> {
    let version = record.get(&format!("{prefix}_version"))?.clone();
    version_tuple(&version)?;
    let code = record.get(&format!("{prefix}_code"))?.parse::<u64>().ok()?;
    (code > 0).then_some(Version { version, code })
}
fn store_version(record: &mut BTreeMap<String, String>, prefix: &str, value: &Version) {
    put(record, &format!("{prefix}_version"), &value.version);
    put(record, &format!("{prefix}_code"), value.code);
}
fn busy_phase(value: &str) -> bool {
    matches!(
        value,
        "checking" | "downloading" | "verifying" | "installing"
    )
}

pub(crate) fn status(app: &App) -> Value {
    let mut record = canonical(app);
    let current = active_version(app);
    let stage_evidence = staging_present(app);
    let staged = stage_evidence.unwrap_or(true);
    let recorded_phase = record
        .get("phase")
        .map(String::as_str)
        .unwrap_or("idle")
        .to_owned();
    let recorded_boot = record
        .get("boot_id")
        .map(String::as_str)
        .unwrap_or("unknown");
    let after_boot = different_boot(recorded_boot, &boot_id());
    let baseline = record_version(&record, "installed");
    let latest = record_version(&record, "latest");
    let effective = if staged
        || recorded_phase == "installing"
        || recorded_phase == "reboot_required" && !after_boot
        || record.get("recovery_required").is_some_and(|v| v == "true")
    {
        baseline.clone()
    } else {
        current.clone()
    };
    let mut reboot = recorded_phase == "reboot_required" && staged;
    let mut recovery = record.get("recovery_required").is_some_and(|s| s == "true");
    let lock_evidence = if busy_phase(&recorded_phase) {
        lock_busy(app)
    } else {
        Ok(false)
    };
    if stage_evidence.is_err() {
        put(&mut record, "phase", "failed");
        put(&mut record, "error_code", "module-update.io");
        recovery = true;
        reboot = false;
    } else if recorded_phase == "reboot_required"
        && after_boot
        && !staged
        && current == latest
        && current.is_some()
    {
        put(&mut record, "phase", "up_to_date");
        put(&mut record, "error_code", "none");
        recovery = false;
        reboot = false;
    } else if busy_phase(&recorded_phase) && lock_evidence != Ok(true) {
        put(&mut record, "phase", "failed");
        let lock_error = lock_evidence.is_err();
        put(
            &mut record,
            "error_code",
            if lock_error {
                "module-update.io"
            } else {
                "module-update.interrupted"
            },
        );
        recovery = lock_error || recorded_phase == "installing" || staged;
    } else if recorded_phase == "reboot_required"
        && (module_version(&pending(app).join("module.prop")) != latest || !marked(app, "update"))
    {
        put(&mut record, "phase", "failed");
        put(
            &mut record,
            "error_code",
            "module-update.staging_unverified",
        );
        recovery = true;
        reboot = false;
    }
    let manager = detect_manager().map(|m| m.name).unwrap_or("unknown");
    let running = record.get("phase").is_some_and(|p| busy_phase(p));
    let available = match (&effective, &latest) {
        (Some(installed), Some(candidate)) => Some(
            candidate.code > installed.code
                && version_tuple(&candidate.version) > version_tuple(&installed.version),
        ),
        _ => None,
    };
    let version_json = |value: Option<&Version>| json!({"version":value.map(|v|&v.version),"version_code":value.map(|v|v.code)});
    json!({"installed":version_json(effective.as_ref()),"latest":version_json(latest.as_ref()),
        "update_available":available,"phase":record.get("phase").map(String::as_str).unwrap_or("idle"),
        "manager":manager,"supported":manager!="unknown" && unsafe{libc::geteuid()}==0,
        "busy":running,"reboot_required":reboot,"recovery_required":recovery,
        "error_code":record.get("error_code").filter(|s|s.as_str()!="none"),
        "request_id":record.get("request_id").filter(|s|safe_id(s))})
}

fn settle_locked(app: &App) -> Result<()> {
    let mut record = canonical(app);
    let old_phase = record
        .get("phase")
        .map(String::as_str)
        .unwrap_or("idle")
        .to_owned();
    let staged = staging_present(app)?;
    let current = active_version(app);
    let after_boot = record
        .get("boot_id")
        .is_some_and(|id| different_boot(id, &boot_id()));
    if busy_phase(&old_phase) {
        put(&mut record, "phase", "failed");
        put(&mut record, "error_code", "module-update.interrupted");
        put(
            &mut record,
            "recovery_required",
            old_phase == "installing" || staged,
        );
    } else if old_phase == "reboot_required"
        && after_boot
        && !staged
        && current == record_version(&record, "latest")
        && current.is_some()
    {
        put(&mut record, "phase", "up_to_date");
        put(&mut record, "error_code", "none");
        put(&mut record, "recovery_required", "false");
        store_version(&mut record, "installed", current.as_ref().unwrap());
    } else if old_phase == "reboot_required"
        && (module_version(&pending(app).join("module.prop")) != record_version(&record, "latest")
            || !marked(app, "update"))
    {
        put(&mut record, "phase", "failed");
        put(
            &mut record,
            "error_code",
            "module-update.staging_unverified",
        );
        put(&mut record, "recovery_required", "true");
    }
    put(&mut record, "schema", 1);
    put(&mut record, "domain", "module-update");
    if !record.contains_key("phase") {
        put(&mut record, "phase", "idle");
    }
    if !staged && old_phase == "idle" {
        if let Some(current) = current {
            store_version(&mut record, "installed", &current);
        }
    }
    publish(app, &record)
}

fn receipt_ledger(app: &App) -> Result<Value> {
    let path = app.moddir.join(RECEIPTS);
    if !exists(&path) {
        return Ok(json!({"schema":1,"seen":[],"receipts":[]}));
    }
    let value =
        crate::utils::read_json_file_bounded(&path, 512 * 1024).ok_or("module-update.io")?;
    let seen = value["seen"].as_array().ok_or("module-update.io")?;
    let receipts = value["receipts"].as_array().ok_or("module-update.io")?;
    if value["schema"] != 1
        || seen.len() > 4096
        || receipts.len() > 128
        || seen.iter().any(|id| !id.as_str().is_some_and(safe_id))
    {
        return Err("module-update.io");
    }
    Ok(value)
}

fn refuse_if_recovery_or_staging(app: &App) -> Result<()> {
    if status(app)["recovery_required"] == true {
        return Err("module-update.recovery_required");
    }
    if staging_present(app)? {
        return Err("module-update.pending_update");
    }
    Ok(())
}

fn verified_staged_module(app: &App) -> Result<PathBuf> {
    let staged = pending(app);
    let metadata = fs::symlink_metadata(&staged).map_err(|_| "module-update.staging_unverified")?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err("module-update.staging_unverified");
    }
    Ok(staged)
}

fn replay_receipt(
    ledger: &Value,
    action: &str,
    installed: &str,
    latest: &str,
    id: &str,
) -> Result<Option<Value>> {
    if let Some(receipt) = ledger["receipts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|receipt| receipt["id"] == id)
    {
        if receipt["action"] != action
            || receipt["installed"] != installed
            || receipt["latest"] != latest
        {
            return Err("module-update.conflict");
        }
        return receipt["data"]
            .as_object()
            .map(|_| Some(receipt["data"].clone()))
            .ok_or("module-update.conflict");
    }
    if ledger["seen"]
        .as_array()
        .unwrap()
        .iter()
        .any(|seen| seen == id)
    {
        return Err("module-update.conflict");
    }
    if ledger["seen"].as_array().unwrap().len() == 4096 {
        return Err("module-update.unavailable");
    }
    Ok(None)
}

fn update_terminal_receipt(app: &App) -> Result<()> {
    let record = canonical(app);
    if record.get("phase").is_some_and(|phase| busy_phase(phase)) {
        return Ok(());
    }
    let Some(id) = record.get("request_id") else {
        return Ok(());
    };
    let mut ledger = receipt_ledger(app)?;
    if let Some(receipt) = ledger["receipts"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|receipt| receipt["id"] == *id)
    {
        receipt["data"] = status(app);
        crate::write_text_file(app, Path::new(RECEIPTS), &ledger.to_string())
            .map_err(|_| "module-update.io")?;
    }
    Ok(())
}

pub(crate) fn reconcile(app: &App) -> Result<()> {
    let held = match lock(app) {
        Ok(held) => held,
        Err("module-update.busy") => return Ok(()),
        Err(code) => return Err(code),
    };
    let result = settle_locked(app).and_then(|()| update_terminal_receipt(app));
    drop(held);
    result
}

pub(crate) fn action(app: &App, args: &[&str]) -> Result<Value> {
    let (action, expected_installed, expected_latest, id) = match args {
        ["check", id] if safe_id(id) => ("check", "none", "none", *id),
        ["install", installed, latest, id]
            if safe_id(id)
                && version_tuple(installed).is_some()
                && version_tuple(latest).is_some() =>
        {
            ("install", *installed, *latest, *id)
        }
        _ => return Err("module-update.invalid_request"),
    };
    if unsafe { libc::geteuid() } != 0 {
        return Err("module-update.not_root");
    }
    let held = match lock(app) {
        Ok(held) => held,
        Err("module-update.busy") => {
            let intent = tokens(&app.moddir.join(INTENT));
            if same_intent(&intent, action, expected_installed, expected_latest, id) {
                return Ok(status(app));
            }
            if intent.get("request_id").is_some_and(|value| value == id) {
                return Err("module-update.conflict");
            }
            return Err("module-update.busy");
        }
        Err(code) => return Err(code),
    };
    let previous = tokens(&app.moddir.join(INTENT));
    // Holding this newly acquired lock proves the previous producer no longer
    // owns it. Never let our own lock make an interrupted installer look live.
    settle_locked(app)?;
    update_terminal_receipt(app)?;
    let mut ledger = receipt_ledger(app)?;
    // Recovery and leftover staging outrank idempotent receipts. A stale
    // successful check must not advertise "available" after an interrupted
    // install left recovery_required=true.
    refuse_if_recovery_or_staging(app)?;
    if let Some(data) = replay_receipt(&ledger, action, expected_installed, expected_latest, id)? {
        return Ok(data);
    }
    if previous.get("request_id").is_some_and(|value| value == id) {
        if same_intent(&previous, action, expected_installed, expected_latest, id) {
            return Ok(status(app));
        }
        return Err("module-update.conflict");
    }
    if action == "install" {
        if detect_manager().is_none() {
            return Err("module-update.unsupported_manager");
        }
        if path_present(&app.moddir.join("disable"))? || path_present(&app.moddir.join("remove"))? {
            return Err("module-update.disabled");
        }
        let actual = active_version(app).ok_or("module-update.unavailable")?;
        let record = canonical(app);
        let checked = record_version(&record, "installed").ok_or("module-update.conflict")?;
        let latest = record_version(&record, "latest").ok_or("module-update.conflict")?;
        if actual != checked
            || actual.version != expected_installed
            || latest.version != expected_latest
            || latest.code <= actual.code
            || version_tuple(&latest.version) <= version_tuple(&actual.version)
        {
            return Err("module-update.conflict");
        }
        load_release(app, &latest)?;
    }
    let mut record = canonical(app);
    put(&mut record, "schema", 1);
    put(&mut record, "domain", "module-update");
    put(&mut record, "request_id", id);
    put(&mut record, "action", action);
    put(&mut record, "boot_id", boot_id());
    put(&mut record, "recovery_required", "false");
    if let Some(current) = active_version(app) {
        store_version(&mut record, "installed", &current);
    }
    put(
        &mut record,
        "phase",
        if action == "check" {
            "checking"
        } else {
            "downloading"
        },
    );
    put(&mut record, "error_code", "none");
    let intent=format!("schema=1\naction={action}\nrequest_id={id}\nexpected_installed={expected_installed}\nexpected_latest={expected_latest}\n");
    ledger["seen"].as_array_mut().unwrap().push(id.into());
    let receipts = ledger["receipts"].as_array_mut().unwrap();
    receipts.push(json!({"id":id,"action":action,"installed":expected_installed,"latest":expected_latest,"data":null}));
    if receipts.len() > 128 {
        receipts.remove(0);
    }
    let ledger_text = ledger.to_string();
    let canonical_text = record
        .iter()
        .map(|(k, v)| format!("{k}={v}\n"))
        .collect::<String>();
    crate::replace_module_text_files_transactionally(
        app,
        &[
            (Path::new(INTENT), &intent),
            (
                crate::state::module_update_path().as_path(),
                &canonical_text,
            ),
            (Path::new(RECEIPTS), &ledger_text),
        ],
    )
    .map_err(|_| "module-update.io")?;
    if spawn_worker(app, &held, id).is_err() {
        put(&mut record, "phase", "failed");
        put(&mut record, "error_code", "module-update.io");
        publish(app, &record)?;
        update_terminal_receipt(app)?;
        return Err("module-update.io");
    }
    // Closing the parent descriptor leaves the child's inherited flock held.
    drop(held);
    Ok(status(app))
}

fn same_intent(
    intent: &BTreeMap<String, String>,
    action: &str,
    installed: &str,
    latest: &str,
    id: &str,
) -> bool {
    [
        ("action", action),
        ("expected_installed", installed),
        ("expected_latest", latest),
        ("request_id", id),
    ]
    .iter()
    .all(|(key, value)| intent.get(*key).is_some_and(|saved| saved == value))
}

fn spawn_worker(app: &App, held: &File, id: &str) -> Result<()> {
    let exe = std::env::current_exe().map_err(|_| "module-update.io")?;
    let mut command = Command::new(exe);
    command
        .args(["__module-update-worker", id])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    crate::process::clear_unsafe_loader_environment(&mut command);
    if !cfg!(target_os = "android") {
        command.env("MODDIR", &app.moddir);
    }
    configure_detached_worker(&mut command, held.as_raw_fd());
    command.spawn().map_err(|_| "module-update.io")?;
    Ok(())
}

fn configure_detached_worker(command: &mut Command, source: i32) {
    // SAFETY: only async-signal-safe libc functions run between fork and exec.
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() < 0
                || libc::dup2(source, CHILD_FD) < 0
                || libc::fcntl(CHILD_FD, libc::F_SETFD, 0) < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

pub(crate) fn worker(app: &App, args: &[String]) -> Result<()> {
    let [id] = args else {
        return Err("module-update.invalid_request");
    };
    if !safe_id(id) || unsafe { libc::geteuid() } != 0 {
        return Err("module-update.invalid_request");
    }
    let pathmeta = fs::symlink_metadata(app.moddir.join(LOCK)).map_err(|_| "module-update.io")?;
    // SAFETY: fstat validates the inherited descriptor before taking ownership.
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(CHILD_FD, &mut stat) } != 0
        || stat.st_dev as u64 != pathmeta.dev()
        || stat.st_ino as u64 != pathmeta.ino()
        || stat.st_mode & libc::S_IFMT != libc::S_IFREG
    {
        return Err("module-update.invalid_request");
    }
    let held = unsafe { File::from_raw_fd(CHILD_FD) };
    if unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("module-update.busy");
    }
    // Do not leak the operation lock into curl, unzip or manager subprocesses.
    if unsafe { libc::fcntl(CHILD_FD, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        return Err("module-update.io");
    }
    let intent = tokens(&app.moddir.join(INTENT));
    if intent.get("request_id") != Some(id) {
        return Err("module-update.conflict");
    }
    let mut record = canonical(app);
    let result =
        cleanup_downloads(app).and_then(|()| match intent.get("action").map(String::as_str) {
            Some("check") => check_worker(app, &mut record),
            Some("install") => install_worker(app, &mut record),
            _ => Err("module-update.invalid_request"),
        });
    if let Err(code) = result {
        let recovery = record.get("phase").is_some_and(|v| v == "installing")
            || exists(&pending(app))
            || marked(app, "update");
        put(&mut record, "phase", "failed");
        put(&mut record, "error_code", code);
        put(&mut record, "recovery_required", recovery);
        publish(app, &record)?;
    }
    update_terminal_receipt(app)?;
    if record
        .get("phase")
        .is_some_and(|phase| phase == "reboot_required")
    {
        let next = App::from_module_root(pending(app));
        let ledger = receipt_ledger(app)?;
        crate::write_text_file(&next, Path::new(RECEIPTS), &ledger.to_string())
            .map_err(|_| "module-update.io")?;
    }
    drop(held);
    result
}

#[derive(Clone)]
struct Release {
    version: Version,
    core_id: u64,
    sums_id: u64,
    core_sha: String,
    sums_sha: String,
    size: u64,
}
fn digest(value: &str) -> Option<String> {
    let value = value.strip_prefix("sha256:")?;
    (value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit()))
        .then(|| value.to_ascii_lowercase())
}
fn parse_release(value: &Value) -> Result<Release> {
    if value["draft"] != false || value["prerelease"] != false {
        return Err("module-update.invalid_release");
    }
    let tag = value["tag_name"]
        .as_str()
        .filter(|v| version_tuple(v).is_some())
        .ok_or("module-update.invalid_release")?;
    let name = value["name"]
        .as_str()
        .ok_or("module-update.invalid_release")?;
    let code = name
        .strip_prefix("MagicNet-")
        .and_then(|s| s.strip_suffix(&format!("-{tag}")))
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|v| *v > 0)
        .ok_or("module-update.invalid_release")?;
    let assets = value["assets"]
        .as_array()
        .filter(|v| v.len() <= 128)
        .ok_or("module-update.invalid_release")?;
    let asset = |name: &str, limit: u64| -> Result<&Value> {
        let mut matching = assets.iter().filter(|asset| asset["name"] == name);
        let asset = matching.next().ok_or("module-update.invalid_release")?;
        if matching.next().is_some()
            || asset["state"] != "uploaded"
            || asset["id"].as_u64().is_none_or(|id| id == 0)
            || asset["size"].as_u64().is_none_or(|v| v == 0 || v > limit)
            || asset["browser_download_url"] != format!("{REPO}{tag}/{name}")
        {
            return Err("module-update.invalid_release");
        }
        Ok(asset)
    };
    let core = asset("MagicNet-core.zip", MAX_CORE as u64)?;
    let sums = asset("SHA256SUMS", 64 * 1024)?;
    Ok(Release {
        version: Version {
            version: tag.into(),
            code,
        },
        core_id: core["id"].as_u64().unwrap(),
        sums_id: sums["id"].as_u64().unwrap(),
        core_sha: digest(core["digest"].as_str().unwrap_or("")).ok_or("module-update.integrity")?,
        sums_sha: digest(sums["digest"].as_str().unwrap_or("")).ok_or("module-update.integrity")?,
        size: core["size"].as_u64().unwrap(),
    })
}

fn load_release(app: &App, expected: &Version) -> Result<Release> {
    let json = crate::utils::read_json_file_bounded(&app.moddir.join(METADATA), 1024 * 1024)
        .ok_or("module-update.conflict")?;
    let release = parse_release(&json)?;
    if &release.version != expected {
        return Err("module-update.conflict");
    }
    Ok(release)
}

fn check_worker(app: &App, record: &mut BTreeMap<String, String>) -> Result<()> {
    phase(app, record, "checking")?;
    let body = fetch(app, API, 1024 * 1024, FetchMedia::ReleaseJson)?;
    let json: Value = serde_json::from_slice(&body).map_err(|_| "module-update.invalid_release")?;
    let release = parse_release(&json)?;
    crate::write_secret_file(
        app,
        Path::new(METADATA),
        &serde_json::to_string(&json).map_err(|_| "module-update.io")?,
    )
    .map_err(|_| "module-update.io")?;
    store_version(record, "latest", &release.version);
    let installed = record_version(record, "installed").ok_or("module-update.unavailable")?;
    let available = {
        let v = installed;
        release.version.code > v.code
            && version_tuple(&release.version.version) > version_tuple(&v.version)
    };
    phase(
        app,
        record,
        if available { "available" } else { "up_to_date" },
    )
}

fn sha(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn checksum_entry(bytes: &[u8]) -> Result<String> {
    let text = std::str::from_utf8(bytes).map_err(|_| "module-update.integrity")?;
    let mut result = None;
    for line in text.lines() {
        let Some((hash, name)) = line.split_once("  ") else {
            continue;
        };
        if name == "MagicNet-core.zip" {
            if result.is_some() {
                return Err("module-update.integrity");
            }
            result = digest(&format!("sha256:{hash}"));
            if result.is_none() {
                return Err("module-update.integrity");
            }
        }
    }
    result.ok_or("module-update.integrity")
}

fn require_space(path: &Path, bytes: u64) -> Result<()> {
    let path = crate::cstring_from_os_str(path.as_os_str(), "update directory")
        .map_err(|_| "module-update.io")?;
    let mut stat = unsafe { std::mem::zeroed::<libc::statvfs>() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut stat) } != 0 {
        return Err("module-update.io");
    }
    let available = (stat.f_bavail as u64)
        .checked_mul(stat.f_frsize as u64)
        .ok_or("module-update.no_space")?;
    if available < bytes {
        Err("module-update.no_space")
    } else {
        Ok(())
    }
}

fn install_worker(app: &App, record: &mut BTreeMap<String, String>) -> Result<()> {
    let latest = record_version(record, "latest").ok_or("module-update.conflict")?;
    let installed = record_version(record, "installed").ok_or("module-update.conflict")?;
    if active_version(app) != Some(installed) {
        return Err("module-update.conflict");
    }
    let release = load_release(app, &latest)?;
    let manager = detect_manager().ok_or("module-update.unsupported_manager")?;
    if path_present(&app.moddir.join("disable"))? || path_present(&app.moddir.join("remove"))? {
        return Err("module-update.disabled");
    }
    if staging_present(app)? {
        return Err("module-update.pending_update");
    }
    let directory = private_dir(app)?;
    require_space(&directory, release.size * 3 + 64 * 1024 * 1024)?;
    phase(app, record, "downloading")?;
    let sums = fetch_asset(app, release.sums_id, 64 * 1024)?;
    if sha(&sums) != release.sums_sha || checksum_entry(&sums)? != release.core_sha {
        return Err("module-update.integrity");
    }
    let bytes = fetch_asset(app, release.core_id, MAX_CORE)?;
    phase(app, record, "verifying")?;
    if bytes.len() as u64 != release.size || sha(&bytes) != release.core_sha {
        return Err("module-update.integrity");
    }
    let path = directory.join("package.zip");
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
            .map_err(|_| "module-update.io")?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "module-update.io")?;
        drop(file);
        let budget = archive::validate(app, &path, &latest.version, latest.code)?;
        require_space(
            &directory,
            budget
                .checked_add(64 * 1024 * 1024)
                .ok_or("module-update.no_space")?,
        )?;
        if staging_present(app)? {
            return Err("module-update.pending_update");
        }
        if path_present(&app.moddir.join("disable"))? || path_present(&app.moddir.join("remove"))? {
            return Err("module-update.disabled");
        }
        phase(app, record, "installing")?;
        let mut command = Command::new(manager.path);
        command
            .args(manager.install_args)
            .arg(&path)
            .env_clear()
            .env(
                "PATH",
                "/system/bin:/system/xbin:/vendor/bin:/data/adb/magisk",
            )
            .env("MAGICNET_NONINTERACTIVE", "1");
        let output = run_bounded_command(command, Duration::from_secs(900), 64 * 1024)
            .map_err(|_| "module-update.install_failed")?;
        if output.timed_out || !output.status.is_some_and(|s| s.success()) {
            return Err("module-update.install_failed");
        }
        let staged = verified_staged_module(app)?;
        if module_version(&staged.join("module.prop")) != Some(latest.clone())
            || !marked(app, "update")
            || marked(app, "disable")
            || marked(app, "remove")
        {
            return Err("module-update.staging_unverified");
        }
        put(record, "manager", manager.name);
        phase(app, record, "reboot_required")?;
        // Publish the updater state into the next module only after proving its
        // identity. This future canonical record survives manager promotion.
        let next = App::from_module_root(staged);
        publish(&next, record)?;
        Ok(())
    })();
    // This exact regular archive is updater-owned, never manager staging.
    let _ = fs::remove_file(path);
    result
}

fn allowed_url(url: &str) -> Result<(String, u16)> {
    let suffix = url
        .strip_prefix("https://")
        .ok_or("module-update.network")?;
    let (host, path) = suffix.split_once('/').ok_or("module-update.network")?;
    if !matches!(
        host,
        "api.github.com"
            | "github.com"
            | "release-assets.githubusercontent.com"
            | "objects.githubusercontent.com"
    ) || url
        .bytes()
        .any(|b| b <= 32 || b == 127 || matches!(b, b'\\' | b'#'))
        || path.is_empty()
    {
        return Err("module-update.network");
    }
    Ok((host.into(), 443))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FetchMedia {
    ReleaseJson,
    AssetOctets,
}

impl FetchMedia {
    fn accept(self) -> &'static str {
        match self {
            Self::ReleaseJson => "application/vnd.github+json",
            Self::AssetOctets => "application/octet-stream",
        }
    }
}

fn asset_url(id: u64) -> Result<String> {
    if id == 0 {
        return Err("module-update.invalid_release");
    }
    Ok(format!("{ASSET_API}{id}"))
}

fn fetch_asset(app: &App, id: u64, limit: usize) -> Result<Vec<u8>> {
    fetch(app, &asset_url(id)?, limit, FetchMedia::AssetOctets)
}

fn fetch(app: &App, url: &str, limit: usize, media: FetchMedia) -> Result<Vec<u8>> {
    fetch_with(url, limit, media, |url, limit, media| {
        fetch_response(app, url, limit, media)
    })
}

fn fetch_with(
    url: &str,
    limit: usize,
    media: FetchMedia,
    mut request: impl FnMut(&str, usize, FetchMedia) -> Result<Vec<u8>>,
) -> Result<Vec<u8>> {
    let mut url = url.to_owned();
    for _ in 0..=5 {
        allowed_url(&url)?;
        let bytes = request(&url, limit, media)?;
        let (code, location, body) = response_bytes(&bytes, limit)?;
        match code {
            200 => return Ok(body.to_vec()),
            301 | 302 | 303 | 307 | 308 => {
                url = location.ok_or("module-update.network")?;
                allowed_url(&url)?;
            }
            _ => return Err("module-update.network"),
        }
    }
    Err("module-update.network")
}

fn fetch_response(app: &App, url: &str, limit: usize, media: FetchMedia) -> Result<Vec<u8>> {
    let (host, port) = allowed_url(url)?;
    let addresses = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|_| "module-update.network")?
        .map(|a| a.ip())
        .collect::<HashSet<_>>();
    crate::subscriptions::validate_resolved_subscription_addresses(&addresses)
        .map_err(|_| "module-update.network")?;
    let command = download_command(app, url, limit, media, &host, port, addresses);
    let output = run_bounded_command(command, Duration::from_secs(185), limit + 16384)
        .map_err(|_| "module-update.network")?;
    if output.timed_out || output.truncated || !output.status.is_some_and(|s| s.success()) {
        return Err("module-update.network");
    }
    Ok(output.stdout)
}

fn download_command(
    app: &App,
    url: &str,
    limit: usize,
    media: FetchMedia,
    host: &str,
    port: u16,
    addresses: HashSet<std::net::IpAddr>,
) -> Command {
    let mut command = crate::trusted_curl(app);
    command
        .args([
            "-q",
            "-sS",
            "--noproxy",
            "*",
            "--proto",
            "=https",
            "--max-redirs",
            "0",
            "--max-filesize",
            &limit.to_string(),
            "--connect-timeout",
            "15",
            "--max-time",
            "180",
            "--include",
        ])
        .args([
            "--user-agent",
            "MagicNet-module-updater/1",
            "--header",
            &format!("Accept: {}", media.accept()),
        ]);
    let mut pins = Vec::new();
    for address in addresses {
        let address = if address.is_ipv6() {
            format!("[{address}]")
        } else {
            address.to_string()
        };
        pins.push(address);
    }
    pins.sort();
    command.args(["--resolve", &format!("{host}:{port}:{}", pins.join(","))]);
    // curl gets no caller-supplied CA/config/auth or key-log environment.
    command
        .env_clear()
        .env("PATH", "/system/bin:/system/xbin:/vendor/bin");
    command.arg(url);
    command
}

fn response_bytes(bytes: &[u8], limit: usize) -> Result<(u16, Option<String>, &[u8])> {
    let mut offset = 0;
    for _ in 0..=5 {
        let relative = bytes
            .get(offset..)
            .ok_or("module-update.network")?
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .ok_or("module-update.network")?;
        let end = offset
            .checked_add(relative + 4)
            .filter(|end| *end <= 16384)
            .ok_or("module-update.network")?;
        let headers =
            std::str::from_utf8(&bytes[offset..end]).map_err(|_| "module-update.network")?;
        let (code, location) = response_headers(headers)?;
        if (100..200).contains(&code) {
            offset = end;
            continue;
        }
        let body = &bytes[end..];
        if body.len() > limit {
            return Err("module-update.network");
        }
        return Ok((code, location, body));
    }
    Err("module-update.network")
}

fn response_headers(text: &str) -> Result<(u16, Option<String>)> {
    let mut code = None;
    let mut location = None;
    for line in text.lines() {
        if line.starts_with("HTTP/") {
            code = line
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse::<u16>().ok());
            location = None;
        } else if let Some((key, value)) = line.split_once(':') {
            if key.eq_ignore_ascii_case("location") {
                if location.is_some() {
                    return Err("module-update.network");
                }
                location = Some(value.trim().to_owned());
            }
        }
    }
    Ok((code.ok_or("module-update.network")?, location))
}

struct Manager {
    name: &'static str,
    path: &'static str,
    install_args: &'static [&'static str],
}
fn probe(path: &str, args: &[&str]) -> Option<String> {
    let mut command = Command::new(path);
    command
        .args(args)
        .env_clear()
        .env("PATH", "/system/bin:/system/xbin:/vendor/bin");
    let output = run_bounded_command(command, Duration::from_secs(4), 8192).ok()?;
    if output.timed_out || output.truncated || !output.status.is_some_and(|s| s.success()) {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}
fn detect_manager() -> Option<Manager> {
    if !cfg!(target_os = "android") || unsafe { libc::geteuid() } != 0 {
        return None;
    }
    for path in ["/data/adb/ksud", "/data/adb/ksu/bin/ksud"] {
        if probe(path, &["debug", "version"]).is_some_and(|text| {
            text.lines().any(|line| {
                line.trim()
                    .strip_prefix("Kernel Version:")
                    .and_then(|v| v.trim().parse::<u32>().ok())
                    .is_some_and(|v| v > 0)
            })
        }) {
            return Some(Manager {
                name: "kernelsu",
                path,
                install_args: &["module", "install"],
            });
        }
    }
    for path in [
        "/data/adb/magisk/magisk",
        "/sbin/magisk",
        "/debug_ramdisk/magisk",
    ] {
        if probe(path, &["-V"]).is_some_and(|text| text.trim().parse::<u32>().is_ok_and(|v| v > 0))
        {
            return Some(Manager {
                name: "magisk",
                path,
                install_args: &["--install-module"],
            });
        }
    }
    for path in ["/data/adb/apd", "/data/adb/ap/bin/apd"] {
        if probe(path, &["-V"]).is_some_and(|text| text.trim().parse::<u64>().is_ok_and(|v| v > 0))
            && probe(path, &["module", "list"]).is_some_and(|text| {
                serde_json::from_str::<Value>(&text).is_ok_and(|v| v.is_array())
            })
        {
            return Some(Manager {
                name: "apatch",
                path,
                install_args: &["module", "install"],
            });
        }
    }
    None
}

pub(crate) fn message(_: &str) -> &'static str {
    "MagicNet module update could not complete; inspect the structured status"
}

#[cfg(test)]
mod tests {
    use super::*;
    fn release() -> Value {
        json!({"draft":false,"prerelease":false,"tag_name":"v1.5.21","name":"MagicNet-1789322931012-v1.5.21",
        "assets":[{"id":1,"name":"MagicNet-core.zip","size":100,"state":"uploaded","digest":format!("sha256:{}","a".repeat(64)),"browser_download_url":format!("{REPO}v1.5.21/MagicNet-core.zip")},
        {"id":2,"name":"SHA256SUMS","size":200,"state":"uploaded","digest":format!("sha256:{}","b".repeat(64)),"browser_download_url":format!("{REPO}v1.5.21/SHA256SUMS")} ]})
    }
    #[test]
    fn strict_versions_and_request_ids() {
        for v in ["v1.5.21", "v0.0.1"] {
            assert!(version_tuple(v).is_some());
        }
        for v in [
            "v1.5.21-rc1",
            "1.5.21",
            "v01.5.21",
            "v1.5.21;id",
            "v1.5.21.2",
        ] {
            assert!(version_tuple(v).is_none());
        }
        assert!(safe_id("request_1234"));
        assert!(!safe_id("$(id)___"));
        assert!(!safe_id("abc"));
    }
    #[test]
    fn official_release_requires_both_digests() {
        assert!(parse_release(&release()).is_ok());
        for pointer in ["/assets/0/digest", "/assets/1/digest"] {
            let mut r = release();
            *r.pointer_mut(pointer).unwrap() = Value::Null;
            assert!(parse_release(&r).is_err());
        }
        for field in ["draft", "prerelease"] {
            let mut r = release();
            r[field] = true.into();
            assert!(parse_release(&r).is_err());
        }
        let mut r = release();
        r["assets"][0]["browser_download_url"] = "https://evil.invalid/pkg.zip".into();
        assert!(parse_release(&r).is_err());
    }
    #[test]
    fn official_asset_ids_are_required_and_keep_fixed_download_endpoints() {
        let parsed = parse_release(&release()).unwrap();
        assert_eq!(parsed.core_id, 1);
        assert_eq!(parsed.sums_id, 2);
        assert_eq!(asset_url(parsed.core_id).unwrap(), format!("{ASSET_API}1"));
        assert_eq!(asset_url(parsed.sums_id).unwrap(), format!("{ASSET_API}2"));
        assert_eq!(asset_url(0), Err("module-update.invalid_release"));
        for pointer in ["/assets/0/id", "/assets/1/id"] {
            for id in [Value::Null, json!(0), json!(-1), json!(1.5), json!("1")] {
                let mut value = release();
                *value.pointer_mut(pointer).unwrap() = id;
                assert!(matches!(
                    parse_release(&value),
                    Err("module-update.invalid_release")
                ));
            }
        }
    }
    #[test]
    fn asset_api_accepts_direct_binary_content_and_validated_redirects() {
        let api = asset_url(1).unwrap();
        let binary = [b'P', b'K', 0, 255];
        let mut calls = 0;
        let bytes = fetch_with(&api, 4, FetchMedia::AssetOctets, |url, limit, media| {
            calls += 1;
            assert_eq!(url, api);
            assert_eq!(limit, 4);
            assert_eq!(media, FetchMedia::AssetOctets);
            let mut response =
                b"HTTP/2 200\r\nContent-Type: application/octet-stream\r\n\r\n".to_vec();
            response.extend_from_slice(&binary);
            Ok(response)
        })
        .unwrap();
        assert_eq!(bytes, binary);
        assert_eq!(calls, 1);

        let target = "https://release-assets.githubusercontent.com/assets/file?sig=abc";
        let mut calls = 0;
        let bytes = fetch_with(&api, 4, FetchMedia::AssetOctets, |url, limit, media| {
            calls += 1;
            assert_eq!(limit, 4);
            assert_eq!(media, FetchMedia::AssetOctets);
            if calls == 1 {
                assert_eq!(url, api);
                Ok(format!("HTTP/2 302\r\nLocation: {target}\r\n\r\n").into_bytes())
            } else {
                assert_eq!(url, target);
                Ok(b"HTTP/2 200\r\n\r\nbody".to_vec())
            }
        })
        .unwrap();
        assert_eq!(bytes, b"body");
        assert_eq!(calls, 2);
    }
    #[test]
    fn asset_redirects_reject_untrusted_targets_before_following() {
        for target in [
            "http://release-assets.githubusercontent.com/file",
            "https://github.com@evil.invalid/file",
            "https://release-assets.githubusercontent.com.evil.invalid/file",
            "https://release-assets.githubusercontent.com:443/file",
            "https://evil.invalid/file",
            "https://release-assets.githubusercontent.com/file#fragment",
            "https://release-assets.githubusercontent.com/fi\\le",
            "/relative/file",
        ] {
            let mut calls = 0;
            assert_eq!(
                fetch_with(
                    &asset_url(1).unwrap(),
                    4,
                    FetchMedia::AssetOctets,
                    |_, _, _| {
                        calls += 1;
                        Ok(format!("HTTP/2 302\r\nLocation: {target}\r\n\r\n").into_bytes())
                    }
                ),
                Err("module-update.network")
            );
            assert_eq!(calls, 1);
        }
        let mut calls = 0;
        assert_eq!(
            fetch_with(
                &asset_url(1).unwrap(),
                4,
                FetchMedia::AssetOctets,
                |_, _, _| {
                    calls += 1;
                    Ok(b"HTTP/2 302\r\nLocation: https://release-assets.githubusercontent.com/file\r\n\r\n".to_vec())
                }
            ),
            Err("module-update.network")
        );
        assert_eq!(calls, 6);
    }
    #[test]
    fn requests_negotiate_json_and_binary_without_automatic_redirects() {
        let app = crate::test_support::temp_app();
        for (url, media, accept) in [
            (
                API.to_owned(),
                FetchMedia::ReleaseJson,
                "Accept: application/vnd.github+json",
            ),
            (
                asset_url(1).unwrap(),
                FetchMedia::AssetOctets,
                "Accept: application/octet-stream",
            ),
        ] {
            let addresses = [
                "140.82.112.5".parse().unwrap(),
                "2606:50c0:8000::154".parse().unwrap(),
            ]
            .into_iter()
            .collect();
            let command = download_command(
                &app,
                &url,
                64 * 1024,
                media,
                "api.github.com",
                443,
                addresses,
            );
            let args = command
                .get_args()
                .map(|arg| arg.to_str().unwrap())
                .collect::<Vec<_>>();
            assert_eq!(args[0], "-q");
            for pair in [
                ["--header", accept],
                ["--max-redirs", "0"],
                ["--noproxy", "*"],
                ["--proto", "=https"],
            ] {
                assert!(args.windows(2).any(|args| args == pair));
            }
            assert!(args.windows(2).any(|args| args
                == [
                    "--resolve",
                    "api.github.com:443:140.82.112.5,[2606:50c0:8000::154]"
                ]));
            assert_eq!(args.last().unwrap(), &url);
            assert!(!args
                .iter()
                .any(|arg| matches!(*arg, "-L" | "--location" | "--location-trusted")));
        }
    }
    #[test]
    fn checksums_reject_duplicates_and_wrong_filename() {
        let hash = "a".repeat(64);
        assert_eq!(
            checksum_entry(format!("{hash}  MagicNet-core.zip\n").as_bytes()),
            Ok(hash.clone())
        );
        assert!(checksum_entry(format!("{hash}  ./MagicNet-core.zip\n").as_bytes()).is_err());
        assert!(checksum_entry(
            format!("{hash}  MagicNet-core.zip\n{hash}  MagicNet-core.zip\n").as_bytes()
        )
        .is_err());
    }
    #[test]
    fn redirects_are_bounded_to_official_https() {
        assert!(allowed_url(API).is_ok());
        assert!(
            allowed_url("https://release-assets.githubusercontent.com/assets/file?sig=abc").is_ok()
        );
        for value in [
            "http://github.com/a",
            "https://github.com@evil.invalid/a",
            "https://evil.invalid/a",
            "https://github.com/a\r\nX: value",
        ] {
            assert!(allowed_url(value).is_err());
        }
        assert!(response_headers(
            "HTTP/2 302\r\nLocation: https://github.com/a\r\nLocation: https://github.com/b\r\n"
        )
        .is_err());
    }
    #[test]
    fn identity_and_version_are_bounded_data() {
        let app = crate::test_support::temp_app();
        let root = &app.moddir;
        let path = root.join("module.prop");
        fs::write(
            &path,
            "id=MagicNet\nversion=v1.5.20\nversionCode=1789322931011\n",
        )
        .unwrap();
        assert_eq!(module_version(&path).unwrap().code, 1789322931011);
        fs::write(&path, "id=Other\nversion=v1.5.20\nversionCode=123\n").unwrap();
        assert!(module_version(&path).is_none());
    }

    fn fixture() -> (crate::test_support::TempApp, App) {
        let base = crate::test_support::temp_app();
        let module = base.moddir.join("modules/MagicNet");
        fs::create_dir_all(&module).unwrap();
        fs::write(
            module.join("module.prop"),
            "id=MagicNet\nversion=v1.5.20\nversionCode=100\n",
        )
        .unwrap();
        let app = App::for_test(module);
        fixture_payload(&app, "v1.5.20");
        (base, app)
    }

    fn fixture_payload(app: &App, version: &str) {
        fs::create_dir_all(app.moddir.join("bin")).unwrap();
        let bytes = b"owned-cli";
        fs::write(app.moddir.join("bin/magicnet-cli"), bytes).unwrap();
        let manifest = json!({"schema":1,"module":"MagicNet","version":version,"components":[
            {"id":"bin-magicnet-cli","files":[{"path":"bin/magicnet-cli","sha256":sha(bytes),"size":bytes.len()}]}]});
        fs::write(app.moddir.join("components.json"), manifest.to_string()).unwrap();
    }

    fn sample_record(app: &App, phase: &str) -> BTreeMap<String, String> {
        let mut record = BTreeMap::new();
        put(&mut record, "schema", 1);
        put(&mut record, "domain", "module-update");
        put(&mut record, "phase", phase);
        put(&mut record, "boot_id", boot_id());
        put(&mut record, "error_code", "none");
        put(&mut record, "recovery_required", "false");
        store_version(
            &mut record,
            "installed",
            &module_version(&app.moddir.join("module.prop")).unwrap(),
        );
        store_version(
            &mut record,
            "latest",
            &Version {
                version: "v1.5.21".into(),
                code: 101,
            },
        );
        record
    }

    #[test]
    fn read_only_status_does_not_create_files_or_guess_unknown_version() {
        let app = crate::test_support::temp_app();
        let data = status(&app);
        assert!(data["installed"]["version"].is_null());
        assert!(data["update_available"].is_null());
        assert!(!app.moddir.join(".state").exists());
    }

    #[test]
    fn staged_metadata_does_not_replace_effective_baseline() {
        let (_base, app) = fixture();
        let mut record = sample_record(&app, "reboot_required");
        publish(&app, &record).unwrap();
        let next = pending(&app);
        fs::create_dir_all(&next).unwrap();
        fs::write(
            app.moddir.join("module.prop"),
            "id=MagicNet\nversion=v1.5.21\nversionCode=101\n",
        )
        .unwrap();
        fs::write(
            next.join("module.prop"),
            "id=MagicNet\nversion=v1.5.21\nversionCode=101\n",
        )
        .unwrap();
        fs::write(app.moddir.join("update"), "").unwrap();
        let observed = status(&app);
        assert_eq!(observed["installed"]["version"], "v1.5.20");
        assert_eq!(observed["latest"]["version"], "v1.5.21");
        assert_eq!(observed["reboot_required"], true);
        // Same-boot marker disappearance is not proof of promotion.
        fs::remove_dir_all(next).unwrap();
        fs::remove_file(app.moddir.join("update")).unwrap();
        assert_eq!(status(&app)["recovery_required"], true);
        put(&mut record, "boot_id", "different_boot_1234");
        fixture_payload(&app, "v1.5.21");
        publish(&app, &record).unwrap();
        reconcile(&app).unwrap();
        let observed = status(&app);
        assert_eq!(observed["installed"]["version"], "v1.5.21");
        assert_eq!(observed["phase"], "up_to_date");
        assert_eq!(canonical(&app).get("installed_version").unwrap(), "v1.5.21");
    }

    #[test]
    fn crashed_install_is_published_as_recovery_and_live_worker_is_preserved() {
        let (_base, app) = fixture();
        let record = sample_record(&app, "installing");
        publish(&app, &record).unwrap();
        let held = lock(&app).unwrap();
        let before =
            bounded_text(&app.moddir.join(crate::state::module_update_path()), 8192).unwrap();
        reconcile(&app).unwrap();
        assert_eq!(
            bounded_text(&app.moddir.join(crate::state::module_update_path()), 8192).unwrap(),
            before
        );
        // Simulate owner exit deterministically: parallel tests may fork while
        // this descriptor is open and keep the lock until their child execs.
        // Production handoff remains close-only and has its own test below.
        assert_eq!(unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_UN) }, 0);
        drop(held);
        let held = lock(&app).unwrap();
        settle_locked(&app).unwrap();
        drop(held);
        assert_eq!(canonical(&app).get("phase").unwrap(), "failed");
        assert_eq!(status(&app)["recovery_required"], true);
        assert_eq!(status(&app)["error_code"], "module-update.interrupted");
    }

    #[test]
    fn detached_child_keeps_flock_after_parent_closes_descriptor() {
        use std::io::{BufRead, BufReader};
        let (_base, app) = fixture();
        let held = lock(&app).unwrap();
        let mut command = Command::new("/usr/bin/python3");
        command
            .args([
                "-c",
                "import sys; print('ready', flush=True); sys.stdin.read()",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped());
        configure_detached_worker(&mut command, held.as_raw_fd());
        let mut child = command.spawn().unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        assert_eq!(line.trim(), "ready");
        drop(held);
        let mut competing = Command::new("/usr/bin/flock");
        competing
            .arg("-n")
            .arg(app.moddir.join(LOCK))
            .arg("/usr/bin/true");
        assert!(!competing.status().unwrap().success());
        assert_eq!(lock(&app).err(), Some("module-update.busy"));
        drop(child.stdin.take());
        assert!(child.wait().unwrap().success());
        assert!(lock(&app).is_ok());
    }

    #[test]
    fn download_cleanup_cannot_follow_symlinks_or_remove_foreign_staging() {
        let (_base, app) = fixture();
        let directory = private_dir(&app).unwrap();
        let foreign = app.moddir.join("keep");
        fs::write(&foreign, "preserve").unwrap();
        std::os::unix::fs::symlink(&foreign, directory.join("package.zip")).unwrap();
        assert_eq!(cleanup_downloads(&app), Err("module-update.io"));
        assert_eq!(fs::read_to_string(foreign).unwrap(), "preserve");
    }

    #[test]
    fn unknown_boot_cannot_promote_and_copied_prop_needs_active_payload() {
        assert!(!different_boot("boot_1234", "unknown"));
        assert!(!different_boot("unknown", "boot_1234"));
        assert!(different_boot("boot_1234", "boot_5678"));
        let (_base, app) = fixture();
        assert!(active_version(&app).is_some());
        fs::write(
            app.moddir.join("module.prop"),
            "id=MagicNet\nversion=v1.5.21\nversionCode=101\n",
        )
        .unwrap();
        assert!(active_version(&app).is_none());
        fixture_payload(&app, "v1.5.21");
        assert!(active_version(&app).is_some());
        fs::write(app.moddir.join("bin/magicnet-cli"), "different").unwrap();
        assert!(active_version(&app).is_none());
    }

    #[test]
    #[test]
    fn receipt_replay_is_blocked_when_recovery_or_staging_is_present() {
        let (_base, app) = fixture();
        let mut record = sample_record(&app, "failed");
        put(&mut record, "recovery_required", "true");
        put(&mut record, "error_code", "module-update.interrupted");
        publish(&app, &record).unwrap();
        assert_eq!(
            refuse_if_recovery_or_staging(&app),
            Err("module-update.recovery_required")
        );

        put(&mut record, "recovery_required", "false");
        put(&mut record, "error_code", "none");
        publish(&app, &record).unwrap();
        fs::write(app.moddir.join("update"), "").unwrap();
        assert_eq!(
            refuse_if_recovery_or_staging(&app),
            Err("module-update.pending_update")
        );
        fs::remove_file(app.moddir.join("update")).unwrap();
        assert_eq!(refuse_if_recovery_or_staging(&app), Ok(()));
    }

    #[test]
    fn staged_module_must_be_a_real_directory() {
        let (_base, app) = fixture();
        let staged = pending(&app);
        fs::create_dir_all(staged.parent().unwrap()).unwrap();
        let foreign = app.moddir.join("keep");
        fs::create_dir_all(&foreign).unwrap();
        std::os::unix::fs::symlink(&foreign, &staged).unwrap();
        assert_eq!(
            verified_staged_module(&app),
            Err("module-update.staging_unverified")
        );
        fs::remove_file(&staged).unwrap();
        fs::create_dir_all(&staged).unwrap();
        assert_eq!(verified_staged_module(&app).unwrap(), staged);
    }

    #[test]
    fn receipt_replays_survive_intervening_actions_and_old_ids_cannot_run_again() {
        let ledger = json!({"schema":1,"seen":["request_1234","request_5678","expired_1234"],"receipts":[
            {"id":"request_1234","action":"check","installed":"none","latest":"none","data":{"request_id":"request_1234","phase":"available"}},
            {"id":"request_5678","action":"check","installed":"none","latest":"none","data":{"request_id":"request_5678","phase":"failed"}}]});
        assert_eq!(
            replay_receipt(&ledger, "check", "none", "none", "request_1234")
                .unwrap()
                .unwrap()["phase"],
            "available"
        );
        assert_eq!(
            replay_receipt(&ledger, "install", "v1.5.20", "v1.5.21", "request_1234"),
            Err("module-update.conflict")
        );
        assert_eq!(
            replay_receipt(&ledger, "check", "none", "none", "expired_1234"),
            Err("module-update.conflict")
        );
        assert!(
            replay_receipt(&ledger, "check", "none", "none", "brandnew_1234")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn interrupted_download_artifacts_do_not_block_the_next_request() {
        let (_base, app) = fixture();
        let directory = private_dir(&app).unwrap();
        fs::write(directory.join("headers"), "interrupted response").unwrap();
        fs::write(directory.join("package.zip"), "interrupted package").unwrap();
        let held = lock(&app).unwrap();
        cleanup_downloads(&app).unwrap();
        assert!(!directory.join("headers").exists());
        assert!(OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(directory.join("package.zip"))
            .is_ok());
        drop(held);
    }

    #[test]
    fn response_header_and_body_limits_apply_before_any_disk_write() {
        assert_eq!(
            response_bytes(b"HTTP/2 200\r\nContent-Type: x\r\n\r\nbody", 4)
                .unwrap()
                .2,
            b"body"
        );
        assert!(response_bytes(b"HTTP/2 200\r\n\r\nbody", 3).is_err());
        let huge = format!("HTTP/2 200\r\nX: {}\r\n\r\nbody", "a".repeat(16384));
        assert!(response_bytes(huge.as_bytes(), 4).is_err());
        assert_eq!(
            response_bytes(
                b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\n\r\nbody",
                4
            )
            .unwrap()
            .0,
            200
        );
    }

    #[test]
    fn wrong_staged_identity_is_recovery_not_a_reboot_success() {
        let (_base, app) = fixture();
        let record = sample_record(&app, "reboot_required");
        publish(&app, &record).unwrap();
        let stage = pending(&app);
        fs::create_dir_all(&stage).unwrap();
        fs::write(
            stage.join("module.prop"),
            "id=Other\nversion=v1.5.21\nversionCode=101\n",
        )
        .unwrap();
        fs::write(app.moddir.join("update"), "").unwrap();
        let data = status(&app);
        assert_eq!(data["phase"], "failed");
        assert_eq!(data["reboot_required"], false);
        assert_eq!(data["recovery_required"], true);
    }
}
