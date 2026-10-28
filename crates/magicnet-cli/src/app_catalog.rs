use crate::{run_bounded_command, App};
use serde_json::Value;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::process::Command;
use std::time::Duration;

pub(crate) fn inspect(app: &App) -> Result<Value, &'static str> {
    let jar = app.moddir.join("libexec/network-policy-bridge.jar");
    let m = fs::symlink_metadata(&jar).map_err(|_| "app.catalog_unsupported")?;
    if !m.is_file()
        || m.len() > 4 * 1024 * 1024
        || m.permissions().mode() & 0o022 != 0
        || m.uid() != unsafe { libc::geteuid() }
    {
        return Err("app.catalog_unsafe");
    }
    let mut command = Command::new("/system/bin/app_process");
    command
        .env("CLASSPATH", jar)
        .args(["/system/bin", "io.github.magicnet.AppCatalogBridge"]);
    let output = run_bounded_command(command, Duration::from_secs(15), 512 * 1024)
        .map_err(|_| "app.catalog_unsupported")?;
    if output.timed_out || output.truncated || !output.status.is_some_and(|s| s.success()) {
        return Err("app.catalog_unavailable");
    }
    let value: Value = serde_json::from_slice(&output.stdout).map_err(|_| "app.catalog_invalid")?;
    if value["schema"] != 1
        || value["scope"] != "owner_user"
        || !value["packages"].as_array().is_some_and(|items| {
            items.len() <= 4096
                && items.iter().all(|item| {
                    item["packageName"]
                        .as_str()
                        .is_some_and(crate::rules::valid_package_name)
                        && item["appLabel"].as_str().is_some_and(|s| s.len() <= 1024)
                })
        })
    {
        return Err("app.catalog_invalid");
    }
    Ok(value)
}
