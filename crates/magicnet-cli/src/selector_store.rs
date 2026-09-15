use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::webui_api::{curl_get_json, curl_put_selection};
use crate::App;

static LOCK_NONCE: AtomicU64 = AtomicU64::new(0);
const STORE_PATH: &str = ".config/magicnet/selector-selections.json";
const LEGACY_STORE_PATH: &str = ".state/sing-box/selector-selections.json";

fn path(app: &App) -> std::path::PathBuf {
    app.moddir.join(STORE_PATH)
}

fn legacy_path(app: &App) -> std::path::PathBuf {
    app.moddir.join(LEGACY_STORE_PATH)
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn load_path(target: &Path) -> Option<BTreeMap<String, String>> {
    let bytes = match fs::read(target) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return None,
        Err(err) => {
            eprintln!("[warn] selector store could not be read: {err}");
            return Some(BTreeMap::new());
        }
    };
    match serde_json::from_slice(&bytes) {
        Ok(values) => Some(values),
        Err(err) => {
            let quarantine = target.with_extension(format!("json.corrupt.{}", now()));
            let _ = fs::rename(target, quarantine);
            eprintln!("[warn] selector store was corrupt and has been quarantined: {err}");
            Some(BTreeMap::new())
        }
    }
}

fn load(app: &App) -> BTreeMap<String, String> {
    load_path(&path(app))
        .or_else(|| load_path(&legacy_path(app)))
        .unwrap_or_default()
}

pub(crate) fn selected(app: &App, group: &str) -> Option<String> {
    let mut values = load(app);
    values.remove(group)
}

struct StoreLock(fs::File);

impl Drop for StoreLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn lock(app: &App) -> Result<StoreLock, String> {
    let lock_path = path(app).with_extension("json.lock");
    let parent = lock_path.parent().ok_or("selector store lock has no parent")?;
    fs::create_dir_all(parent).map_err(|err| format!("create selector store directory: {err}"))?;
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&lock_path)
        .map_err(|err| format!("open selector store lock: {err}"))?;

    for _ in 0..40 {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(StoreLock(file));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::WouldBlock {
            return Err(format!("lock selector store: {error}"));
        }
        thread::sleep(Duration::from_millis(25));
    }
    Err("selector store is busy".to_string())
}

fn cleanup_matching_legacy_store(app: &App, committed: &BTreeMap<String, String>) {
    let legacy = legacy_path(app);
    let Ok(bytes) = fs::read(&legacy) else {
        return;
    };
    let Ok(values) = serde_json::from_slice::<BTreeMap<String, String>>(&bytes) else {
        return;
    };
    let fully_migrated = values
        .iter()
        .all(|(group, member)| committed.get(group) == Some(member));
    if fully_migrated {
        let _ = fs::remove_file(legacy);
    }
}

pub(crate) fn save(app: &App, group: &str, member: &str) -> Result<(), String> {
    let target = path(app);
    let parent = target.parent().ok_or("selector store has no parent")?;
    fs::create_dir_all(parent).map_err(|err| format!("create selector store: {err}"))?;
    let _store_lock = lock(app)?;
    let mut values = load(app);
    values.insert(group.to_string(), member.to_string());
    let nonce = format!(
        "{}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        LOCK_NONCE.fetch_add(1, Ordering::Relaxed)
    );
    let tmp = target.with_extension(format!("json.tmp.{nonce}"));
    let bytes =
        serde_json::to_vec(&values).map_err(|err| format!("encode selector store: {err}"))?;
    let write_result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()
    })();
    if let Err(err) = write_result {
        let _ = fs::remove_file(&tmp);
        return Err(format!("write selector store: {err}"));
    }
    let result = fs::rename(&tmp, &target).map_err(|err| format!("commit selector store: {err}"));
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    } else {
        cleanup_matching_legacy_store(app, &values);
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
        fs::create_dir_all(root.join(".config/magicnet")).unwrap();
        fs::write(path(&app), b"not-json").unwrap();
        assert!(load(&app).is_empty());
        assert!(fs::read_dir(root.join(".config/magicnet"))
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
    fn legacy_state_store_is_read_and_migrated_on_save() {
        let (app, root) = app();
        fs::create_dir_all(root.join(".state/sing-box")).unwrap();
        fs::write(
            legacy_path(&app),
            br#"{"ai-chatgpt":"ai-proxy","proxy":"old-node"}"#,
        )
        .unwrap();
        assert_eq!(selected(&app, "proxy").as_deref(), Some("old-node"));
        save(&app, "ai-gemini", "ai-proxy").unwrap();
        let values: BTreeMap<String, String> =
            serde_json::from_slice(&fs::read(path(&app)).unwrap()).unwrap();
        assert_eq!(values.get("proxy").map(String::as_str), Some("old-node"));
        assert_eq!(
            values.get("ai-gemini").map(String::as_str),
            Some("ai-proxy")
        );
        assert!(!legacy_path(&app).exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_store_is_kept_if_an_unmigrated_value_appears() {
        let (app, root) = app();
        fs::create_dir_all(root.join(".state/sing-box")).unwrap();
        let mut committed = BTreeMap::new();
        committed.insert("proxy".to_string(), "new-node".to_string());
        fs::write(legacy_path(&app), br#"{"proxy":"old-node","late":"node"}"#).unwrap();
        cleanup_matching_legacy_store(&app, &committed);
        assert!(legacy_path(&app).exists());
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
    fn flock_serializes_concurrent_updates_without_lost_writes() {
        for _ in 0..20 {
            let (_, root) = app();
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
            let values: BTreeMap<String, String> =
                serde_json::from_slice(&fs::read(root.join(STORE_PATH)).unwrap()).unwrap();
            assert_eq!(values.len(), 2);
            assert!(!fs::read_dir(root.join(".config/magicnet"))
                .unwrap()
                .any(|entry| entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .contains(".tmp.")));
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn dropped_flock_can_be_reacquired() {
        let (app, root) = app();
        drop(lock(&app).unwrap());
        drop(lock(&app).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
}
