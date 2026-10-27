use std::fs;
use std::os::fd::AsRawFd;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[test]
fn config_apply_exits_instead_of_waiting_forever_for_a_live_lock() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "magicnet-apply-deadline-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir_all(root.join(".state")).unwrap();
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join(".state/config-apply.lock"))
        .unwrap();
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
        .args(["config", "apply"])
        .env("MODDIR", &root)
        .env("MODPATH", &root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            drop(lock);
            let _ = fs::remove_dir_all(&root);
            panic!("config apply ignored its lock deadline");
        }
        thread::sleep(Duration::from_millis(20));
    }
    let output = child.wait_with_output().unwrap();
    drop(lock);
    fs::remove_dir_all(root).unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("config apply is still busy"), "{stderr}");
}

#[test]
fn contended_hotspot_reconcile_does_not_run_hooks_or_publish_state() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is after the epoch")
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "magicnet-hotspot-skip-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir_all(root.join(".state/machines")).expect("create state fixture");
    let state_path = root.join(".state/machines/hotspot.state");
    let previous = "schema=1\nstate=pending\n";
    fs::write(&state_path, previous).expect("write pending state");
    let lock = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join(".state/config-apply.lock"))
        .expect("open lock");
    // SAFETY: lock owns this descriptor for the lifetime of the child.
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
        .args(["hotspot", "reconcile"])
        .env("MODDIR", &root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run periodic reconcile through the real dispatcher");
    // Keep the lock held until the child exits; the watchdog tolerates process
    // startup and scheduling delays without accepting a wait for lock release.
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait().expect("poll periodic reconcile").is_some() {
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            drop(lock);
            let _ = fs::remove_dir_all(&root);
            panic!("contended periodic reconcile did not exit while the lock was held");
        }
        thread::sleep(Duration::from_millis(20));
    }
    let output = child
        .wait_with_output()
        .expect("collect periodic reconcile");
    assert!(output.status.success(), "{output:?}");
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("reconcile skipped"));
    assert_eq!(
        fs::read_to_string(state_path).expect("read state"),
        previous
    );
    assert_eq!(
        fs::read_dir(root.join(".state/machines"))
            .expect("list machines")
            .count(),
        1
    );
    drop(lock);
    fs::remove_dir_all(root).expect("remove fixture");
}
