use super::{stop_singbox_with, SINGBOX_STOP_GRACE, SINGBOX_STOP_POLL_INTERVAL};
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
        |_, force| signals.push(force),
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
            |_, force| signals.push(force),
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
        |_, force| signals.push(force),
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
        |pid, force| signals.push((pid.to_string(), force)),
        Duration::ZERO,
        Duration::ZERO,
        Duration::ZERO,
    );
    assert!(result.unwrap_err().contains("process set changed"));
    assert_eq!(signals, vec![("42".to_string(), false)]);
}
