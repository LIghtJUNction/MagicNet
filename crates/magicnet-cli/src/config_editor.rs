use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{decode_base64, run_magicnet_function, write_text_file, App};

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
        _ => Err("Usage: cli config-editor {get|path|validate|save} <mihomo|sing-box> [base64-config]".to_string()),
    }
}

fn save_config(app: &App, target: &str, path: &Path, args: &[String]) -> Result<(), String> {
    let payload = args.get(2).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err(
            "Usage: cli config-editor save <mihomo|sing-box> <base64-config>".to_string(),
        );
    }
    let bytes = decode_base64(payload)?;
    let text = String::from_utf8(bytes).map_err(|err| format!("config is not UTF-8: {err}"))?;
    let tmp = app.moddir.join(format!(".tmp/config-editor-{target}.tmp"));
    write_text_file(tmp.clone(), &text)?;
    validate_config(app, target, &tmp)?;
    if path.exists() {
        let ext = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("bak");
        let _ = fs::copy(path, path.with_extension(format!("{ext}.bak")));
    }
    fs::rename(&tmp, path).map_err(|err| format!("save config {}: {err}", path.display()))?;
    run_magicnet_function(app, "magicnet_apply_runtime_config")?;
    println!("[info] Saved and validated {target} config: {}", path.display());
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
    let output = command.output().map_err(|err| format!("run validator: {err}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        Err(format!("config validation failed\n{stdout}\n{stderr}"))
    }
}
