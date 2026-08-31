// Unit tests included from the matching src module.

use super::{
    api_host_port, config_apply_lock, config_apply_lock_bounded, normalize_transparent_mode,
    prepare_transparent_transaction, read_transparent_mode, restart_command,
    rollback_transparent_preflight, safe_log_name, service_log_path, stop_runtime_cleanup_command,
    supervisor_cmdline_matches, REPAIR_COMMAND, START_KERNEL_COMMAND, TRANSPARENT_CAPABILITY,
    TRANSPARENT_CONFIG, TRANSPARENT_MODE_CONF, TRANSPARENT_PROBE_REPORT,
    TRANSPARENT_SHARED_INTERFACES, TRANSPARENT_SHARED_PENDING, TRANSPARENT_TRANSACTION,
};
use crate::App;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn fixture_app(name: &str) -> (App, PathBuf) {
    let root = std::env::temp_dir().join(format!("magicnet-service-{name}-{}", std::process::id()));
    let log_dir = root.join(".log");
    fs::create_dir_all(&log_dir).unwrap();
    let app = App {
        moddir: root.clone(),
        api: String::new(),
        log_dir,
    };
    (app, root)
}

#[test]
fn transparent_mode_only_accepts_tun_or_ebpf() {
    assert_eq!(normalize_transparent_mode("tun").unwrap(), "tun");
    assert_eq!(normalize_transparent_mode("ebpf").unwrap(), "ebpf");
    assert!(normalize_transparent_mode("proxy").is_err());
    assert!(normalize_transparent_mode("external").is_err());
    assert!(normalize_transparent_mode("external-tun").is_err());
    assert!(normalize_transparent_mode("hybrid").is_err());
    assert!(normalize_transparent_mode("tproxy").is_err());
}

#[test]
fn transparent_mode_file_is_strict_and_missing_defaults_to_tun() {
    let (app, root) = fixture_app("transparent-mode");
    let mode_path = root.join(TRANSPARENT_MODE_CONF);
    fs::create_dir_all(mode_path.parent().unwrap()).unwrap();

    let missing = read_transparent_mode(&app).unwrap();
    assert_eq!(missing.mode, "tun");
    assert!(!missing.file_present);

    fs::write(
        &mode_path,
        "# explicit selection\nMAGICNET_TRANSPARENT_MODE=ebpf\n",
    )
    .unwrap();
    let ebpf = read_transparent_mode(&app).unwrap();
    assert_eq!(ebpf.mode, "ebpf");
    assert!(ebpf.file_present);

    fs::write(
        &mode_path,
        "MAGICNET_TRANSPARENT_MODE=tun\nMAGICNET_UNEXPECTED_ASSIGNMENT=1\n",
    )
    .unwrap();
    assert!(read_transparent_mode(&app).is_err());

    fs::write(
        &mode_path,
        "MAGICNET_TRANSPARENT_MODE=tun\nMAGICNET_TRANSPARENT_MODE=ebpf\n",
    )
    .unwrap();
    assert!(read_transparent_mode(&app).is_err());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn transparent_preflight_rollback_restores_ebpf_runtime_state() {
    let (app, root) = fixture_app("transparent-state-rollback");
    let mode_path = root.join(TRANSPARENT_MODE_CONF);
    let config_path = root.join(TRANSPARENT_CONFIG);
    fs::create_dir_all(mode_path.parent().unwrap()).unwrap();
    fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    fs::write(&mode_path, "MAGICNET_TRANSPARENT_MODE=ebpf\n").unwrap();
    fs::write(&config_path, b"old-ebpf-config\n").unwrap();

    let old_state = [
        (TRANSPARENT_CAPABILITY, b"ok\n".as_slice()),
        (
            TRANSPARENT_PROBE_REPORT,
            br#"{"active_programs":[{"name":"sb_ebpf_conn4"}]}"#.as_slice(),
        ),
        (TRANSPARENT_SHARED_INTERFACES, b"wlan2\n".as_slice()),
    ];
    for (path, contents) in old_state {
        let path = root.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    let old_mode = read_transparent_mode(&app).unwrap();
    prepare_transparent_transaction(&app, &old_mode, "tun").unwrap();

    fs::write(&mode_path, "MAGICNET_TRANSPARENT_MODE=tun\n").unwrap();
    fs::write(&config_path, b"candidate-tun-config\n").unwrap();
    fs::remove_file(root.join(TRANSPARENT_CAPABILITY)).unwrap();
    fs::remove_file(root.join(TRANSPARENT_PROBE_REPORT)).unwrap();
    fs::write(root.join(TRANSPARENT_SHARED_PENDING), b"candidate\n").unwrap();
    fs::write(root.join(TRANSPARENT_SHARED_INTERFACES), b"").unwrap();

    rollback_transparent_preflight(&app, &old_mode).unwrap();

    assert_eq!(
        fs::read_to_string(&mode_path).unwrap(),
        "MAGICNET_TRANSPARENT_MODE=ebpf\n"
    );
    assert_eq!(fs::read(&config_path).unwrap(), b"old-ebpf-config\n");
    for (path, contents) in old_state {
        assert_eq!(fs::read(root.join(path)).unwrap(), contents);
    }
    assert!(!root.join(TRANSPARENT_SHARED_PENDING).exists());
    assert!(!root.join(TRANSPARENT_TRANSACTION).exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn lifecycle_commands_detach_optional_supervisors_after_core_start() {
    assert!(START_KERNEL_COMMAND.contains("MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2"));
    assert!(START_KERNEL_COMMAND.contains("magicnet_start_kernel"));
    assert!(START_KERNEL_COMMAND.contains("magicnet_supervisors_start_detached"));
    for target in ["sing-box", "singbox"] {
        let command = restart_command(target);
        assert!(command.contains("MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2"));
        assert!(command.contains("magicnet_start_kernel"));
        assert!(command.contains("magicnet_supervisors_start_detached"));
        assert!(!command.contains("supervisor start all >/dev/null"));
    }
}

#[test]
fn stop_runtime_cleanup_disables_dns_capture_before_leak_guard() {
    assert_eq!(
            stop_runtime_cleanup_command(),
            "magicnet_hotspot_watchdog_stop >/dev/null 2>&1 || true; magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true; magicnet_disable_dns_capture || true; magicnet_disable_dns_leak_guard || true"
        );
}

#[test]
fn repair_explicitly_opts_into_disruptive_recovery() {
    assert!(REPAIR_COMMAND.contains("MAGICNET_ALLOW_DISRUPTIVE_RECOVERY=1"));
    assert!(REPAIR_COMMAND.contains("magicnet_ensure_kernel"));
}

#[test]
fn config_apply_lock_is_exclusive_and_releases_on_drop() {
    let (app, root) = fixture_app("config-apply-lock");
    let lock_path = root.join(".state/config-apply.lock");
    let guard = config_apply_lock(&app).expect("create config apply lock");
    let probe = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&lock_path)
        .expect("open config apply lock probe");
    assert_eq!(
        unsafe {
            libc::flock(
                std::os::fd::AsRawFd::as_raw_fd(&probe),
                libc::LOCK_EX | libc::LOCK_NB,
            )
        },
        -1,
        "a second config apply must not enter while the first owns the lock"
    );
    drop(probe);
    let started = Instant::now();
    let error = config_apply_lock_bounded(&app, Duration::from_millis(30))
        .err()
        .expect("bounded lifecycle lock must not wait behind config apply forever");
    assert!(error.contains("config apply is still busy"));
    assert!(started.elapsed() < Duration::from_secs(1));
    drop(guard);
    let reacquired = config_apply_lock(&app).expect("reacquire config apply lock");
    drop(reacquired);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn service_log_targets_reject_path_traversal() {
    assert!(!safe_log_name("../../etc/passwd"));
    assert!(!safe_log_name("../outside.log"));
    assert!(!safe_log_name("nested/outside.log"));
    assert!(safe_log_name("custom.log"));
    assert!(safe_log_name("custom-name_2.log"));
}

#[test]
fn service_log_path_rejects_symlink_escape() {
    let (app, root) = fixture_app("symlink");
    let outside = root.join("outside.log");
    fs::write(&outside, "do not expose\n").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&outside, app.log_dir.join("custom.log")).unwrap();
    #[cfg(unix)]
    assert!(service_log_path(&app, "custom").is_err());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn service_log_path_selects_latest_webui_task_log() {
    let (app, root) = fixture_app("latest-webui");
    let older = app.log_dir.join("webui-start-old.log");
    let newer = app.log_dir.join("webui-start-new.log");
    fs::write(&older, "older\n").unwrap();
    std::thread::sleep(Duration::from_millis(20));
    fs::write(&newer, "newer\n").unwrap();
    fs::write(app.log_dir.join("service.log"), "unrelated\n").unwrap();

    assert_eq!(
        service_log_path(&app, "webui").unwrap(),
        fs::canonicalize(&newer).unwrap()
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn service_log_path_reports_missing_webui_task_log() {
    let (app, root) = fixture_app("missing-webui");
    let error = service_log_path(&app, "webui").unwrap_err();
    assert!(error.starts_with("log file unavailable:"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn webui_setup_uses_the_configured_api_endpoint() {
    assert_eq!(
        api_host_port("http://127.0.0.1:19090"),
        ("127.0.0.1".to_string(), "19090".to_string())
    );
    assert_eq!(
        api_host_port("http://[::1]:19090"),
        ("::1".to_string(), "19090".to_string())
    );
    assert_eq!(
        api_host_port("invalid"),
        ("127.0.0.1".to_string(), "9090".to_string())
    );
}

fn argv(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[test]
fn supervisor_pidfiles_require_the_matching_module_command() {
    let module = PathBuf::from("/data/adb/modules/MagicNet");
    let kernel = module.join(".state/watchdog/magicnet-kernel.pid");
    let fswatch = module.join(".state/fswatch/magicnet-config.pid");
    let hotspot = module.join(".state/watchdog/magicnet-hotspot-route.pid");
    assert!(supervisor_cmdline_matches(
        &module,
        &kernel,
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/MagicNet/.state/watchdog/magicnet-kernel.loop.sh",
        ])
    ));
    assert!(supervisor_cmdline_matches(
        &module,
        &fswatch,
        &argv(&["/data/adb/modules/MagicNet/cli", "config", "apply"])
    ));
    assert!(supervisor_cmdline_matches(
        &module,
        &hotspot,
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/MagicNet/.state/watchdog/magicnet-hotspot-route.loop.sh",
        ])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        &fswatch,
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/Other/.state/fswatch/magicnet-config.loop.sh",
        ])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        &kernel,
        &argv(&[
            "sleep",
            "600",
            "/data/adb/modules/MagicNet/.state/watchdog/magicnet-kernel.loop.sh",
        ])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        &fswatch,
        &argv(&["/data/adb/modules/MagicNet/cli config apply"])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        &module.join(".state/unknown-supervisor.pid"),
        &argv(&["/data/adb/modules/MagicNet/cli", "config", "apply"])
    ));
}
