#![cfg(target_os = "linux")]

use std::path::Path;
use std::process::Command;

#[test]
fn interrupted_transparent_recovery_preserves_failed_stop_and_cleanup() {
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/test-transparent-recovery.py");
    let output = Command::new("python3")
        .arg(script)
        .arg("CliRecoveryTests")
        .env(
            "MAGICNET_RECOVERY_TEST_CLI",
            env!("CARGO_BIN_EXE_magicnet-cli"),
        )
        .output()
        .expect("run real CLI transparent recovery regression");
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
