// Unit tests included from the matching src module.

use std::ffi::CString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt, PermissionsExt};
use std::process::Command;

use super::*;
use crate::test_support::temp_app;

fn test_proc_stat(pid: u32, state: char, start: u64) -> String {
    let filler = (1..=18).map(|_| "1").collect::<Vec<_>>().join(" ");
    format!("{pid} (subscription owner) {state} {filler} {start} 0\n")
}

#[test]
fn stale_update_lock_is_not_stolen_when_proc_identity_is_indeterminate() {
    let app = temp_app();
    let lock = app.moddir.join(".state/sing-box/subscription-update.lock");
    fs::create_dir_all(&lock).expect("create subscription lock");
    fs::write(lock.join("owner"), "4242:777:subscription-update-v1\n")
        .expect("write subscription lock owner");
    let proc_root = app.moddir.join("test-proc");
    let proc_dir = proc_root.join("4242");
    fs::create_dir_all(&proc_dir).expect("create proc fixture");
    let stat = proc_dir.join("stat");
    let stat_c = CString::new(stat.as_os_str().as_bytes()).expect("stat path contains NUL");
    assert_eq!(unsafe { libc::mkfifo(stat_c.as_ptr(), 0o600) }, 0);

    cleanup_stale_update_lock_from_proc(&app, &proc_root);
    assert!(
        lock.join("owner").is_file(),
        "indeterminate owner was stolen"
    );

    fs::remove_file(&stat).expect("remove blocking stat FIFO");
    fs::write(&stat, test_proc_stat(4242, 'S', 777)).expect("write live proc stat");
    cleanup_stale_update_lock_from_proc(&app, &proc_root);
    assert!(lock.join("owner").is_file(), "live owner was stolen");

    fs::write(&stat, test_proc_stat(4242, 'S', 999)).expect("write reused proc stat");
    cleanup_stale_update_lock_from_proc(&app, &proc_root);
    assert!(!lock.exists(), "PID reuse did not release stale lock");
}

#[test]
fn subscription_metadata_guard_unlocks_before_inherited_descriptor_closes() {
    let app = temp_app();
    let lock = app.moddir.join(".state/sing-box/subscription-update.lock");
    let guard = SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).unwrap();
    // A dup shares the open-file description exactly as a concurrent fork
    // does, even when both descriptors have CLOEXEC set.
    let inherited = guard._file.try_clone().unwrap();
    assert!(SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).is_err());
    drop(guard);
    let successor = SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO)
        .expect("a completed metadata operation must unlock despite inherited descriptors");
    drop(inherited);
    assert!(SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).is_err());
    drop(successor);
    assert!(SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).is_ok());
}

#[test]
fn subscription_metadata_guard_serializes_rust_and_shell_writers() {
    let app = temp_app();
    let lock = app.moddir.join(".state/sing-box/subscription-update.lock");
    let guard_path = lock.with_file_name("subscription-update.lock.guard");
    let guard = SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).unwrap();
    assert_ne!(
        unsafe { libc::fcntl(guard._file.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
        0,
        "metadata flock must not leak into runtime children"
    );
    assert_eq!(fs::metadata(&guard_path).unwrap().mode() & 0o777, 0o600);
    assert!(SubscriptionSourceGuard::acquire(&app).is_err());
    assert!(!lock.exists(), "a blocked writer published its directory");

    fs::create_dir(&lock).unwrap();
    let owner = "999999:1:stale\n";
    fs::write(lock.join("owner"), owner).unwrap();
    cleanup_stale_update_lock_from_proc(&app, &app.moddir.join("missing-proc"));
    assert_eq!(fs::read_to_string(lock.join("owner")).unwrap(), owner);

    let shell = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../src/MagicNet/lib/magicnet/singbox_subscribe/update.sh");
    let result = Command::new("bash")
        .arg("-c")
        .arg(
            "error() { :; }; . \"$1\"; \
             magicnet_singbox_update_lock_active && \
             ! magicnet_singbox_update_lock_acquire",
        )
        .arg("subscription-guard-test")
        .arg(shell)
        .env("MODDIR", &app.moddir)
        .status()
        .unwrap();
    assert!(
        result.success(),
        "shell did not honor the Rust metadata flock"
    );
    assert_eq!(fs::read_to_string(lock.join("owner")).unwrap(), owner);
    let guard_inode = fs::metadata(&guard_path).unwrap().ino();
    drop(guard);
    let source = SubscriptionSourceGuard::acquire(&app).unwrap();
    drop(source);
    assert!(!lock.exists());
    assert_eq!(fs::metadata(guard_path).unwrap().ino(), guard_inode);
}

#[test]
fn subscription_lock_preserves_unknown_or_nonregular_owners() {
    let app = temp_app();
    let lock = app.moddir.join(".state/sing-box/subscription-update.lock");
    let owner = lock.join("owner");
    fs::create_dir_all(&lock).unwrap();
    let proc_root = app.moddir.join("test-proc");
    for malformed in [
        "broken",
        "+4242:777:nonce",
        "04242:777:nonce",
        "0:777:nonce",
        "4242:not-a-time:nonce",
        "4242:777:",
        "4242:777:nonce:extra",
    ] {
        fs::write(&owner, malformed).unwrap();
        cleanup_stale_update_lock_from_proc(&app, &proc_root);
        assert_eq!(fs::read_to_string(&owner).unwrap(), malformed);
        assert!(SubscriptionSourceGuard::acquire(&app).is_err());
    }
    fs::write(&owner, "x".repeat(130)).unwrap();
    cleanup_stale_update_lock_from_proc(&app, &proc_root);
    assert!(owner.exists());
    fs::remove_file(&owner).unwrap();

    let outside = app.moddir.join("outside-owner");
    fs::write(&outside, "999999:1:stale").unwrap();
    symlink(&outside, &owner).unwrap();
    cleanup_stale_update_lock_from_proc(&app, &proc_root);
    assert!(owner.is_symlink());
    fs::remove_file(&owner).unwrap();
    let owner_c = CString::new(owner.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(owner_c.as_ptr(), 0o600) }, 0);
    let started = Instant::now();
    cleanup_stale_update_lock_from_proc(&app, &proc_root);
    assert!(SubscriptionSourceGuard::acquire(&app).is_err());
    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(fs::symlink_metadata(&owner).unwrap().file_type().is_fifo());
    fs::remove_file(&owner).unwrap();

    fs::create_dir_all(proc_root.join("4242")).unwrap();
    for state in ['T', 't'] {
        fs::write(&owner, "4242:777:paused\n").unwrap();
        fs::write(
            proc_root.join("4242/stat"),
            test_proc_stat(4242, state, 777),
        )
        .unwrap();
        cleanup_stale_update_lock_from_proc(&app, &proc_root);
        assert!(owner.exists(), "a paused owner was stolen");
    }
}

#[test]
fn subscription_release_waits_for_metadata_and_preserves_replacement_owner() {
    let app = temp_app();
    let source = SubscriptionSourceGuard::acquire(&app).unwrap();
    let lock = source.directory.clone();
    let metadata = SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).unwrap();
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    let release = std::thread::spawn(move || {
        drop(source);
        finished_tx.send(()).unwrap();
    });
    assert!(finished_rx.recv_timeout(Duration::from_millis(75)).is_err());
    assert!(lock.join("owner").exists());
    fs::write(lock.join("owner"), "999999:1:replacement\n").unwrap();
    drop(metadata);
    finished_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    release.join().unwrap();
    assert_eq!(
        fs::read_to_string(lock.join("owner")).unwrap(),
        "999999:1:replacement\n"
    );
}

#[test]
fn subscription_metadata_guard_rejects_nonregular_paths_without_blocking() {
    let app = temp_app();
    let lock = app.moddir.join(".state/sing-box/subscription-update.lock");
    fs::create_dir_all(lock.parent().unwrap()).unwrap();
    let guard = lock.with_file_name("subscription-update.lock.guard");
    let outside = app.moddir.join("outside-guard");
    fs::write(&outside, "unchanged").unwrap();
    symlink(&outside, &guard).unwrap();
    assert!(SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).is_err());
    assert_eq!(fs::read_to_string(&outside).unwrap(), "unchanged");
    fs::remove_file(&guard).unwrap();
    let guard_c = CString::new(guard.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(guard_c.as_ptr(), 0o600) }, 0);
    let started = Instant::now();
    assert!(SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).is_err());
    assert!(started.elapsed() < Duration::from_secs(1));
    fs::remove_file(&guard).unwrap();
    fs::create_dir(&guard).unwrap();
    assert!(SubscriptionMetadataGuard::acquire(&lock, Duration::ZERO).is_err());
}

#[test]
fn subscription_url_validation_requires_public_https_without_credentials() {
    validate_subscription_url("https://example.com/sub?profile=abc").unwrap();
    validate_subscription_url("HTTPS://example.com/sub").unwrap();
    validate_subscription_url("HtTpS://example.com/sub").unwrap();
    validate_subscription_url("https://example.com:8443/sub").unwrap();
    validate_subscription_url("https://1.1.1.1/sub").unwrap();
    validate_subscription_url("https://8.8.8.8:8443/sub").unwrap();
    validate_subscription_url("https://[2606:4700:4700::1111]/sub").unwrap();
    assert!(validate_subscription_url("http://example.com/sub").is_err());
    assert!(validate_subscription_url("https://user:secret@example.com/sub").is_err());
    assert!(validate_subscription_url("https://127.0.0.1:8080/sub").is_err());
    assert!(validate_subscription_url("https://[::1]/sub").is_err());
    assert!(validate_subscription_url("https://1.1/sub").is_err());
    assert!(validate_subscription_url("ftp://example.com/sub").is_err());
    assert!(validate_subscription_url("https://example.com/a b").is_err());
}

#[test]
fn subscription_host_validation_accepts_public_ip_literals_only() {
    for host in ["1.1.1.1", "2606:4700:4700::1111", "example.com"] {
        validate_subscription_host(host).unwrap();
    }
    for host in ["127.0.0.1", "::1", "192.168.1.1", "1.1", "0x7f000001"] {
        assert!(
            validate_subscription_host(host).is_err(),
            "{host} must be rejected"
        );
    }
}

#[test]
fn subscription_authority_rejects_malformed_ports_and_ipv6_authorities() {
    assert_eq!(
        parse_subscription_port(":8443").expect("valid explicit port"),
        8443
    );
    for url in [
        "https://example.com:0/sub",
        "https://example.com:not-a-port/sub",
        "https://[::1]8443/sub",
        "https://[not-an-ip]/sub",
        "https://example.com:443:1/sub",
    ] {
        assert!(
            parse_subscription_authority(url).is_err(),
            "{url} must fail"
        );
    }
}

#[test]
fn subscription_address_policy_rejects_private_and_special_use_addresses() {
    for address in [
        "0.0.0.0",
        "10.0.0.1",
        "127.0.0.1",
        "169.254.1.1",
        "172.16.0.1",
        "192.0.0.1",
        "192.0.2.1",
        "192.168.0.1",
        "192.31.196.1",
        "192.52.193.1",
        "192.88.99.1",
        "192.175.48.1",
        "198.18.0.1",
        "198.51.100.1",
        "203.0.113.1",
        "224.0.0.1",
        "::",
        "::1",
        "fc00::1",
        "fe80::1",
        "100::1",
        "64:ff9b::1",
        "2001:0::1",
        "2001:2::1",
        "2001:10::1",
        "2001:20::1",
        "2001:db8::1",
        "ff02::1",
        "::ffff:127.0.0.1",
        "::ffff:192.0.2.1",
    ] {
        let address = IpAddr::from_str(address).expect("valid fixture address");
        assert!(
            !is_public_subscription_address(address),
            "{address} must be rejected"
        );
    }
    for address in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] {
        let address = IpAddr::from_str(address).expect("valid fixture address");
        assert!(
            is_public_subscription_address(address),
            "{address} must remain permitted"
        );
    }
}

#[test]
fn resolved_subscription_addresses_fail_closed() {
    let public = HashSet::from([
        IpAddr::from_str("1.1.1.1").unwrap(),
        IpAddr::from_str("2606:4700:4700::1111").unwrap(),
    ]);
    validate_resolved_subscription_addresses(&public).unwrap();

    let mixed = HashSet::from([
        IpAddr::from_str("1.1.1.1").unwrap(),
        IpAddr::from_str("127.0.0.1").unwrap(),
    ]);
    assert!(validate_resolved_subscription_addresses(&mixed).is_err());
    assert!(validate_resolved_subscription_addresses(&HashSet::new()).is_err());
}

#[test]
fn https_download_pins_all_addresses_in_one_curl_entry() {
    let authority =
        parse_subscription_authority("https://downloads.example.invalid:8443/list").unwrap();
    for (addresses, expected) in [
        (vec!["1.1.1.1"], "downloads.example.invalid:8443:1.1.1.1"),
        (
            vec!["8.8.8.8", "1.1.1.1"],
            "downloads.example.invalid:8443:1.1.1.1,8.8.8.8",
        ),
        (
            vec!["2606:4700:4700::1111", "2001:4860:4860::8888"],
            "downloads.example.invalid:8443:[2001:4860:4860::8888],[2606:4700:4700::1111]",
        ),
        (
            vec!["2606:4700:4700::1111", "1.1.1.1", "8.8.8.8", "1.1.1.1"],
            "downloads.example.invalid:8443:1.1.1.1,[2606:4700:4700::1111],8.8.8.8",
        ),
    ] {
        let resolved = addresses
            .iter()
            .map(|address| IpAddr::from_str(address).unwrap())
            .collect();
        let mut command = Command::new("curl");
        pin_https_download_addresses(&mut command, &authority, resolved).unwrap();
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            vec![OsStr::new("--resolve"), OsStr::new(expected)],
            "all addresses must share one curl DNS-cache entry: {addresses:?}"
        );
    }
}

#[test]
fn https_download_rejects_an_empty_or_partly_private_address_set_before_pinning() {
    let authority = parse_subscription_authority("https://downloads.example.invalid/list").unwrap();
    for addresses in [
        vec![],
        vec!["1.1.1.1", "127.0.0.1"],
        vec!["2606:4700:4700::1111", "::1"],
    ] {
        let resolved = addresses
            .iter()
            .map(|address| IpAddr::from_str(address).unwrap())
            .collect();
        let mut command = Command::new("curl");
        assert!(pin_https_download_addresses(&mut command, &authority, resolved).is_err());
        assert_eq!(command.get_args().count(), 0);
    }
}

#[test]
fn https_download_public_ip_literals_need_no_curl_dns_override() {
    for url in [
        "https://1.1.1.1/list",
        "https://8.8.8.8:8443/list",
        "https://[2606:4700:4700::1111]/list",
        "https://[2001:4860:4860::8888]:8443/list",
    ] {
        validate_subscription_url(url).unwrap();
        let authority = parse_subscription_authority(url).unwrap();
        let resolved = HashSet::from([IpAddr::from_str(authority.host).unwrap()]);
        let mut command = Command::new("curl");
        pin_https_download_addresses(&mut command, &authority, resolved).unwrap();
        assert_eq!(command.get_args().count(), 0, "literal URL: {url}");
    }
}

#[test]
fn https_download_private_ip_literals_are_rejected_before_skipping_pinning() {
    for (host, url) in [
        ("127.0.0.1", "https://127.0.0.1/list"),
        ("192.168.1.1", "https://192.168.1.1/list"),
        ("::1", "https://[::1]/list"),
        ("fc00::1", "https://[fc00::1]/list"),
    ] {
        assert!(validate_subscription_url(url).is_err());
        let authority = SubscriptionAuthority { host, port: 443 };
        let resolved = HashSet::from([IpAddr::from_str(host).unwrap()]);
        let mut command = Command::new("curl");
        assert!(pin_https_download_addresses(&mut command, &authority, resolved).is_err());
        assert_eq!(command.get_args().count(), 0);
    }
}

#[test]
fn subscription_user_agent_is_validated_and_persisted() {
    let app = temp_app();
    let value = "sing-box/1.12.0 (Android)";
    let encoded = crate::encode_base64(value.as_bytes());

    sub_user_agent(
        &app,
        &[
            "sub".to_string(),
            "user-agent".to_string(),
            "set".to_string(),
            encoded,
        ],
    )
    .expect("set subscription User-Agent");

    assert_eq!(subscription_user_agent(&app), value);
    assert_eq!(
        fs::read_to_string(app.moddir.join(SUBSCRIPTION_USER_AGENT_PATH)).unwrap(),
        format!("{value}\n")
    );

    sub_user_agent(
        &app,
        &[
            "sub".to_string(),
            "user-agent".to_string(),
            "clear".to_string(),
        ],
    )
    .expect("clear subscription User-Agent");
    assert_eq!(subscription_user_agent(&app), "");
}

#[test]
fn subscription_filters_are_normalized_deduplicated_and_persisted() {
    let app = temp_app();
    let encoded = crate::encode_base64("免费\nFREE\nfree\n香港\n".as_bytes());

    sub_filter(
        &app,
        &[
            "sub".to_string(),
            "filter".to_string(),
            "set".to_string(),
            encoded,
        ],
    )
    .unwrap();

    assert_eq!(
        fs::read_to_string(app.moddir.join(SUBSCRIPTION_FILTER_PATH)).unwrap(),
        "免费\nFREE\n香港\n"
    );
    assert_eq!(subscription_filters(&app), ["免费", "FREE", "香港"]);
}

#[test]
fn subscription_filters_reject_oversized_or_excessive_entries() {
    assert!(normalize_subscription_filter_text(&"x".repeat(65)).is_err());
    let too_many = (0..=MAX_SUBSCRIPTION_FILTERS)
        .map(|index| format!("filter-{index}"))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(normalize_subscription_filter_text(&too_many).is_err());
}

#[test]
fn subscription_user_agent_rejects_controls_and_oversized_values() {
    assert!(validate_subscription_user_agent("sing-box\ninjected").is_err());
    assert!(validate_subscription_user_agent(&"x".repeat(257)).is_err());
    assert!(validate_subscription_user_agent("").is_err());
}

#[test]
fn set_file_dedupes_and_trims_singbox_subscription_lines() {
    let payload = crate::encode_base64(
        b"\nhttps://example.com/a\nhttps://example.com/a\n  https://example.com/b  \n",
    );
    let text = normalized_subscription_payload(&payload).unwrap();
    assert_eq!(text, "https://example.com/a\nhttps://example.com/b\n");
}

#[test]
fn webui_raw_subscription_text_uses_the_same_normalization_rules() {
    let text = normalized_subscription_text(
        "\nhttps://example.com/a\nhttps://example.com/a\n  https://example.com/b  \n",
    )
    .expect("normalize WebUI payload text");

    assert_eq!(text, "https://example.com/a\nhttps://example.com/b\n");
    assert!(normalized_subscription_text("vmess://not-a-subscription\n").is_err());
    assert!(normalized_subscription_text("\n  \n").is_err());
}

#[test]
fn set_file_rejects_non_http_subscription_lines() {
    let app = temp_app();
    let payload = crate::encode_base64(b"vmess://not-a-subscription-file-entry\n");

    let err = sub_set_file(
        &app,
        &[
            "sub".to_string(),
            "set-file".to_string(),
            "sing-box".to_string(),
            payload,
        ],
    )
    .unwrap_err();

    assert!(err.contains("must use HTTPS"), "{err}");
}

#[test]
fn set_file_rejects_more_than_five_singbox_subscription_lines() {
    let app = temp_app();
    let payload = crate::encode_base64(
            b"https://example.com/1\nhttps://example.com/2\nhttps://example.com/3\nhttps://example.com/4\nhttps://example.com/5\nhttps://example.com/6\n",
        );

    let err = sub_set_file(
        &app,
        &[
            "sub".to_string(),
            "set-file".to_string(),
            "sing-box".to_string(),
            payload,
        ],
    )
    .unwrap_err();

    assert!(err.contains("at most 5 entries"), "{err}");
}

#[test]
fn candidate_activation_failure_never_writes_the_active_url() {
    let app = temp_app();
    let directory = app.moddir.join(".tmp/subscription-candidates");
    let error = with_subscription_candidate(&app, "https://example.com/sub\n", |candidate_fd| {
        assert_eq!(
            fs::read_to_string(format!("/proc/self/fd/{candidate_fd}")).unwrap(),
            "https://example.com/sub\n"
        );
        assert!(
            fs::read_dir(&directory)
                .expect("read anonymous candidate directory")
                .next()
                .is_none(),
            "candidate must be unlinked before activation"
        );
        Err::<(), _>("activation rejected".to_string())
    })
    .unwrap_err();

    assert_eq!(error, "activation rejected");
    assert!(!sub_target_file(&app, "sing-box").exists());
    assert!(fs::read_dir(&directory)
        .expect("read anonymous candidate directory")
        .next()
        .is_none());
}

#[test]
fn committed_update_with_selector_replay_failure_is_success_with_warning() {
    let outcome =
        subscription_update_outcome(Ok(()), Err("fixture selector replay failure".to_string()))
            .unwrap();

    assert_eq!(outcome, Some(SELECTOR_REPLAY_WARNING));
}

#[test]
fn failed_update_stays_failed_even_when_replay_would_succeed() {
    let error = subscription_update_outcome(Err("update failed".to_string()), Ok(())).unwrap_err();

    assert_eq!(error, "update failed");
}

#[test]
fn anonymous_subscription_candidate_is_private_and_readable_by_a_child() {
    let app = temp_app();
    let candidate = write_subscription_candidate(&app, "https://example.com/private\n").unwrap();
    let metadata = candidate.file.metadata().expect("stat anonymous candidate");
    let directory = app.moddir.join(".tmp/subscription-candidates");

    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    assert_eq!(
        metadata.nlink(),
        0,
        "candidate must be unlinked before spawn"
    );
    assert_eq!(
        fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert!(
        fs::read_dir(&directory)
            .expect("read anonymous candidate directory")
            .next()
            .is_none(),
        "no lexical candidate file may remain"
    );

    let fd_path = format!("/proc/self/fd/{}", candidate.fd());
    let output = Command::new("sh")
        .arg("-c")
        .arg("cat \"$1\"")
        .arg("sh")
        .arg(&fd_path)
        .output()
        .expect("spawn child reader");

    assert!(output.status.success(), "child reader failed: {output:?}");
    assert_eq!(output.stdout.as_slice(), b"https://example.com/private\n");
}

#[test]
fn candidate_temp_root_symlink_is_rejected_without_creating_outside_files() {
    let app = temp_app();
    let outside = app.moddir.join("outside");
    fs::create_dir_all(&app.moddir).expect("create module directory");
    fs::create_dir_all(&outside).expect("create outside directory");
    symlink(&outside, app.moddir.join(".tmp")).expect("create temporary-root symlink");

    assert!(write_subscription_candidate(&app, "https://example.com/sub\n").is_err());
    assert!(
        !outside.join("subscription-candidates").exists(),
        "candidate setup must not traverse a .tmp symlink"
    );
}

#[test]
fn candidate_temp_directory_symlink_is_rejected_without_creating_outside_files() {
    let app = temp_app();
    let outside = app.moddir.join("outside");
    let parent = app.moddir.join(".tmp");
    fs::create_dir_all(&parent).expect("create candidate parent");
    fs::create_dir_all(&outside).expect("create outside directory");
    symlink(&outside, parent.join("subscription-candidates"))
        .expect("create candidate directory symlink");

    assert!(write_subscription_candidate(&app, "https://example.com/sub\n").is_err());
    assert!(
        fs::read_dir(&outside)
            .expect("read outside directory")
            .next()
            .is_none(),
        "candidate setup must not traverse the candidate directory symlink"
    );
}

#[test]
fn clear_sources_is_repeatable_and_preserves_the_active_configuration() {
    let app = temp_app();
    let dir = app.moddir.join(".config/sing-box");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("subscription.url"),
        "https://example.com/private\n",
    )
    .unwrap();
    fs::write(dir.join("subscription.local"), "proxies: []\n").unwrap();
    fs::write(dir.join("config.json"), "{\"keep\":true}").unwrap();
    for _ in 0..3 {
        sub_clear(&app).unwrap();
        assert_eq!(
            fs::read_to_string(dir.join("subscription.url")).unwrap(),
            ""
        );
        assert_eq!(
            fs::read_to_string(dir.join("subscription.local")).unwrap(),
            ""
        );
        assert_eq!(
            fs::read_to_string(dir.join("config.json")).unwrap(),
            "{\"keep\":true}"
        );
        assert!(!app
            .moddir
            .join(".state/sing-box/subscription-update.lock")
            .exists());
    }
}

#[test]
fn clear_cannot_race_a_live_subscription_writer_or_recovery() {
    let app = temp_app();
    let dir = app.moddir.join(".config/sing-box");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("subscription.url"), "original").unwrap();
    let guard = SubscriptionSourceGuard::acquire(&app).unwrap();
    assert!(sub_clear(&app).is_err());
    assert_eq!(
        fs::read_to_string(dir.join("subscription.url")).unwrap(),
        "original"
    );
    drop(guard);
    fs::create_dir_all(app.moddir.join(".state/sing-box/subscription-transaction")).unwrap();
    assert!(sub_clear(&app).is_err());
    assert_eq!(
        fs::read_to_string(dir.join("subscription.url")).unwrap(),
        "original"
    );
}

#[test]
fn clear_failure_keeps_both_sources_and_releases_its_lock() {
    let app = temp_app();
    let dir = app.moddir.join(".config/sing-box");
    fs::create_dir_all(dir.join("subscription.local")).unwrap();
    fs::write(dir.join("subscription.url"), "original").unwrap();
    assert!(sub_clear(&app).is_err());
    assert_eq!(
        fs::read_to_string(dir.join("subscription.url")).unwrap(),
        "original"
    );
    assert!(dir.join("subscription.local").is_dir());
    assert!(!app
        .moddir
        .join(".state/sing-box/subscription-update.lock")
        .exists());
}
