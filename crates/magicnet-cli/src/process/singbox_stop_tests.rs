use super::{
    signal_owned_singbox_with, signal_pid, stop_singbox_with, SINGBOX_STOP_GRACE,
    SINGBOX_STOP_POLL_INTERVAL,
};
use std::cell::Cell;
use std::time::{Duration, Instant};

#[test]
fn slow_firewall_teardown_is_not_interrupted_by_sigkill() {
    let started = Instant::now();
    let killed = Cell::new(false);
    let mut signals = Vec::new();
    let result = stop_singbox_with(
        &["42".to_string()],
        || {
            if killed.get() || started.elapsed() >= Duration::from_secs(3) {
                Ok(Vec::new())
            } else {
                Ok(vec!["42".to_string()])
            }
        },
        |pid, force| {
            signals.push((pid.to_string(), force));
            killed.set(force);
            Ok(())
        },
        SINGBOX_STOP_GRACE,
        Duration::from_secs(1),
        SINGBOX_STOP_POLL_INTERVAL,
    );
    assert!(result.is_ok());
    assert_eq!(signals, vec![("42".to_string(), false)]);
    assert!(!killed.get());
}

#[test]
fn immediate_exit_needs_only_one_discovery_and_no_kill() {
    let mut discoveries = 0;
    let mut signals = Vec::new();
    stop_singbox_with(
        &["42".to_string()],
        || {
            discoveries += 1;
            Ok(Vec::new())
        },
        |_, force| {
            signals.push(force);
            Ok(())
        },
        SINGBOX_STOP_GRACE,
        Duration::from_secs(1),
        SINGBOX_STOP_POLL_INTERVAL,
    )
    .unwrap();
    assert_eq!(discoveries, 1);
    assert_eq!(signals, vec![false]);
}

#[test]
fn discovery_errors_never_allow_escalation() {
    for successful_queries in [0, 1] {
        let mut queries = 0;
        let mut signals = Vec::new();
        let result = stop_singbox_with(
            &["42".to_string()],
            || {
                queries += 1;
                if queries > successful_queries {
                    Err("discovery unavailable".to_string())
                } else {
                    Ok(vec!["42".to_string()])
                }
            },
            |_, force| {
                signals.push(force);
                Ok(())
            },
            SINGBOX_STOP_GRACE,
            Duration::ZERO,
            Duration::ZERO,
        );
        assert_eq!(result.unwrap_err(), "discovery unavailable");
        assert_eq!(signals, vec![false]);
    }
}

#[test]
fn expired_grace_escalates_once_and_verifies_exit() {
    let killed = Cell::new(false);
    let mut signals = Vec::new();
    stop_singbox_with(
        &["42".to_string()],
        || {
            if killed.get() {
                Ok(Vec::new())
            } else {
                Ok(vec!["42".to_string()])
            }
        },
        |_, force| {
            signals.push(force);
            killed.set(force);
            Ok(())
        },
        Duration::ZERO,
        Duration::ZERO,
        Duration::ZERO,
    )
    .unwrap();
    assert_eq!(signals, vec![false, true]);
}

#[test]
fn surviving_sigkill_is_an_error_not_a_successful_stop() {
    let mut signals = Vec::new();
    let result = stop_singbox_with(
        &["42".to_string()],
        || Ok(vec!["42".to_string()]),
        |_, force| {
            signals.push(force);
            Ok(())
        },
        Duration::ZERO,
        Duration::ZERO,
        Duration::ZERO,
    );
    assert!(result.unwrap_err().contains("did not stop after SIGKILL"));
    assert_eq!(signals, vec![false, true]);
}

#[test]
fn replacement_pid_does_not_inherit_the_old_kill_deadline() {
    let mut signals = Vec::new();
    let result = stop_singbox_with(
        &["42".to_string()],
        || Ok(vec!["84".to_string()]),
        |pid, force| {
            signals.push((pid.to_string(), force));
            Ok(())
        },
        Duration::ZERO,
        Duration::ZERO,
        Duration::ZERO,
    );
    assert!(result.unwrap_err().contains("process set changed"));
    assert_eq!(signals, vec![("42".to_string(), false)]);
}

#[test]
fn failed_sigterm_never_starts_the_grace_or_escalates() {
    let mut signals = Vec::new();
    let result = stop_singbox_with(
        &["42".to_string()],
        || panic!("discovery after rejected SIGTERM"),
        |_, force| {
            signals.push(force);
            Err("SIGTERM rejected".to_string())
        },
        Duration::ZERO,
        Duration::ZERO,
        Duration::ZERO,
    );
    assert_eq!(result.unwrap_err(), "SIGTERM rejected");
    assert_eq!(signals, vec![false]);
}

#[test]
fn failed_sigkill_is_reported_without_claiming_a_successful_stop() {
    let mut discoveries = 0;
    let mut signals = Vec::new();
    let result = stop_singbox_with(
        &["42".to_string()],
        || {
            discoveries += 1;
            Ok(vec!["42".to_string()])
        },
        |_, force| {
            signals.push(force);
            if force {
                Err("SIGKILL rejected".to_string())
            } else {
                Ok(())
            }
        },
        Duration::ZERO,
        Duration::ZERO,
        Duration::ZERO,
    );
    assert_eq!(result.unwrap_err(), "SIGKILL rejected");
    assert_eq!(signals, vec![false, true]);
    assert_eq!(discoveries, 1);
}

#[test]
fn signals_only_a_currently_verified_owned_pid() {
    let mut signals = Vec::new();
    signal_owned_singbox_with(
        "42",
        false,
        || Ok(vec!["42".to_string()]),
        |pid, force| {
            signals.push((pid.to_string(), force));
            Ok(())
        },
    )
    .unwrap();
    assert_eq!(signals, vec![("42".to_string(), false)]);

    for discovery in [Ok(Vec::new()), Ok(vec!["84".to_string()])] {
        signal_owned_singbox_with(
            "42",
            false,
            || discovery.clone(),
            |_, _| panic!("stale PID was signaled"),
        )
        .unwrap();
    }
    let result = signal_owned_singbox_with(
        "42",
        true,
        || Err("ownership unavailable".to_string()),
        |_, _| panic!("unknown ownership was signaled"),
    );
    assert_eq!(result.unwrap_err(), "ownership unavailable");
}

#[test]
fn invalid_signal_targets_cannot_signal_a_process_group() {
    for pid in ["0", "-1", "-42", "2147483648", "not-a-pid"] {
        assert_eq!(
            signal_pid(pid, false).unwrap_err(),
            "invalid sing-box signal target"
        );
    }
}

#[test]
fn native_sigterm_stops_a_child_without_an_external_kill_command() {
    use std::os::unix::process::ExitStatusExt;

    let mut child = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .unwrap();
    if let Err(err) = signal_pid(&child.id().to_string(), false) {
        let _ = child.kill();
        let _ = child.wait();
        panic!("native SIGTERM failed: {err}");
    }
    assert_eq!(child.wait().unwrap().signal(), Some(libc::SIGTERM));
}
