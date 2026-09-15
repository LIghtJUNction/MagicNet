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
