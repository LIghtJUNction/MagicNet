use super::*;
use std::os::unix::fs::OpenOptionsExt;
use std::sync::mpsc;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn blocked_proc_worker_releases_unrelated_descriptors() {
    const NAME: &str =
        "utils::proc_fd_inheritance_tests::blocked_proc_worker_releases_unrelated_descriptors";
    if std::env::var("MAGICNET_PROC_FD_TEST_CHILD").as_deref() != Ok(NAME) {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command.args(["--exact", NAME, "--nocapture"]);
        command.env("MAGICNET_PROC_FD_TEST_CHILD", NAME);
        let result = run_bounded_command(command, Duration::from_secs(20), 8192).unwrap();
        assert!(!result.timed_out, "isolated descriptor test timed out");
        assert!(
            result.status.unwrap().success(),
            "{}{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
        return;
    }

    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::env::temp_dir().join(format!("magicnet-proc-fds-{}-{nonce}", std::process::id()));
    fs::create_dir(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let binary = root.join("executable");
    let mut writer = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&binary)
        .unwrap();
    writer.write_all(b"#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
    let lock_path = root.join("lock");
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&lock_path)
        .unwrap();
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    let fifo = root.join("blocked-proc");
    let fifo_c = cstring_from_os_str(fifo.as_os_str(), "fixture").unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo_c.as_ptr(), 0o600) }, 0);

    let (sender, receiver) = mpsc::channel();
    let reader = std::thread::spawn(move || {
        sender
            .send(unsafe { libc::syscall(libc::SYS_gettid) })
            .unwrap();
        read_proc_file_bounded_with_timeout(&fifo, 32, Duration::from_secs(10))
    });
    let tid = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    // A nonblocking writer succeeds only after the production fork worker
    // opens its FIFO. Hold it empty so the worker stays blocked during checks.
    let guard = loop {
        match fs::OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(root.join("blocked-proc"))
        {
            Ok(file) => break file,
            Err(error)
                if error.raw_os_error() == Some(libc::ENXIO) && Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("worker did not open its fixture: {error}"),
        }
    };
    let children = fs::read_to_string(format!("/proc/self/task/{tid}/children")).unwrap();
    let pids: Vec<_> = children.split_whitespace().collect();
    assert_eq!(pids.len(), 1, "expected the production proc-reader child");
    let inherited: Vec<_> = fs::read_dir(format!("/proc/{}/fd", pids[0]))
        .unwrap()
        .map(|entry| fs::read_link(entry.unwrap().path()).unwrap())
        .collect();
    drop(writer);
    drop(lock);
    let executable_result = Command::new(&binary).status();
    let contender = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&lock_path)
        .unwrap();
    let lock_result = unsafe { libc::flock(contender.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    let lock_error = io::Error::last_os_error();
    // Always finish and join the worker before assertions can panic.
    drop(guard);
    let result = reader.join().unwrap();
    assert_eq!(result.unwrap(), b"");
    assert!(
        !inherited.contains(&binary),
        "proc worker retained an executable writer"
    );
    assert!(
        !inherited.contains(&lock_path),
        "proc worker retained an unrelated lock"
    );
    assert!(
        executable_result.unwrap().success(),
        "closed executable remained busy"
    );
    assert_eq!(
        lock_result, 0,
        "closed parent lock remained owned: {lock_error}"
    );
}
