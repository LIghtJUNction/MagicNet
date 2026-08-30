// Unit tests included from the matching src module.

use std::ffi::CString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
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
fn restored_subscription_urls_allow_empty_and_reject_policy_violations() {
    validate_restored_subscription_urls("").unwrap();
    validate_restored_subscription_urls("\n  \n").unwrap();
    validate_restored_subscription_urls("https://example.com/sub\nhttps://example.org/sub\n")
        .unwrap();
    assert!(validate_restored_subscription_urls("https://user:secret@example.com/sub\n").is_err());
    assert!(validate_restored_subscription_urls("https://127.0.0.1/sub\n").is_err());
    let too_many = (0..=5)
        .map(|idx| format!("https://example.com/{idx}"))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(validate_restored_subscription_urls(&too_many).is_err());
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
