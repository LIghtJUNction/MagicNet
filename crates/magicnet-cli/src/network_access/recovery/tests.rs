use super::*;
use std::os::unix::fs::symlink;

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("magicnet-access-{}-{nonce}", std::process::id()));
        DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn record(phase: &'static str) -> Record {
    Record {
        policy: Policy {
            provider: "oplus",
            uid: 110007,
            value: 4,
            packages: vec!["app.one".to_string(), "app.shared".to_string()],
            writable: true,
        },
        phase,
    }
}

#[test]
fn explicit_repair_is_idempotent_and_never_reclears_a_reapplied_policy() {
    assert_eq!(decide(&record("new"), 4, false), Ok(Decision::Write));
    assert_eq!(decide(&record("applied"), 0, false), Ok(Decision::Noop));
    assert_eq!(
        decide(&record("applied"), 4, false),
        Err("restriction_reapplied")
    );
    assert_eq!(decide(&record("applied"), 2, false), Err("policy_conflict"));
    assert_eq!(
        decide(&record("rolled_back"), 4, false),
        Ok(Decision::Write)
    );
}

#[test]
fn uncertain_write_requires_reconciliation_or_explicit_rollback() {
    assert_eq!(
        decide(&record("prepared"), 0, false),
        Ok(Decision::Complete)
    );
    assert_eq!(
        decide(&record("prepared"), 4, false),
        Err("interrupted_change")
    );
    assert_eq!(decide(&record("prepared"), 4, true), Ok(Decision::Complete));
    assert_eq!(decide(&record("prepared"), 0, true), Ok(Decision::Write));
    assert_eq!(
        decide(&record("rollback_prepared"), 0, false),
        Err("rollback_required")
    );
    assert_eq!(
        decide(&record("rollback_prepared"), 4, true),
        Ok(Decision::Complete)
    );
}

#[test]
fn rollback_only_restores_the_original_when_our_value_is_still_present() {
    assert_eq!(decide(&record("applied"), 0, true), Ok(Decision::Write));
    assert_eq!(decide(&record("applied"), 2, true), Err("policy_conflict"));
    assert_eq!(decide(&record("rolled_back"), 4, true), Ok(Decision::Noop));
    assert_eq!(
        decide(&record("rolled_back"), 0, true),
        Err("policy_conflict")
    );
    let mut android = record("applied");
    android.policy.provider = "android";
    android.policy.value = 5;
    assert_eq!(decide(&android, 4, true), Ok(Decision::Write));
    assert_eq!(decide(&android, 0, true), Err("policy_conflict"));
}

#[test]
fn journal_is_bound_to_provider_policy_and_complete_shared_identity() {
    let saved = record("prepared");
    let token = saved.policy.candidate();
    assert!(decode(&token, &saved.encode()).is_ok());
    for key in ["uid", "before", "provider", "packages", "phase", "schema"] {
        let mut value = saved.encode();
        value[key] = Value::Null;
        assert!(decode(&token, &value).is_err(), "accepted missing {key}");
    }
    let mut value = saved.encode();
    value["packages"] = json!(["app.one"]);
    assert!(decode(&token, &value).is_err());
    let mut value = saved.encode();
    value["packages"] = json!(["app.shared", "app.one"]);
    assert!(decode(&token, &value).is_err());
    assert!(!valid_token("../outside"));
    assert!(!valid_token(&"G".repeat(64)));
    assert!(!valid_token(&"0".repeat(65)));
}

#[test]
fn inspection_does_not_create_state_and_private_records_are_durable() {
    let root = Temp::new();
    assert!(directory(&root.0, false).unwrap().is_none());
    assert!(!root.0.join(".state").exists());
    let dir = directory(&root.0, true).unwrap().unwrap();
    let mut saved = record("prepared");
    save(&dir, &saved).unwrap();
    let token = saved.policy.candidate();
    let persisted = read(&dir, &token).unwrap().unwrap();
    assert_eq!(persisted.phase, "prepared");
    assert_eq!(persisted.policy.packages, saved.policy.packages);
    assert!(!persisted.policy.writable);
    saved.phase = "applied";
    save(&dir, &saved).unwrap();
    assert_eq!(read(&dir, &token).unwrap().unwrap().phase, "applied");
    assert_eq!(scan(&dir).unwrap().len(), 1);
    assert_eq!(
        fs::metadata(dir.join(format!("{token}.json")))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert!(saved.public().get("uid").is_none());
    assert!(result(&saved, true).get("packages").is_none());
    assert_eq!(result(&saved, true)["effective_system_dns"], "not_probed");
}

#[test]
fn recovery_lock_serializes_writers_without_deleting_the_lock_file() {
    let root = Temp::new();
    let dir = directory(&root.0, true).unwrap().unwrap();
    let guard = lock(&dir).unwrap();
    assert!(matches!(lock(&dir), Err("recovery_busy")));
    drop(guard);
    assert!(dir.join(".lock").is_file());
    assert!(lock(&dir).is_ok());
}

#[test]
fn symlink_world_writable_and_hardlinked_state_are_rejected() {
    let root = Temp::new();
    let outside = Temp::new();
    symlink(&outside.0, root.0.join(".state")).unwrap();
    assert!(matches!(directory(&root.0, false), Err("recovery_unsafe")));
    fs::remove_file(root.0.join(".state")).unwrap();
    let dir = directory(&root.0, true).unwrap().unwrap();
    let saved = record("prepared");
    save(&dir, &saved).unwrap();
    let token = saved.policy.candidate();
    let path = dir.join(format!("{token}.json"));
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(read(&dir, &token).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    fs::hard_link(&path, outside.0.join("hardlink")).unwrap();
    assert!(read(&dir, &token).is_err());
    fs::remove_file(outside.0.join("hardlink")).unwrap();
    fs::remove_file(&path).unwrap();
    symlink(outside.0.join("missing"), &path).unwrap();
    assert!(read(&dir, &token).is_err());
}

#[test]
fn corrupt_and_oversized_journals_are_not_interpreted_as_absent() {
    let root = Temp::new();
    let dir = directory(&root.0, true).unwrap().unwrap();
    let token = record("prepared").policy.candidate();
    let path = dir.join(format!("{token}.json"));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .unwrap();
    file.write_all(b"{").unwrap();
    assert!(matches!(read(&dir, &token), Err("invalid_recovery_record")));
    file.set_len(MAX_RECORD + 1).unwrap();
    assert!(read(&dir, &token).is_err());
    assert!(read(&dir, "invalid").is_err());
}
