use std::fs;
use std::process::Command;

use crate::{decode_base64, run_magicnet_function, write_text_file, App};

pub(crate) fn api_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or_default() {
        "ui" => {
            api_ui(app, args.get(1).map(String::as_str).unwrap_or("current"));
            Ok(())
        }
        "groups" => curl(app, "/providers/proxies"),
        "conns" => curl(app, "/connections"),
        "stats" => curl(app, "/traffic"),
        "close-all" => curl_delete(app, "/connections"),
        _ => Err(
            "Usage: cli api {ui [current|mihomo|sing-box|all]|groups|conns|stats|close-all}"
                .to_string(),
        ),
    }
}

pub(crate) fn webui_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            webui_status(app);
            Ok(())
        }
        "install-local" => install_local(app, args),
        _ => Err("Usage: cli webui {status|install-local <download-url> [name]}".to_string()),
    }
}

pub(crate) fn backup_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("export") {
        "export" => {
            let password = args.get(1).map(String::as_str).unwrap_or("");
            let text = backup_text(app, password);
            let bytes = encode_backup_bytes(&text, password);
            println!("{}", crate::encode_base64(&bytes));
            Ok(())
        }
        "restore" => {
            let password = args.get(1).map(String::as_str).unwrap_or("");
            let payload = args.get(2).map(String::as_str).unwrap_or_default();
            if payload.is_empty() {
                return Err("Usage: cli backup restore [password|-] <base64>|restore-file [password|-] <path>".to_string());
            }
            restore_payload(app, password, payload)
        }
        "restore-file" => {
            let password = args.get(1).map(String::as_str).unwrap_or("");
            let path = args.get(2).map(String::as_str).unwrap_or_default();
            if path.is_empty() {
                return Err("Usage: cli backup restore-file [password|-] <path>".to_string());
            }
            let payload =
                fs::read_to_string(path).map_err(|err| format!("read backup file: {err}"))?;
            restore_payload(app, password, payload.trim())
        }
        _ => Err("Usage: cli backup {export [password]|restore [password|-] <base64>|restore-file [password|-] <path>}".to_string()),
    }
}

fn restore_payload(app: &App, password: &str, payload: &str) -> Result<(), String> {
    let bytes = decode_base64(payload)?;
    let bytes = decode_backup_bytes(bytes, password)?;
    let text = String::from_utf8(bytes).map_err(|err| format!("backup is not UTF-8: {err}"))?;
    verify_backup_password(&text, password)?;
    restore_backup(app, &text)?;
    run_magicnet_function(app, "magicnet_apply_runtime_config")?;
    println!("[info] Backup restored");
    Ok(())
}

fn curl(app: &App, path: &str) -> Result<(), String> {
    run_curl(&["-fsS", "--max-time", "4", &format!("{}{}", app.api, path)])
}

fn curl_delete(app: &App, path: &str) -> Result<(), String> {
    run_curl(&[
        "-fsS",
        "-X",
        "DELETE",
        "--max-time",
        "4",
        &format!("{}{}", app.api, path),
    ])
}

fn run_curl(args: &[&str]) -> Result<(), String> {
    let output = Command::new("curl")
        .args(args)
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    print!("{}", String::from_utf8_lossy(&output.stdout));
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn webui_status(app: &App) {
    let local_dir = app.moddir.join(".config/sing-box/zashboard");
    println!("local_dir={}", local_dir.display());
    println!(
        "local_ready={}",
        local_dir.join("index.html").exists() as u8
    );
    println!("sing-box={}", app.singbox_webui);
    println!("mihomo={}", app.mihomo_webui);
    println!(
        "version={}",
        fs::read_to_string(app.moddir.join("zashboard.version"))
            .unwrap_or_else(|_| "unknown".to_string())
            .lines()
            .next()
            .unwrap_or("unknown")
    );
}

fn api_ui(app: &App, target: &str) {
    match target {
        "sing-box" | "singbox" => println!("{}", app.singbox_webui),
        "mihomo" | "clash" => println!("{}", app.mihomo_webui),
        "all" => {
            println!("mihomo={}", app.mihomo_webui);
            println!("sing-box={}", app.singbox_webui);
        }
        _ if crate::pid_summary("sing-box") != "stopped" => println!("{}", app.singbox_webui),
        _ => println!("{}", app.mihomo_webui),
    }
}

fn install_local(app: &App, args: &[String]) -> Result<(), String> {
    let url = args.get(1).map(String::as_str).unwrap_or_default();
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("Usage: cli webui install-local <download-url> [name]".to_string());
    }
    let name = args.get(2).map(String::as_str).unwrap_or("zashboard");
    let tmp = app.moddir.join(".tmp/webui-panel.zip");
    let target = app.moddir.join(".config/sing-box/zashboard");
    if let Some(parent) = tmp.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    download_panel_zip(url, &tmp)?;
    let backup = target.with_extension("bak");
    let _ = fs::remove_dir_all(&backup);
    if target.exists() {
        let _ = fs::rename(&target, &backup);
    }
    fs::create_dir_all(&target).map_err(|err| format!("mkdir {}: {err}", target.display()))?;
    let status = Command::new("unzip")
        .arg("-oq")
        .arg(&tmp)
        .arg("-d")
        .arg(&target)
        .status()
        .map_err(|err| format!("unzip panel: {err}"))?;
    promote_dist_dir(&target)?;
    if !status.success() || !contains_index(&target) {
        let _ = fs::remove_dir_all(&target);
        let _ = fs::rename(&backup, &target);
        return Err("panel zip does not contain index.html".to_string());
    }
    write_text_file(app.moddir.join("zashboard.version"), &format!("{name}\n"))?;
    run_magicnet_function(
        app,
        "magicnet_singbox_apply_zashboard; magicnet_mihomo_apply_zashboard",
    )?;
    println!("[info] Installed local panel {name}");
    Ok(())
}

fn download_panel_zip(url: &str, tmp: &std::path::Path) -> Result<(), String> {
    match curl_download(url, tmp) {
        Ok(()) => Ok(()),
        Err(first_err) => {
            let Some(fallback) = zashboard_fallback_url(url) else {
                return Err(first_err);
            };
            eprintln!("[warn] zashboard download failed, retrying smaller asset: {fallback}");
            curl_download(&fallback, tmp).map_err(|fallback_err| {
                format!("download panel failed\nprimary: {first_err}\nfallback: {fallback_err}")
            })
        }
    }
}

fn curl_download(url: &str, tmp: &std::path::Path) -> Result<(), String> {
    let output = Command::new("curl")
        .args(["-fL", "--connect-timeout", "15", "--max-time", "90", "-o"])
        .arg(tmp)
        .arg(url)
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let detail = stderr.trim();
    if detail.is_empty() {
        Err(format!(
            "curl exited with status {}",
            output.status.code().unwrap_or(1)
        ))
    } else {
        Err(format!(
            "curl exited with status {}: {detail}",
            output.status.code().unwrap_or(1)
        ))
    }
}

fn zashboard_fallback_url(url: &str) -> Option<String> {
    if !url.starts_with("https://github.com/Zephyruso/zashboard/releases/")
        || !url.ends_with("/dist.zip")
    {
        return None;
    }
    Some(url.trim_end_matches("/dist.zip").to_string() + "/dist-no-fonts.zip")
}

fn contains_index(dir: &std::path::Path) -> bool {
    if dir.join("index.html").exists() {
        return true;
    }
    fs::read_dir(dir)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| entry.path().is_dir() && contains_index(&entry.path()))
}

fn promote_dist_dir(target: &std::path::Path) -> Result<(), String> {
    let dist = target.join("dist");
    if !dist.join("index.html").exists() {
        return Ok(());
    }
    for entry in fs::read_dir(&dist).map_err(|err| format!("read {}: {err}", dist.display()))? {
        let entry = entry.map_err(|err| format!("read {}: {err}", dist.display()))?;
        let dest = target.join(entry.file_name());
        if dest.exists() {
            if dest.is_dir() {
                fs::remove_dir_all(&dest)
            } else {
                fs::remove_file(&dest)
            }
            .map_err(|err| format!("remove {}: {err}", dest.display()))?;
        }
        fs::rename(entry.path(), &dest)
            .map_err(|err| format!("move panel asset to {}: {err}", dest.display()))?;
    }
    fs::remove_dir_all(&dist).map_err(|err| format!("remove {}: {err}", dist.display()))?;
    Ok(())
}

fn backup_text(app: &App, password: &str) -> String {
    let mut out = String::new();
    out.push_str("MagicNet backup v1\n");
    out.push_str(&format!("password_set={}\n", (!password.is_empty()) as u8));
    if !password.is_empty() {
        out.push_str(&format!(
            "password_md5={:x}\n",
            md5::compute(password.as_bytes())
        ));
    }
    for rel in backup_files() {
        let path = app.moddir.join(rel);
        out.push_str(&format!("\n--- {rel}\n"));
        let text = fs::read_to_string(path).unwrap_or_default();
        out.push_str(&text);
        out.push('\n');
    }
    out
}

fn encode_backup_bytes(text: &str, password: &str) -> Vec<u8> {
    if password.is_empty() {
        return text.as_bytes().to_vec();
    }
    let mut out = b"MagicNet encrypted backup v1\n".to_vec();
    out.extend(xor_with_password(text.as_bytes(), password));
    out
}

fn decode_backup_bytes(bytes: Vec<u8>, password: &str) -> Result<Vec<u8>, String> {
    const PREFIX: &[u8] = b"MagicNet encrypted backup v1\n";
    if !bytes.starts_with(PREFIX) {
        return Ok(bytes);
    }
    if password == "-" || password.is_empty() {
        return Err("backup requires a safety code".to_string());
    }
    Ok(xor_with_password(&bytes[PREFIX.len()..], password))
}

fn xor_with_password(input: &[u8], password: &str) -> Vec<u8> {
    let key = format!("{:x}", md5::compute(password.as_bytes()));
    let key = key.as_bytes();
    input
        .iter()
        .enumerate()
        .map(|(idx, byte)| byte ^ key[idx % key.len()])
        .collect()
}

fn verify_backup_password(text: &str, password: &str) -> Result<(), String> {
    let mut password_set = false;
    let mut expected = "";
    for line in text.lines().take_while(|line| !line.starts_with("--- ")) {
        if line == "password_set=1" {
            password_set = true;
        } else if let Some(value) = line.strip_prefix("password_md5=") {
            expected = value.trim();
        }
    }
    if !password_set {
        return Ok(());
    }
    if password == "-" || password.is_empty() {
        return Err("backup requires a safety code".to_string());
    }
    if expected.is_empty() {
        return Err("backup password metadata is missing".to_string());
    }
    let actual = format!("{:x}", md5::compute(password.as_bytes()));
    if actual != expected {
        return Err("backup safety code does not match".to_string());
    }
    Ok(())
}

fn restore_backup(app: &App, text: &str) -> Result<(), String> {
    let mut current: Option<String> = None;
    let mut buf = String::new();
    for line in text.lines() {
        if let Some(path) = line.strip_prefix("--- ") {
            flush_restore(app, current.take(), &buf)?;
            current = Some(path.to_string());
            buf.clear();
        } else if current.is_some() {
            buf.push_str(line);
            buf.push('\n');
        }
    }
    flush_restore(app, current, &buf)
}

fn flush_restore(app: &App, rel: Option<String>, text: &str) -> Result<(), String> {
    let Some(rel) = rel else {
        return Ok(());
    };
    if !backup_files().contains(&rel.as_str()) {
        return Ok(());
    }
    write_text_file(app.moddir.join(rel), text)
}

fn backup_files() -> &'static [&'static str] {
    &[
        ".config/sing-box/subscription.url",
        ".config/mihomo/subscription.url",
        ".config/magicnet/app-mode.conf",
        ".config/magicnet/app-proxy.list",
        ".config/magicnet/app-bypass.list",
        ".config/magicnet/block.conf",
        ".config/magicnet/block-domain-suffix.list",
        ".config/magicnet/block-allow-rules.list",
        ".config/magicnet/capture.conf",
        ".config/magicnet/capture-app.list",
        ".config/magicnet/capture-domain-suffix.list",
        ".config/magicnet/route-proxy-domain-suffix.list",
        ".config/magicnet/route-direct-domain-suffix.list",
        ".config/magicnet/route-block-domain-suffix.list",
        ".config/magicnet/transparent-mode.conf",
        ".config/magicnet/hotspot.conf",
    ]
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    fn temp_app() -> App {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("magicnet-cli-test-{stamp}"));
        App::for_test(dir)
    }

    #[test]
    fn backup_without_password_is_plaintext_and_restores_known_files_only() {
        let app = temp_app();
        write_text_file(
            app.moddir.join(".config/magicnet/app-mode.conf"),
            "MAGICNET_APP_MODE=whitelist\n",
        )
        .unwrap();
        let text = backup_text(&app, "");

        assert!(text.starts_with("MagicNet backup v1\npassword_set=0"));
        assert_eq!(encode_backup_bytes(&text, ""), text.as_bytes());
        verify_backup_password(&text, "").unwrap();

        let restore_app = temp_app();
        let restore_text = format!("{text}\n--- ../ignored\nnope\n");
        restore_backup(&restore_app, &restore_text).unwrap();
        let restored =
            fs::read_to_string(restore_app.moddir.join(".config/magicnet/app-mode.conf")).unwrap();
        assert!(restored.starts_with("MAGICNET_APP_MODE=whitelist\n"));
        assert!(!restore_app.moddir.join("../ignored").exists());
    }

    #[test]
    fn encrypted_backup_requires_matching_safety_code() {
        let text =
            "MagicNet backup v1\npassword_set=1\npassword_md5=900150983cd24fb0d6963f7d28e17f72\n";
        let encoded = encode_backup_bytes(text, "abc");

        assert!(decode_backup_bytes(encoded.clone(), "").is_err());
        assert!(decode_backup_bytes(encoded.clone(), "-").is_err());

        let decoded = decode_backup_bytes(encoded, "abc").unwrap();
        let decoded = String::from_utf8(decoded).unwrap();
        verify_backup_password(&decoded, "abc").unwrap();
        assert!(verify_backup_password(&decoded, "wrong")
            .unwrap_err()
            .contains("does not match"));
    }

    #[test]
    fn backup_password_metadata_must_be_present_when_password_is_set() {
        let err =
            verify_backup_password("MagicNet backup v1\npassword_set=1\n", "abc").unwrap_err();
        assert!(err.contains("metadata is missing"), "{err}");
    }

    #[test]
    fn contains_index_searches_nested_panel_directories() {
        let app = temp_app();
        let root = app.moddir.join("panel");
        fs::create_dir_all(root.join("nested")).unwrap();
        assert!(!contains_index(&root));
        fs::write(root.join("nested/index.html"), "").unwrap();
        assert!(contains_index(&root));
    }

    #[test]
    fn promote_dist_dir_moves_zashboard_assets_to_panel_root() {
        let app = temp_app();
        let root = app.moddir.join("panel");
        fs::create_dir_all(root.join("dist/assets")).unwrap();
        fs::write(root.join("dist/index.html"), "").unwrap();
        fs::write(root.join("dist/assets/app.js"), "").unwrap();

        promote_dist_dir(&root).unwrap();

        assert!(root.join("index.html").exists());
        assert!(root.join("assets/app.js").exists());
        assert!(!root.join("dist").exists());
    }

    #[test]
    fn zashboard_dist_url_falls_back_to_no_fonts_asset() {
        let url = "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip";
        assert_eq!(
            zashboard_fallback_url(url).as_deref(),
            Some(
                "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip"
            )
        );
        assert_eq!(
            zashboard_fallback_url("https://example.com/panel/dist.zip"),
            None
        );
    }
}
