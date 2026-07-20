use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value as JsonValue;

use crate::{decode_base64, run_magicnet_function, write_text_file, App};

const VALIDATOR_TIMEOUT: Duration = Duration::from_secs(20);
const TEMPLATE_FETCH_TIMEOUT: Duration = Duration::from_secs(45);

pub(crate) fn config_editor(app: &App, args: &[String]) -> Result<(), String> {
    let action = args.first().map(String::as_str).unwrap_or_default();
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    match action {
        "path" => {
            let path = config_path(app, target)?;
            println!("{}", path.display());
            Ok(())
        }
        "get" => {
            let path = config_path(app, target)?;
            let text = fs::read_to_string(&path).unwrap_or_else(|_| default_config(target));
            print!("{text}");
            Ok(())
        }
        "validate" => {
            let path = config_path(app, target)?;
            validate_config(app, target, &path)?;
            println!("[info] {target} config validation passed");
            Ok(())
        }
        "save" => {
            let path = config_path(app, target)?;
            save_config(app, target, &path, args)
        }
        "save-file" => {
            let path = config_path(app, target)?;
            save_config_file(app, target, &path, args)
        }
        "sync-template" | "sync" => sync_template(app, target),
        _ => Err(
            "Usage: cli config-editor {get|path|validate|save|save-file|sync-template} <sing-box|all> [base64-config|tmp-path]"
                .to_string(),
        ),
    }
}

fn save_config(app: &App, target: &str, path: &Path, args: &[String]) -> Result<(), String> {
    let payload = args.get(2).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli config-editor save sing-box <base64-config>".to_string());
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
        return Err("Usage: cli config-editor save-file sing-box <tmp-path>".to_string());
    }
    if !tmp.starts_with(app.moddir.join(".tmp")) {
        return Err("config-editor save-file only accepts files under $MODDIR/.tmp".to_string());
    }
    commit_config(app, target, path, &tmp)
}

fn commit_config(app: &App, target: &str, path: &Path, tmp: &Path) -> Result<(), String> {
    validate_config(app, target, tmp)?;
    backup_config(path)?;
    fs::rename(tmp, path).map_err(|err| format!("save config {}: {err}", path.display()))?;
    println!(
        "[info] Saved and validated {target} config: {}\n[info] Runtime policy changes can be applied from the control/app pages.",
        path.display()
    );
    Ok(())
}

fn backup_config(path: &Path) -> Result<(), String> {
    if path.exists() {
        let ext = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("bak");
        fs::copy(path, path.with_extension(format!("{ext}.bak")))
            .map_err(|err| format!("backup config {}: {err}", path.display()))?;
    }
    Ok(())
}

fn sync_template(app: &App, target: &str) -> Result<(), String> {
    match target {
        "all" => {
            sync_template_one(app, "sing-box")?;
            Ok(())
        }
        "sing-box" | "singbox" => sync_template_one(app, "sing-box"),
        _ => Err("Usage: cli config-editor sync-template <sing-box|all>".to_string()),
    }
}

fn sync_template_one(app: &App, target: &str) -> Result<(), String> {
    let path = config_path(app, target)?;
    let url = upstream_template_url(target)?;
    let template = fetch_template(app, &url)?;
    let current = fs::read_to_string(&path).unwrap_or_default();
    let merged = prepare_template(target, &template, &current)?;
    let tmp = app
        .moddir
        .join(format!(".tmp/config-template-{target}.tmp"));
    write_text_file(tmp.clone(), &merged)?;
    validate_config(app, target, &tmp)?;
    backup_config(&path)?;
    fs::rename(&tmp, &path).map_err(|err| format!("save config {}: {err}", path.display()))?;
    run_magicnet_function(app, "magicnet_apply_runtime_config")?;
    println!(
        "[info] Synced {target} template from {url}\n[info] Preserved subscription-facing config and re-applied runtime rules."
    );
    Ok(())
}

fn upstream_template_url(target: &str) -> Result<String, String> {
    match target {
        "sing-box" => Ok(
            "https://raw.githubusercontent.com/LIghtJUNction/MagicSingBox/main/config.json"
                .to_string(),
        ),
        _ => Err("config target must be sing-box".to_string()),
    }
}

fn fetch_template(app: &App, url: &str) -> Result<String, String> {
    let mut errors = Vec::new();
    let mut command = Command::new("curl");
    command
        .arg("-fsSL")
        .arg("--max-time")
        .arg(TEMPLATE_FETCH_TIMEOUT.as_secs().to_string())
        .arg(url);
    if let Some(text) = fetch_with(command, "curl", &mut errors) {
        return Ok(text);
    }

    let mut command = Command::new("wget");
    command.arg("-qO-").arg(url);
    if let Some(text) = fetch_with(command, "wget", &mut errors) {
        return Ok(text);
    }

    for singbox in [app.moddir.join("bin/sing-box")] {
        if singbox.exists() {
            let mut command = Command::new(singbox);
            command.arg("tools").arg("fetch").arg(url);
            if let Some(text) = fetch_with(command, "sing-box tools fetch", &mut errors) {
                return Ok(text);
            }
        }
    }

    Err(format!("fetch template failed: {}", errors.join("; ")))
}

fn fetch_with(command: Command, label: &str, errors: &mut Vec<String>) -> Option<String> {
    let output = match run_with_timeout(command, TEMPLATE_FETCH_TIMEOUT + Duration::from_secs(5)) {
        Ok(output) => output,
        Err(err) => {
            errors.push(format!("{label}: {err}"));
            return None;
        }
    };
    if output.status.success() {
        match String::from_utf8(output.stdout) {
            Ok(text) => Some(text),
            Err(err) => {
                errors.push(format!("{label}: template is not UTF-8: {err}"));
                None
            }
        }
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        errors.push(if stderr.is_empty() {
            format!("{label}: command failed")
        } else {
            format!("{label}: {stderr}")
        });
        None
    }
}

fn prepare_template(target: &str, template: &str, current: &str) -> Result<String, String> {
    match target {
        "sing-box" => preserve_singbox_subscription_config(template, current),
        _ => Err("config target must be sing-box".to_string()),
    }
}

fn preserve_singbox_subscription_config(template: &str, current: &str) -> Result<String, String> {
    let mut template_json: JsonValue = serde_json::from_str(template)
        .map_err(|err| format!("upstream sing-box template is invalid JSON: {err}"))?;
    let Ok(current_json) = serde_json::from_str::<JsonValue>(current) else {
        return serde_json::to_string_pretty(&template_json)
            .map_err(|err| format!("serialize sing-box template: {err}"));
    };
    if let Some(outbounds) = current_json.get("outbounds").cloned() {
        let Some(object) = template_json.as_object_mut() else {
            return Err("upstream sing-box template is not a JSON object".to_string());
        };
        object.insert("outbounds".to_string(), outbounds);
    }
    serde_json::to_string_pretty(&template_json)
        .map(|text| format!("{text}\n"))
        .map_err(|err| format!("serialize sing-box template: {err}"))
}

fn config_path(app: &App, target: &str) -> Result<PathBuf, String> {
    match target {
        "sing-box" | "singbox" | "all" => Ok(app.moddir.join(".config/sing-box/config.json")),
        _ => Err("config target must be sing-box".to_string()),
    }
}

fn default_config(_target: &str) -> String {
    r#"{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local"
      }
    ],
    "final": "local"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 7892
    },
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "magicnet0",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": "direct"
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "zashboard"
    }
  }
}
"#
    .to_string()
}

fn validate_config(app: &App, target: &str, path: &Path) -> Result<(), String> {
    let bin = match target {
        "sing-box" | "singbox" | "all" => app.moddir.join("bin/sing-box"),
        _ => return Err("config target must be sing-box".to_string()),
    };
    if !bin.exists() {
        return Err(format!("validator missing: {}", bin.display()));
    }
    let mut command = Command::new(bin);
    command.arg("check").arg("-c").arg(path);
    if let Some(parent) = path.parent() {
        command.arg("-D").arg(parent);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_sing_box_config_uses_mixed_tun_stack() {
        let config: serde_json::Value =
            serde_json::from_str(&default_config("sing-box")).expect("parse default config");
        let tun_stack = config["inbounds"]
            .as_array()
            .and_then(|inbounds| inbounds.iter().find(|inbound| inbound["tag"] == "tun-in"))
            .and_then(|inbound| inbound["stack"].as_str());

        assert_eq!(tun_stack, Some("mixed"));
    }

    #[test]
    fn preserves_singbox_outbounds_block() {
        let template = r#"{
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {}
}
"#;
        let current = r#"{
  "outbounds": [
    { "type": "selector", "tag": "proxy" }
  ]
}
"#;
        let merged = preserve_singbox_subscription_config(template, current).unwrap();
        assert!(merged.contains("\"tag\": \"proxy\""));
        assert!(merged.contains("\"inbounds\": []"));
        assert!(merged.contains("\"route\": {}"));
    }
}
