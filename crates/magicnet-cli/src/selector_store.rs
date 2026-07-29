use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::webui_api::{curl_get_json, curl_put_selection};
use crate::App;

static LOCK_NONCE: AtomicU64 = AtomicU64::new(0);

fn path(app: &App) -> std::path::PathBuf {
    app.moddir.join(".state/sing-box/selector-selections.json")
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn load(app: &App) -> BTreeMap<String, String> {
    let target = path(app);
    let Ok(bytes) = fs::read(&target) else {
        return BTreeMap::new();
    };
    match serde_json::from_slice(&bytes) {
        Ok(values) => values,
        Err(err) => {
            let quarantine = target.with_extension(format!("json.corrupt.{}", now()));
            let _ = fs::rename(&target, quarantine);
            eprintln!("[warn] selector store was corrupt and has been quarantined: {err}");
            BTreeMap::new()
        }
    }
}

pub(crate) fn selected(app: &App, group: &str) -> Option<String> {
    let mut values = load(app);
    values.remove(group)
}

struct StoreLock {
    path: std::path::PathBuf,
    token: String,
    nonce: String,
}

struct LockGuard(fs::File);

impl Drop for LockGuard {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn lock_guard(path: &std::path::Path) -> Result<LockGuard, String> {
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(|err| format!("open selector lock guard: {err}"))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(format!(
            "lock selector guard: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(LockGuard(file))
}

impl Drop for StoreLock {
    fn drop(&mut self) {
        if fs::read_to_string(&self.path)
            .ok()
            .as_deref()
            .map(str::trim)
            == Some(&self.token)
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn process_start(pid: u32) -> Option<String> {
    fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()?
        .split_whitespace()
        .nth(21)
        .map(str::to_string)
}

fn owner_stale(text: &str) -> bool {
    let mut fields = text.trim().split(':');
    let Some(pid) = fields.next().and_then(|value| value.parse::<u32>().ok()) else {
        return true;
    };
    let Some(started) = fields.next() else {
        return true;
    };
    process_start(pid).as_deref() != Some(started)
}

fn lock(app: &App) -> Result<StoreLock, String> {
    let lock = path(app).with_extension("json.lock");
    let guard_path = path(app).with_extension("json.lock.guard");
    let nonce = format!(
        "{}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        LOCK_NONCE.fetch_add(1, Ordering::Relaxed)
    );
    let token = format!(
        "{}:{}:{}",
        std::process::id(),
        process_start(std::process::id()).unwrap_or_default(),
        nonce
    );
    let claim = path(app).with_extension(format!("json.lock.claim.{nonce}"));
    let mut claim_file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&claim)
        .map_err(|err| format!("create selector lock claim: {err}"))?;
    if let Err(err) = writeln!(claim_file, "{token}").and_then(|_| claim_file.sync_all()) {
        let _ = fs::remove_file(&claim);
        return Err(format!("write selector lock claim: {err}"));
    }
    drop(claim_file);
    for _ in 0..40 {
        let guard = match lock_guard(&guard_path) {
            Ok(guard) => guard,
            Err(err) => {
                let _ = fs::remove_file(&claim);
                return Err(err);
            }
        };
        match fs::hard_link(&claim, &lock) {
            Ok(()) => {
                let _ = fs::remove_file(&claim);
                drop(guard);
                return Ok(StoreLock {
                    path: lock,
                    token,
                    nonce,
                });
            }
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
                let observed = fs::read_to_string(&lock).ok();
                if observed.as_deref().is_some_and(owner_stale) {
                    let confirmed = fs::read_to_string(&lock).ok();
                    if confirmed == observed {
                        let _ = fs::remove_file(&lock);
                    }
                }
                drop(guard);
                thread::sleep(Duration::from_millis(25));
            }
            Err(err) => {
                let _ = fs::remove_file(&claim);
                return Err(format!("publish selector lock: {err}"));
            }
        }
    }
    let _ = fs::remove_file(&claim);
    Err("selector store is busy".to_string())
}

pub(crate) fn save(app: &App, group: &str, member: &str) -> Result<(), String> {
    let target = path(app);
    let parent = target.parent().ok_or("selector store has no parent")?;
    fs::create_dir_all(parent).map_err(|err| format!("create selector store: {err}"))?;
    let store_lock = lock(app)?;
    let mut values = load(app);
    values.insert(group.to_string(), member.to_string());
    let tmp = target.with_extension(format!("json.tmp.{}", store_lock.nonce));
    let bytes =
        serde_json::to_vec(&values).map_err(|err| format!("encode selector store: {err}"))?;
    if let Err(err) = fs::write(&tmp, bytes) {
        let _ = fs::remove_file(&tmp);
        return Err(format!("write selector store: {err}"));
    }
    let result = fs::rename(&tmp, &target).map_err(|err| format!("commit selector store: {err}"));
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

pub(crate) fn replay(app: &App) -> Result<usize, String> {
    let values = {
        let _lock = lock(app)?;
        load(app)
    };
    if values.is_empty() {
        return Ok(0);
    }
    let mut proxies = None;
    for _ in 0..20 {
        if let Ok(value) = curl_get_json(app, "/proxies") {
            proxies = Some(value);
            break;
        }
        thread::sleep(Duration::from_millis(250));
    }
    let proxies = proxies.ok_or("selector API not ready")?;
    let groups = proxies
        .get("proxies")
        .and_then(Value::as_object)
        .ok_or("invalid proxies response")?;
    let mut applied = 0;
    let mut failed = 0;
    for (group, member) in values {
        let member = replay_member(&group, &member);
        if valid_member(groups, &group, &member) {
            if let Err(err) = curl_put_selection(app, &group, &json!({"name": member}).to_string())
            {
                failed += 1;
                eprintln!("[warn] persisted selector replay failed for one group: {err}");
            } else {
                applied += 1;
            }
        }
    }
    if failed > 0 {
        eprintln!("[warn] selector replay completed with {failed} failed item(s)");
    }
    Ok(applied)
}

fn replay_member(group: &str, member: &str) -> String {
    if member == "ai-proxy" && matches!(group, "ai-chatgpt" | "ai-gemini" | "ai-grok" | "ai-claude")
    {
        format!("{group}-auto")
    } else {
        member.to_string()
    }
}

fn valid_member(groups: &serde_json::Map<String, Value>, group: &str, member: &str) -> bool {
    groups
        .get(group)
        .and_then(|value| value.get("all"))
        .and_then(Value::as_array)
        .is_some_and(|items| items.iter().any(|item| item.as_str() == Some(member)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app() -> (App, std::path::PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "magicnet-selector-store-{}-{nonce}",
            std::process::id(),
        ));
        let app = App {
            moddir: root.clone(),
            api: "http://127.0.0.1:1".into(),
            log_dir: root.join(".log"),
        };
        (app, root)
    }

    #[test]
    fn corrupted_store_is_empty() {
        let (app, root) = app();
        fs::create_dir_all(root.join(".state/sing-box")).unwrap();
        fs::write(path(&app), b"not-json").unwrap();
        assert!(load(&app).is_empty());
        assert!(fs::read_dir(root.join(".state/sing-box"))
            .unwrap()
            .any(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("selector-selections.json.corrupt.")
            }));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn replay_requires_existing_group_member() {
        let value = json!({"ai-chatgpt": {"all": ["block", "ai-chatgpt-auto"]}});
        let groups = value.as_object().unwrap();
        let migrated = replay_member("ai-chatgpt", "ai-proxy");
        assert!(valid_member(groups, "ai-chatgpt", &migrated));
        assert!(!valid_member(groups, "ai-chatgpt", "missing"));
        assert!(!valid_member(groups, "missing", &migrated));
    }

    #[test]
    fn replay_migrates_legacy_ai_proxy_members() {
        for group in ["ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"] {
            assert_eq!(replay_member(group, "ai-proxy"), format!("{group}-auto"));
        }
        assert_eq!(replay_member("ai-chatgpt", "block"), "block");
        assert_eq!(replay_member("ai-proxy", "legacy-node"), "legacy-node");
    }

    #[test]
    fn stale_lock_recovers_and_concurrent_updates_survive() {
        for _ in 0..20 {
            let (_, root) = app();
            fs::create_dir_all(root.join(".state/sing-box")).unwrap();
            fs::write(
                root.join(".state/sing-box/selector-selections.json.lock"),
                "invalid",
            )
            .unwrap();
            let root_a = root.clone();
            let a = std::thread::spawn(move || {
                let app = App {
                    moddir: root_a.clone(),
                    api: String::new(),
                    log_dir: root_a.join(".log"),
                };
                save(&app, "ai-chatgpt", "ai-proxy").unwrap();
            });
            let root_b = root.clone();
            let b = std::thread::spawn(move || {
                let app = App {
                    moddir: root_b.clone(),
                    api: String::new(),
                    log_dir: root_b.join(".log"),
                };
                save(&app, "ai-gemini", "ai-proxy").unwrap();
            });
            a.join().unwrap();
            b.join().unwrap();
            let values: BTreeMap<String, String> = serde_json::from_slice(
                &fs::read(root.join(".state/sing-box/selector-selections.json")).unwrap(),
            )
            .unwrap();
            assert_eq!(values.len(), 2);
            assert!(!fs::read_dir(root.join(".state/sing-box"))
                .unwrap()
                .any(|entry| {
                    let name = entry.unwrap().file_name();
                    let name = name.to_string_lossy();
                    name.contains(".claim.") || name.contains(".tmp.")
                }));
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn live_owner_never_expires_by_age() {
        let pid = std::process::id();
        let owner = format!("{pid}:{}:0", process_start(pid).unwrap());
        assert!(!owner_stale(&owner));
    }

    #[test]
    fn old_owner_does_not_remove_replacement_lock() {
        let (_, root) = app();
        let lock_path = root.join(".state/sing-box/selector-selections.json.lock");
        fs::create_dir_all(lock_path.parent().unwrap()).unwrap();
        fs::write(&lock_path, "new-owner").unwrap();
        drop(StoreLock {
            path: lock_path.clone(),
            token: "old-owner".into(),
            nonce: "old-nonce".into(),
        });
        assert_eq!(fs::read_to_string(&lock_path).unwrap(), "new-owner");
        fs::remove_dir_all(root).unwrap();
    }
}
