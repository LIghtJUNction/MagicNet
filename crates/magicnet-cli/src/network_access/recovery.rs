//! Explicit, per-identity recovery. The private journal is evidence for rollback,
//! not an instruction to keep overriding Android or a user's firewall choices.
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use super::{bridge, collect, package_inventory, valid_package, Policy};
use crate::App;

type Result<T> = std::result::Result<T, &'static str>;
const MAX_RECORD: u64 = 65536;
const MAX_RECORDS: usize = 128;

struct Lock(File);
impl Drop for Lock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[derive(Clone, Debug)]
struct Record {
    policy: Policy,
    phase: &'static str,
}

impl Record {
    fn encode(&self) -> Value {
        json!({
            "schema":1, "provider":self.policy.provider, "uid":self.policy.uid,
            "before":self.policy.value, "packages":self.policy.packages, "phase":self.phase,
        })
    }

    fn public(&self) -> Value {
        json!({
            "candidate":self.policy.candidate(), "provider":self.policy.provider,
            "packages":self.policy.packages, "recorded_phase":self.phase,
            "live_policy":"not_probed",
        })
    }
}

fn valid_token(token: &str) -> bool {
    token.len() == 64 && token.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn decode(token: &str, value: &Value) -> Result<Record> {
    if !valid_token(token) || value["schema"] != 1 {
        return Err("invalid_recovery_record");
    }
    let provider = match value["provider"].as_str() {
        Some("oplus") => "oplus",
        Some("android") => "android",
        _ => return Err("invalid_recovery_record"),
    };
    let number = |key: &str| {
        value[key]
            .as_u64()
            .filter(|v| *v <= i32::MAX as u64)
            .map(|v| v as u32)
            .ok_or("invalid_recovery_record")
    };
    let packages = value["packages"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 128)
        .ok_or("invalid_recovery_record")?
        .iter()
        .map(|v| {
            v.as_str()
                .filter(|name| valid_package(name))
                .map(str::to_string)
                .ok_or("invalid_recovery_record")
        })
        .collect::<Result<Vec<_>>>()?;
    if packages.windows(2).any(|pair| pair[0] >= pair[1]) {
        return Err("invalid_recovery_record");
    }
    let policy = Policy {
        provider,
        uid: number("uid")?,
        value: number("before")?,
        packages,
        // This is historical state, never authority to call a currently missing setter.
        writable: false,
    };
    if policy.allowed_target().is_none() || policy.candidate() != token {
        return Err("invalid_recovery_record");
    }
    let phase = match value["phase"].as_str() {
        Some("prepared") => "prepared",
        Some("applied") => "applied",
        Some("rollback_prepared") => "rollback_prepared",
        Some("rolled_back") => "rolled_back",
        _ => return Err("invalid_recovery_record"),
    };
    Ok(Record { policy, phase })
}

fn directory(root: &Path, create: bool) -> Result<Option<PathBuf>> {
    let mut path = root.to_path_buf();
    for component in ["", ".state", "network-access-recovery"] {
        if !component.is_empty() {
            path.push(component);
        }
        if create && !component.is_empty() {
            match DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err("recovery_io"),
            }
        }
        let meta = match fs::symlink_metadata(&path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err("recovery_io"),
        };
        let forbidden = if component == "network-access-recovery" { 0o077 } else { 0o022 };
        if !meta.is_dir()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.permissions().mode() & forbidden != 0
        {
            return Err("recovery_unsafe");
        }
    }
    Ok(Some(path))
}

fn private_file(meta: &fs::Metadata) -> bool {
    meta.is_file()
        && meta.nlink() == 1
        && meta.uid() == unsafe { libc::geteuid() }
        && meta.permissions().mode() & 0o077 == 0
}

fn lock(dir: &Path) -> Result<Lock> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(dir.join(".lock"))
        .map_err(|_| "recovery_io")?;
    if !private_file(&file.metadata().map_err(|_| "recovery_io")?) {
        return Err("recovery_unsafe");
    }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("recovery_busy");
    }
    Ok(Lock(file))
}

fn read(dir: &Path, token: &str) -> Result<Option<Record>> {
    if !valid_token(token) {
        return Err("invalid_candidate");
    }
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(dir.join(format!("{token}.json")))
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("recovery_io"),
    };
    let meta = file.metadata().map_err(|_| "recovery_io")?;
    if !private_file(&meta) || meta.len() > MAX_RECORD {
        return Err("recovery_unsafe");
    }
    let mut bytes = Vec::new();
    file.take(MAX_RECORD + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "recovery_io")?;
    if bytes.len() as u64 > MAX_RECORD {
        return Err("recovery_unsafe");
    }
    let value = serde_json::from_slice(&bytes).map_err(|_| "invalid_recovery_record")?;
    decode(token, &value).map(Some)
}

fn scan(dir: &Path) -> Result<Vec<Record>> {
    let mut records = Vec::new();
    for entry in fs::read_dir(dir).map_err(|_| "recovery_io")? {
        let name = entry.map_err(|_| "recovery_io")?.file_name();
        let name = name.to_str().ok_or("invalid_recovery_record")?;
        if name.starts_with('.') {
            continue;
        }
        let token = name.strip_suffix(".json").ok_or("invalid_recovery_record")?;
        let record = read(dir, token)?.ok_or("recovery_io")?;
        records.push(record);
        if records.len() > MAX_RECORDS {
            return Err("recovery_limit");
        }
    }
    records.sort_by_key(|record| record.policy.candidate());
    Ok(records)
}

fn save(dir: &Path, record: &Record) -> Result<()> {
    let token = record.policy.candidate();
    let value = record.encode();
    decode(&token, &value)?;
    let text = value.to_string();
    if text.len() as u64 > MAX_RECORD {
        return Err("recovery_limit");
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "recovery_io")?
        .as_nanos();
    let stage = dir.join(format!(".{token}.{}.{nonce}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&stage)
        .map_err(|_| "recovery_io")?;
    let result = (|| {
        file.write_all(text.as_bytes()).map_err(|_| "recovery_io")?;
        file.sync_all().map_err(|_| "recovery_io")?;
        fs::rename(&stage, dir.join(format!("{token}.json"))).map_err(|_| "recovery_io")?;
        File::open(dir)
            .and_then(|file| file.sync_all())
            .map_err(|_| "recovery_io")
    })();
    if result.is_err() {
        let _ = fs::remove_file(&stage);
    }
    result
}

fn live(app: &App, policy: &Policy) -> Result<(u32, bool)> {
    let inventory = package_inventory()?;
    if inventory.get(&policy.uid) != Some(&policy.packages) {
        return Err("identity_conflict");
    }
    let uid = policy.uid.to_string();
    let value = bridge(app, &["get", policy.provider, &uid])?;
    if value["provider"] != policy.provider || value["uid"] != policy.uid {
        return Err("invalid_bridge_response");
    }
    let current = value["policy"]
        .as_u64()
        .and_then(|value| u32::try_from(value).ok())
        .ok_or("invalid_bridge_response")?;
    Ok((current, value["repair_supported"] == true))
}

#[derive(Debug, PartialEq)]
enum Decision {
    Write,
    Complete,
    Noop,
}

fn decide(record: &Record, current: u32, rollback: bool) -> Result<Decision> {
    let before = record.policy.value;
    let target = record.policy.allowed_target().ok_or("repair_unsupported")?;
    if rollback {
        if current == before {
            return Ok(if record.phase == "rolled_back" { Decision::Noop } else { Decision::Complete });
        }
        if current == target && record.phase != "rolled_back" {
            return Ok(Decision::Write);
        }
        return Err("policy_conflict");
    }
    match (record.phase, current) {
        ("new" | "rolled_back", value) if value == before => Ok(Decision::Write),
        ("prepared", value) if value == target => Ok(Decision::Complete),
        ("applied", value) if value == target => Ok(Decision::Noop),
        ("applied", value) if value == before => Err("restriction_reapplied"),
        // The earlier call may have timed out after writing. Do not blindly reapply.
        ("prepared", value) if value == before => Err("interrupted_change"),
        ("rollback_prepared", _) => Err("rollback_required"),
        _ => Err("policy_conflict"),
    }
}

fn result(record: &Record, changed: bool) -> Value {
    json!({
        "candidate":record.policy.candidate(), "recorded_phase":record.phase,
        "changed":changed, "configured_verified":true,
        "rollback_available":record.phase != "rolled_back",
        "effective_system_dns":"not_probed", "automatic_reapply":false,
    })
}

pub(super) fn mutate(app: &App, token: &str, rollback: bool) -> Result<Value> {
    if !valid_token(token) {
        return Err("invalid_candidate");
    }
    if unsafe { libc::geteuid() } != 0 {
        return Err("permission_denied");
    }
    let dir = directory(&app.moddir, true)?.ok_or("recovery_io")?;
    let _lock = lock(&dir)?;
    let mut record = match read(&dir, token)? {
        Some(record) => record,
        None if rollback => return Err("recovery_not_found"),
        None => {
            if scan(&dir)?.len() >= MAX_RECORDS {
                return Err("recovery_limit");
            }
            let (_, policies, error) = collect(app);
            if let Some(error) = error {
                return Err(error);
            }
            let policy = policies
                .into_iter()
                .find(|p| p.candidate() == token)
                .ok_or("stale_candidate")?;
            if !policy.writable || policy.allowed_target().is_none() {
                return Err("repair_unsupported");
            }
            Record { policy, phase: "new" }
        }
    };
    let (current, writable) = live(app, &record.policy)?;
    let decision = decide(&record, current, rollback)?;
    if decision == Decision::Noop {
        return Ok(result(&record, false));
    }
    if decision == Decision::Write {
        if !writable {
            return Err("repair_unsupported");
        }
        record.phase = if rollback { "rollback_prepared" } else { "prepared" };
        // Durable write-ahead record precedes every framework change. Failures retain it.
        save(&dir, &record)?;
        let target = if rollback {
            record.policy.value
        } else {
            record.policy.allowed_target().ok_or("repair_unsupported")?
        };
        let uid = record.policy.uid.to_string();
        let value = bridge(app, &[
            "change", record.policy.provider, &uid, &current.to_string(),
            &target.to_string(), &record.policy.packages.join(","),
        ])?;
        if value["provider"] != record.policy.provider
            || value["uid"] != record.policy.uid
            || value["policy"] != target
            || value["configured_verified"] != true
        {
            return Err("invalid_bridge_response");
        }
        if live(app, &record.policy)?.0 != target {
            return Err("repair_not_effective");
        }
    }
    record.phase = if rollback { "rolled_back" } else { "applied" };
    save(&dir, &record)?;
    Ok(result(&record, decision == Decision::Write))
}

pub(super) fn check(app: &App, token: &str) -> Result<Value> {
    let dir = directory(&app.moddir, false)?.ok_or("recovery_not_found")?;
    let record = read(&dir, token)?.ok_or("recovery_not_found")?;
    let (current, _) = live(app, &record.policy)?;
    let observed = if current == record.policy.value {
        "original_policy"
    } else if Some(current) == record.policy.allowed_target() {
        "recovered_policy"
    } else {
        "policy_conflict"
    };
    Ok(json!({
        "candidate":token, "recorded_phase":record.phase, "observed_policy":observed,
        "restriction_reapplied":record.phase == "applied" && current == record.policy.value,
        "effective_system_dns":"not_probed", "automatic_reapply":false,
    }))
}

pub(super) fn summary(app: &App, private: bool) -> Value {
    let records = directory(&app.moddir, false)
        .and_then(|dir| dir.map(|dir| scan(&dir)).unwrap_or_else(|| Ok(Vec::new())));
    match records {
        Ok(records) => {
            let mut value = json!({
                "status":"observed", "record_count":records.len(),
                "pending_count":records.iter().filter(|r| matches!(r.phase, "prepared" | "rollback_prepared")).count(),
                "live_policy":"not_probed", "automatic_reapply":false,
            });
            if private {
                value["records"] = records.iter().map(Record::public).collect();
            }
            value
        }
        Err(reason) => json!({"status":"unknown", "reason":reason, "record_count":null}),
    }
}

#[cfg(test)]
mod tests;
