use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::{decode_base64, write_text_file, App};

const VALIDATOR_TIMEOUT: Duration = Duration::from_secs(20);

pub(crate) fn config_editor(app: &App, args: &[String]) -> Result<(), String> {
    let action = args.first().map(String::as_str).unwrap_or_default();
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    let path = config_path(app, target)?;
    match action {
        "path" => {
            println!("{}", path.display());
            Ok(())
        }
        "get" => {
            let text = fs::read_to_string(&path)
                .map_err(|err| format!("config not found {}: {err}", path.display()))?;
            print!("{text}");
            Ok(())
        }
        "validate" => {
            validate_config(app, target, &path)?;
            println!("[info] {target} config validation passed");
            Ok(())
        }
        "save" => save_config(app, target, &path, args),
        "save-file" => save_config_file(app, target, &path, args),
        _ => Err(
            "Usage: cli config-editor {get|path|validate|save|save-file} <mihomo|sing-box> [base64-config|tmp-path]"
                .to_string(),
        ),
    }
}

fn save_config(app: &App, target: &str, path: &Path, args: &[String]) -> Result<(), String> {
    let payload = args.get(2).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli config-editor save <mihomo|sing-box> <base64-config>".to_string());
    }
    let bytes = decode_base64(payload)?;
    let text = String::from_utf8(bytes).map_err(|err| format!("config is not UTF-8: {err}"))?;
    let tmp = app.moddir.join(format!(".tmp/config-editor-{target}.tmp"));
    write_text_file(tmp.clone(), &text)?;
    commit_config(app, target, path, &tmp)
}

fn save_config_file(app: &App, target: &str, path: &Path, args: &[String]) -> Result<(), String> {
    let tmp = args.get(2).map(PathBuf::from).unwrap_or_default();
    if tmp.as_os_str().is_empty() {
        return Err("Usage: cli config-editor save-file <mihomo|sing-box> <tmp-path>".to_string());
    }
    if !tmp.starts_with(app.moddir.join(".tmp")) {
        return Err("config-editor save-file only accepts files under $MODDIR/.tmp".to_string());
    }
    commit_config(app, target, path, &tmp)
}

fn commit_config(app: &App, target: &str, path: &Path, tmp: &Path) -> Result<(), String> {
    validate_config(app, target, &tmp)?;
    if path.exists() {
        let ext = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("bak");
        let _ = fs::copy(path, path.with_extension(format!("{ext}.bak")));
    }
    fs::rename(&tmp, path).map_err(|err| format!("save config {}: {err}", path.display()))?;
    println!(
        "[info] Saved and validated {target} config: {}\n[info] Runtime policy changes can be applied from the control/app pages.",
        path.display()
    );
    Ok(())
}

fn config_path(app: &App, target: &str) -> Result<PathBuf, String> {
    match target {
        "mihomo" | "clash" => Ok(app.moddir.join(".config/mihomo/config.yaml")),
        "sing-box" | "singbox" => Ok(app.moddir.join(".config/sing-box/config.json")),
        _ => Err("config target must be mihomo or sing-box".to_string()),
    }
}

fn validate_config(app: &App, target: &str, path: &Path) -> Result<(), String> {
    let bin = match target {
        "mihomo" | "clash" => app.moddir.join(".local/bin/mihomo"),
        "sing-box" | "singbox" => app.moddir.join(".local/bin/sing-box"),
        _ => return Err("config target must be mihomo or sing-box".to_string()),
    };
    if !bin.exists() {
        return Err(format!("validator missing: {}", bin.display()));
    }
    let mut command = Command::new(bin);
    match target {
        "mihomo" | "clash" => {
            command.arg("-t").arg("-f").arg(path);
            if let Some(parent) = path.parent() {
                command.arg("-d").arg(parent);
            }
        }
        _ => {
            command.arg("check").arg("-c").arg(path);
            if let Some(parent) = path.parent() {
                command.arg("-D").arg(parent);
            }
        }
    }
    let output = run_with_timeout(command, VALIDATOR_TIMEOUT)?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        Err(format!("config validation failed\n{stdout}\n{stderr}"))
    }
}

fn run_with_timeout(
    mut command: Command,
    timeout: Duration,
) -> Result<std::process::Output, String> {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| format!("run validator: {err}"))?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return child
                    .wait_with_output()
                    .map_err(|err| format!("read validator output: {err}"))
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "config validation timed out after {}s",
                    timeout.as_secs()
                ));
            }
            Err(err) => return Err(format!("wait validator: {err}")),
        }
    }
}
