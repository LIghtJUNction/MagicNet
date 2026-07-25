use std::fs;

use crate::{decode_base64, run_magicnet_function, write_text_file, App};

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
            let (password, path) = match (args.get(1), args.get(2)) {
                (Some(path), None) => ("", path.as_str()),
                (Some(password), Some(path)) => (password.as_str(), path.as_str()),
                _ => {
                    return Err(
                        "Usage: cli backup restore-file [password|-] <path>".to_string()
                    )
                }
            };
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
    run_magicnet_function(
        app,
        "magicnet_apply_runtime_config; magicnet_wifi_policy_stop; magicnet_wifi_policy_start",
    )?;
    println!("[info] Backup restored");
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
        ".config/magicnet/app-mode.conf",
        ".config/magicnet/app-proxy.list",
        ".config/magicnet/app-bypass.list",
        ".config/magicnet/block.conf",
        ".config/magicnet/block-domain-suffix.list",
        ".config/magicnet/block-allow-rules.list",
        ".config/magicnet/route-proxy-domain-suffix.list",
        ".config/magicnet/route-direct-domain-suffix.list",
        ".config/magicnet/route-block-domain-suffix.list",
        ".config/magicnet/route-warp-domain-suffix.list",
        ".config/magicnet/dns.conf",
        ".config/magicnet/warp.conf",
        ".config/magicnet/warp-endpoint.json",
        ".config/magicnet/transparent-mode.conf",
        ".config/magicnet/wifi-policy.conf",
        ".config/magicnet/wifi-ssid.list",
        ".config/magicnet/wifi-bssid.list",
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
    fn restore_file_without_password_treats_only_argument_as_path() {
        let app = temp_app();
        let path = app.moddir.join("backup.txt");
        let text =
            "MagicNet backup v1\npassword_set=1\npassword_md5=5ebe2294ecd0e0f08eab7690d2a6ee69\n";
        let encrypted = encode_backup_bytes(text, "secret");
        write_text_file(path.clone(), &crate::encode_base64(&encrypted)).unwrap();

        let args = vec![
            "restore-file".to_string(),
            path.to_string_lossy().into_owned(),
        ];
        let err = backup_cmd(&app, &args).unwrap_err();

        assert_eq!(err, "backup requires a safety code");
    }

    #[test]
    fn restore_file_accepts_password_and_dash_placeholder_before_path() {
        let app = temp_app();
        let path = app.moddir.join("backup.txt");
        let text =
            "MagicNet backup v1\npassword_set=1\npassword_md5=900150983cd24fb0d6963f7d28e17f72\n";
        let encrypted = encode_backup_bytes(text, "secret");
        write_text_file(path.clone(), &crate::encode_base64(&encrypted)).unwrap();
        let path = path.to_string_lossy().into_owned();

        let password_args = vec![
            "restore-file".to_string(),
            "secret".to_string(),
            path.clone(),
        ];
        let password_err = backup_cmd(&app, &password_args).unwrap_err();
        assert!(password_err.contains("does not match"), "{password_err}");

        let dash_args = vec!["restore-file".to_string(), "-".to_string(), path];
        let dash_err = backup_cmd(&app, &dash_args).unwrap_err();
        assert_eq!(dash_err, "backup requires a safety code");
    }
}
