use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    aead::{rand_core::RngCore, Aead, AeadCore, KeyInit, OsRng, Payload},
    Key, XChaCha20Poly1305, XNonce,
};

use crate::config_editor::validate_repository_config_text;
use crate::subscriptions::{
    normalize_subscription_filter_text, validate_subscription_url, validate_subscription_user_agent,
};
use crate::utils::replace_module_text_files_transactionally;
use crate::{decode_base64, run_magicnet_function, shell_inert_conf_value, App};

const MAX_BACKUP_BYTES: usize = 32 * 1024 * 1024;
const MAX_BACKUP_BASE64_BYTES: usize = MAX_BACKUP_BYTES.div_ceil(3) * 4;

pub(crate) fn backup_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("export") {
        "export" => {
            let password = args.get(1).map(String::as_str).unwrap_or("");
            let text = backup_text(app)?;
            let bytes = encode_backup_bytes(&text, password)?;
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
            let metadata = fs::metadata(path).map_err(|err| format!("inspect backup file: {err}"))?;
            if metadata.len() > MAX_BACKUP_BASE64_BYTES as u64 {
                return Err("backup file exceeds size limit".to_string());
            }
            let payload =
                fs::read_to_string(path).map_err(|err| format!("read backup file: {err}"))?;
            restore_payload(app, password, payload.trim())
        }
        _ => Err("Usage: cli backup {export [password]|restore [password|-] <base64>|restore-file [password|-] <path>}".to_string()),
    }
}

fn restore_payload(app: &App, password: &str, payload: &str) -> Result<(), String> {
    if payload.len() > MAX_BACKUP_BASE64_BYTES {
        return Err("backup payload exceeds size limit".to_string());
    }
    let bytes = decode_base64(payload)?;
    if bytes.len() > MAX_BACKUP_BYTES {
        return Err("backup payload exceeds size limit".to_string());
    }
    let (bytes, legacy_password_verifier) = decode_backup_bytes(bytes, password)?;
    if bytes.len() > MAX_BACKUP_BYTES {
        return Err("backup plaintext exceeds size limit".to_string());
    }
    let text = String::from_utf8(bytes).map_err(|err| format!("backup is not UTF-8: {err}"))?;
    if legacy_password_verifier {
        verify_legacy_backup_password(&text, password)?;
    }
    restore_backup(app, &text)?;
    run_magicnet_function(
        app,
        "magicnet_apply_runtime_config; magicnet_wifi_policy_stop; magicnet_wifi_policy_start",
    )?;
    println!("[info] Backup restored");
    Ok(())
}

fn backup_text(app: &App) -> Result<String, String> {
    let mut out = String::from("MagicNet backup v2\n");
    for rel in backup_files() {
        let path = app.moddir.join(rel);
        let length = fs::metadata(&path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        if length > MAX_BACKUP_BYTES as u64 {
            return Err(format!("backup source exceeds size limit: {rel}"));
        }
        let text = fs::read_to_string(path).unwrap_or_default();
        let additional = rel.len() + text.len() + 6;
        if out.len().saturating_add(additional) > MAX_BACKUP_BYTES {
            return Err("backup exceeds size limit".to_string());
        }
        out.push_str(&format!("--- {rel}\n"));
        out.push_str(&text);
        if !text.is_empty() && !text.ends_with('\n') {
            out.push('\n');
        }
    }
    Ok(out)
}

const ENCRYPTED_V1_PREFIX: &[u8] = b"MagicNet encrypted backup v1\n";
const ENCRYPTED_V2_PREFIX: &[u8] = b"MagicNet encrypted backup v2\n";
const V2_SALT_LEN: usize = 16;

fn encode_backup_bytes(text: &str, password: &str) -> Result<Vec<u8>, String> {
    if password.is_empty() {
        return Ok(text.as_bytes().to_vec());
    }

    let mut salt = [0_u8; V2_SALT_LEN];
    OsRng.fill_bytes(&mut salt);
    let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
    let key = derive_v2_key(password, &salt)?;
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&key));
    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: text.as_bytes(),
                aad: ENCRYPTED_V2_PREFIX,
            },
        )
        .map_err(|_| "backup encryption failed".to_string())?;

    let mut out = ENCRYPTED_V2_PREFIX.to_vec();
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

fn decode_backup_bytes(bytes: Vec<u8>, password: &str) -> Result<(Vec<u8>, bool), String> {
    if bytes.starts_with(ENCRYPTED_V2_PREFIX) {
        if password == "-" || password.is_empty() {
            return Err("backup requires a safety code".to_string());
        }
        let envelope = &bytes[ENCRYPTED_V2_PREFIX.len()..];
        if envelope.len() < V2_SALT_LEN + XNonce::default().len() + 16 {
            return Err("backup authentication failed".to_string());
        }
        let (salt, envelope) = envelope.split_at(V2_SALT_LEN);
        let (nonce, ciphertext) = envelope.split_at(XNonce::default().len());
        let key = derive_v2_key(password, salt)?;
        let cipher = XChaCha20Poly1305::new(Key::from_slice(&key));
        let plaintext = cipher
            .decrypt(
                XNonce::from_slice(nonce),
                Payload {
                    msg: ciphertext,
                    aad: ENCRYPTED_V2_PREFIX,
                },
            )
            // Do not distinguish a wrong safety code from a modified envelope.
            .map_err(|_| "backup authentication failed".to_string())?;
        return Ok((plaintext, false));
    }
    if !bytes.starts_with(ENCRYPTED_V1_PREFIX) {
        return Ok((bytes, true));
    }
    if password == "-" || password.is_empty() {
        return Err("backup requires a safety code".to_string());
    }
    Ok((
        xor_with_password(&bytes[ENCRYPTED_V1_PREFIX.len()..], password),
        true,
    ))
}

fn derive_v2_key(password: &str, salt: &[u8]) -> Result<[u8; 32], String> {
    // OWASP's minimum interactive Argon2id profile: 19 MiB, two passes, one lane.
    let params = Params::new(19 * 1024, 2, 1, Some(32))
        .map_err(|_| "backup encryption parameters are invalid".to_string())?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = [0_u8; 32];
    argon2
        .hash_password_into(password.as_bytes(), salt, &mut key)
        .map_err(|_| "backup key derivation failed".to_string())?;
    Ok(key)
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

fn verify_legacy_backup_password(text: &str, password: &str) -> Result<(), String> {
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
    if text.len() > MAX_BACKUP_BYTES {
        return Err("backup plaintext exceeds size limit".to_string());
    }
    if !matches!(
        text.lines().next(),
        Some("MagicNet backup v1" | "MagicNet backup v2")
    ) {
        return Err("backup header is invalid".to_string());
    }
    let mut current: Option<String> = None;
    let mut buf = String::new();
    let mut sections = Vec::new();
    for line in text.lines() {
        if let Some(path) = line.strip_prefix("--- ") {
            collect_restore_section(&mut sections, current.take(), &buf);
            current = Some(path.to_string());
            buf.clear();
        } else if current.is_some() {
            buf.push_str(line);
            buf.push('\n');
        }
    }
    collect_restore_section(&mut sections, current, &buf);

    // Parse and validate the complete backup before touching any persisted
    // configuration. The previous streaming restore could replace early files
    // and then fail on a later malformed section, leaving disk and runtime
    // configuration out of sync.
    let mut seen = HashSet::new();
    let mut replacements = Vec::new();
    for (rel, text) in sections {
        if !backup_files().contains(&rel.as_str()) {
            continue;
        }
        if !seen.insert(rel.clone()) {
            return Err(format!(
                "refusing to restore duplicate config section: {rel}"
            ));
        }
        // The export format includes empty sections for known files. An
        // absent repository settings file means “use the pinned default”; do
        // not replace that default with an invalid empty file on restore.
        if rel == ".config/magicnet/singbox-config-repo.conf" && text.trim().is_empty() {
            continue;
        }
        validate_restore_section(&rel, &text)?;
        replacements.push((PathBuf::from(rel), text));
    }
    if replacements.is_empty() {
        return Ok(());
    }
    let replacement_refs = replacements
        .iter()
        .map(|(path, text)| (path.as_path(), text.as_str()))
        .collect::<Vec<_>>();
    replace_module_text_files_transactionally(app, &replacement_refs)
}

fn collect_restore_section(sections: &mut Vec<(String, String)>, rel: Option<String>, text: &str) {
    let Some(rel) = rel else {
        return;
    };
    sections.push((rel, text.to_string()));
}

fn validate_restore_section(rel: &str, text: &str) -> Result<(), String> {
    // `.conf` files are `.`-sourced by the shell library. A shell-inert value
    // alone is not enough: unknown keys such as PATH can still change the
    // runtime environment. Each restored file therefore has its own fixed
    // schema and value domain.
    if rel.ends_with(".conf") && !sourced_conf_content_matches_schema(rel, text) {
        return Err(format!(
            "refusing to restore {rel}: file is shell-sourced and violates its allowlisted schema"
        ));
    }
    if rel == ".config/sing-box/subscription.user-agent" {
        let value = text.strip_suffix('\n').unwrap_or(text);
        if value.contains('\r')
            || value.contains('\n')
            || (!value.is_empty() && validate_subscription_user_agent(value).is_err())
        {
            return Err(format!(
                "refusing to restore {rel}: invalid subscription User-Agent"
            ));
        }
    }
    if rel == ".config/sing-box/subscription.local"
        && (text.len() > 8 * 1024 * 1024 || text.contains('\0'))
    {
        return Err(format!(
            "refusing to restore {rel}: invalid local subscription source"
        ));
    }
    if rel == ".config/sing-box/subscription-filter.list" {
        let normalized = normalize_subscription_filter_text(text)
            .map_err(|_| format!("refusing to restore {rel}: invalid subscription filter list"))?;
        if normalized != text {
            return Err(format!(
                "refusing to restore {rel}: subscription filter list is not normalized"
            ));
        }
    }
    Ok(())
}

/// Whether every line of a shell-sourced configuration file belongs to its
/// file-specific key and value allowlist. Empty lines and comments are kept so
/// existing user-facing config formatting survives a backup round trip.
fn sourced_conf_content_matches_schema(rel: &str, text: &str) -> bool {
    if rel == ".config/magicnet/singbox-config-repo.conf" {
        return text.trim().is_empty() || validate_repository_config_text(text);
    }
    text.lines()
        .all(|line| sourced_conf_line_matches_schema(rel, line))
}

fn sourced_conf_line_matches_schema(rel: &str, line: &str) -> bool {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return true;
    }
    let Some((key, value)) = line.split_once('=') else {
        return false;
    };
    shell_inert_conf_value(value) && sourced_conf_value_is_allowed(rel, key, value)
}

fn sourced_conf_value_is_allowed(rel: &str, key: &str, value: &str) -> bool {
    match (rel, key) {
        (".config/magicnet/app-mode.conf", "MAGICNET_APP_MODE") => {
            matches!(value, "blacklist" | "whitelist")
        }
        (".config/magicnet/block.conf", "MAGICNET_BLOCK_ENABLED")
        | (".config/magicnet/block.conf", "MAGICNET_BLOCK_COMMUNITY_ENABLED") => {
            matches!(value, "0" | "1")
        }
        (".config/magicnet/block.conf", "MAGICNET_BLOCK_URL") => {
            validate_subscription_url(value).is_ok()
        }
        (".config/magicnet/dns.conf", "MAGICNET_DNS_PROFILE") => matches!(
            value,
            "default"
                | "system"
                | "local"
                | "cloudflare"
                | "cloudflare-doh"
                | "1.1.1.1-doh"
                | "doh"
                | "cloudflare-dot"
                | "1.1.1.1-dot"
                | "dot"
                | "cloudflare-udp"
                | "1.1.1.1"
                | "udp"
        ),
        (".config/magicnet/warp.conf", "MAGICNET_WARP_ENABLED") => {
            matches!(
                value,
                "0" | "1" | "true" | "false" | "yes" | "no" | "on" | "off"
            )
        }
        (".config/magicnet/transparent-mode.conf", "MAGICNET_TRANSPARENT_MODE") => {
            matches!(value, "tun" | "ebpf")
        }
        (".config/magicnet/network-policy.conf", "MAGICNET_IPV6_MODE") => {
            matches!(value, "ipv4_only" | "prefer_ipv4" | "prefer_ipv6")
        }
        (".config/magicnet/network-policy.conf", "MAGICNET_TUN_MTU") => value
            .parse::<u16>()
            .map(|mtu| (1280..=1500).contains(&mtu))
            .unwrap_or(false),
        (".config/magicnet/network-policy.conf", "MAGICNET_UDP_TIMEOUT") => {
            matches!(value, "1m" | "3m" | "5m" | "10m" | "15m" | "30m")
        }
        (".config/magicnet/wifi-policy.conf", "MAGICNET_WIFI_POLICY_ENABLED") => {
            matches!(value, "0" | "1")
        }
        (".config/magicnet/wifi-policy.conf", "MAGICNET_WIFI_POLICY_MODE") => {
            value.eq_ignore_ascii_case("blacklist") || value.eq_ignore_ascii_case("whitelist")
        }
        (".config/magicnet/wifi-policy.conf", "MAGICNET_WIFI_POLICY_INTERVAL") => value
            .parse::<u64>()
            .map(|seconds| (3..=300).contains(&seconds))
            .unwrap_or(false),
        _ => false,
    }
}

fn backup_files() -> &'static [&'static str] {
    &[
        ".config/sing-box/subscription.url",
        ".config/sing-box/subscription.local",
        ".config/sing-box/subscription.user-agent",
        ".config/sing-box/subscription-filter.list",
        ".config/magicnet/app-mode.conf",
        ".config/magicnet/app-proxy.list",
        ".config/magicnet/app-direct.list",
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
        ".config/magicnet/singbox-config-repo.conf",
        ".config/magicnet/transparent-mode.conf",
        ".config/magicnet/network-policy.conf",
        ".config/magicnet/wifi-policy.conf",
        ".config/magicnet/wifi-ssid.list",
        ".config/magicnet/wifi-bssid.list",
    ]
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use super::*;
    use crate::test_support::temp_app;

    fn legacy_v1_backup_text(digest_parts: [&str; 2]) -> String {
        let digest = digest_parts.concat();
        format!("MagicNet backup v1\npassword_set=1\npassword_md5={digest}\n")
    }

    #[test]
    fn restore_rejects_unversioned_payload_before_parsing_sections() {
        let app = temp_app();
        let error = restore_backup(
            &app,
            "--- .config/magicnet/app-mode.conf\nMAGICNET_APP_MODE=whitelist\n",
        )
        .unwrap_err();
        assert_eq!(error, "backup header is invalid");
        assert!(!app.moddir.join(".config/magicnet/app-mode.conf").exists());
    }

    #[test]
    fn backup_without_password_is_plaintext_and_restores_known_files_only() {
        let app = temp_app();
        let app_mode = app.moddir.join(".config/magicnet/app-mode.conf");
        fs::create_dir_all(app_mode.parent().expect("app mode parent")).unwrap();
        fs::write(&app_mode, "MAGICNET_APP_MODE=whitelist\n").unwrap();
        let text = backup_text(&app).unwrap();

        assert!(text.starts_with("MagicNet backup v2\n"));
        assert!(!text.contains("password_md5="));
        assert_eq!(encode_backup_bytes(&text, "").unwrap(), text.as_bytes());

        let restore_app = temp_app();
        let restore_text = format!("{text}\n--- ../ignored\nnope\n");
        restore_backup(&restore_app, &restore_text).unwrap();
        let restored =
            fs::read_to_string(restore_app.moddir.join(".config/magicnet/app-mode.conf")).unwrap();
        assert!(restored.starts_with("MAGICNET_APP_MODE=whitelist\n"));
        assert_eq!(
            fs::read_to_string(
                restore_app
                    .moddir
                    .join(".config/sing-box/subscription-filter.list")
            )
            .unwrap(),
            ""
        );
        assert_eq!(
            fs::read_to_string(restore_app.moddir.join(".config/magicnet/block.conf")).unwrap(),
            ""
        );
        assert!(!restore_app.moddir.join("../ignored").exists());
    }

    #[test]
    fn restore_rejects_shell_injection_into_sourced_conf() {
        let app = temp_app();
        // A password-less backup that smuggles a command substitution into the
        // shell-sourced block.conf must be refused, not written.
        let text = concat!(
            "MagicNet backup v1\n",
            "password_set=0\n",
            "\n",
            "--- .config/magicnet/block.conf\n",
            "MAGICNET_BLOCK_ENABLED=1\n",
            "id > /data/local/tmp/pwned; reboot\n",
        );
        let err = restore_backup(&app, text).unwrap_err();
        assert!(err.contains("block.conf"), "unexpected error: {err}");
        assert!(!app.moddir.join(".config/magicnet/block.conf").exists());
    }

    #[test]
    fn restore_validation_failure_leaves_every_existing_config_unchanged() {
        let app = temp_app();
        let subscription = app.moddir.join(".config/sing-box/subscription.user-agent");
        let app_mode = app.moddir.join(".config/magicnet/app-mode.conf");
        fs::create_dir_all(subscription.parent().expect("subscription parent")).unwrap();
        fs::create_dir_all(app_mode.parent().expect("app mode parent")).unwrap();
        fs::write(&subscription, "old-agent\n").unwrap();
        fs::write(&app_mode, "MAGICNET_APP_MODE=blacklist\n").unwrap();

        let text = concat!(
            "MagicNet backup v2\n",
            "--- .config/sing-box/subscription.user-agent\n",
            "new-agent\n",
            "--- .config/magicnet/app-mode.conf\n",
            "MAGICNET_APP_MODE=whitelist\n",
            "--- .config/magicnet/dns.conf\n",
            "PATH=/tmp/invalid\n",
        );
        let err = restore_backup(&app, text).expect_err("invalid final section must abort");

        assert!(err.contains("dns.conf"), "{err}");
        assert_eq!(fs::read_to_string(&subscription).unwrap(), "old-agent\n");
        assert_eq!(
            fs::read_to_string(&app_mode).unwrap(),
            "MAGICNET_APP_MODE=blacklist\n"
        );
        assert!(!app.moddir.join(".config/magicnet/dns.conf").exists());
    }

    #[test]
    fn restore_rejects_duplicate_known_sections_without_writing() {
        let app = temp_app();
        let app_mode = app.moddir.join(".config/magicnet/app-mode.conf");
        fs::create_dir_all(app_mode.parent().expect("app mode parent")).unwrap();
        fs::write(&app_mode, "MAGICNET_APP_MODE=blacklist\n").unwrap();
        let text = concat!(
            "MagicNet backup v2\n",
            "--- .config/magicnet/app-mode.conf\n",
            "MAGICNET_APP_MODE=whitelist\n",
            "--- .config/magicnet/app-mode.conf\n",
            "MAGICNET_APP_MODE=blacklist\n",
        );

        let err = restore_backup(&app, text).expect_err("duplicate section must abort");

        assert!(err.contains("duplicate config section"), "{err}");
        assert_eq!(
            fs::read_to_string(&app_mode).unwrap(),
            "MAGICNET_APP_MODE=blacklist\n"
        );
    }

    #[test]
    fn sourced_conf_schema_accepts_known_values_and_rejects_unknown_or_unsafe_ones() {
        let block = ".config/magicnet/block.conf";
        assert!(sourced_conf_content_matches_schema(
            block,
            "MAGICNET_BLOCK_ENABLED=1\nMAGICNET_BLOCK_COMMUNITY_ENABLED=0\nMAGICNET_BLOCK_URL=https://example.com/list.txt\n# note\n"
        ));
        assert!(!sourced_conf_content_matches_schema(
            block,
            "PATH=/tmp/evil\n"
        ));
        assert!(!sourced_conf_content_matches_schema(
            block,
            "MAGICNET_BLOCK_ENABLED=yes\n"
        ));
        assert!(!sourced_conf_content_matches_schema(
            block,
            "MAGICNET_BLOCK_URL=https://example.com/list;id\n"
        ));
        assert!(!sourced_conf_content_matches_schema(
            block,
            "not a kv line\n"
        ));

        let repository = ".config/magicnet/singbox-config-repo.conf";
        assert!(sourced_conf_content_matches_schema(
            repository,
            "MAGICNET_SINGBOX_CONFIG_REPO_URL=https://github.com/example/repo.git\nMAGICNET_SINGBOX_CONFIG_REPO_REF=main\nMAGICNET_SINGBOX_CONFIG_REPO_PATH=config.json\n"
        ));
        assert!(!sourced_conf_content_matches_schema(
            repository,
            "MAGICNET_SINGBOX_CONFIG_REPO_URL=http://github.com/example/repo\n"
        ));

        let transparent = ".config/magicnet/transparent-mode.conf";
        assert!(sourced_conf_content_matches_schema(
            transparent,
            "MAGICNET_TRANSPARENT_MODE=tun\n"
        ));
        assert!(sourced_conf_content_matches_schema(
            transparent,
            "MAGICNET_TRANSPARENT_MODE=ebpf\n"
        ));
        for invalid in ["auto", "proxy", "external", "external-tun", "hybrid"] {
            assert!(!sourced_conf_content_matches_schema(
                transparent,
                &format!("MAGICNET_TRANSPARENT_MODE={invalid}\n")
            ));
        }

        let network = ".config/magicnet/network-policy.conf";
        assert!(sourced_conf_content_matches_schema(
            network,
            "MAGICNET_IPV6_MODE=prefer_ipv4\nMAGICNET_TUN_MTU=1400\nMAGICNET_UDP_TIMEOUT=5m\n"
        ));
        for invalid in [
            "MAGICNET_IPV6_MODE=ipv6_only\n",
            "MAGICNET_TUN_MTU=1279\n",
            "MAGICNET_TUN_MTU=1501\n",
            "MAGICNET_UDP_TIMEOUT=1h\n",
        ] {
            assert!(!sourced_conf_content_matches_schema(network, invalid));
        }
    }

    #[test]
    fn restore_restricts_secret_backup_files_to_0600() {
        let app = temp_app();
        let text = concat!(
            "MagicNet backup v1\n",
            "password_set=0\n",
            "\n",
            "--- .config/sing-box/subscription.url\n",
            "https://example.com/subscription\n",
            "\n",
            "--- .config/magicnet/warp-endpoint.json\n",
            "{\"private_key\":\"fixture\"}\n",
        );

        restore_backup(&app, text).expect("restore secret-bearing files");

        for rel in [
            ".config/sing-box/subscription.url",
            ".config/magicnet/warp-endpoint.json",
        ] {
            let mode = fs::metadata(app.moddir.join(rel))
                .expect("stat restored secret")
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600, "unexpected mode for {rel}");
        }
    }

    #[test]
    fn v2_encrypted_backup_round_trips_and_is_nondeterministic() {
        let text = "MagicNet backup v2\n\n--- .config/magicnet/app-mode.conf\nMAGICNET_APP_MODE=whitelist\n";
        let first = encode_backup_bytes(text, "abc").unwrap();
        let second = encode_backup_bytes(text, "abc").unwrap();

        assert!(first.starts_with(ENCRYPTED_V2_PREFIX));
        assert_ne!(first, second, "each export needs a fresh salt and nonce");
        let (decoded, legacy) = decode_backup_bytes(first, "abc").unwrap();
        assert!(!legacy);
        assert_eq!(decoded, text.as_bytes());
    }

    #[test]
    fn v2_encrypted_backup_rejects_wrong_code_and_tampering_before_parsing() {
        let encoded = encode_backup_bytes("MagicNet backup v2\n", "abc").unwrap();

        let wrong_code = decode_backup_bytes(encoded.clone(), "wrong").unwrap_err();
        assert_eq!(wrong_code, "backup authentication failed");

        let mut tampered = encoded;
        *tampered.last_mut().unwrap() ^= 1;
        let tampering = decode_backup_bytes(tampered, "abc").unwrap_err();
        assert_eq!(tampering, "backup authentication failed");
    }

    #[test]
    fn legacy_v1_xor_backup_fixture_remains_importable() {
        let text = legacy_v1_backup_text(["900150983cd24fb0", "d6963f7d28e17f72"]);
        let mut fixture = ENCRYPTED_V1_PREFIX.to_vec();
        fixture.extend(xor_with_password(text.as_bytes(), "abc"));

        let (decoded, legacy) = decode_backup_bytes(fixture, "abc").unwrap();
        assert!(legacy);
        let decoded = String::from_utf8(decoded).unwrap();
        verify_legacy_backup_password(&decoded, "abc").unwrap();
        assert!(verify_legacy_backup_password(&decoded, "wrong")
            .unwrap_err()
            .contains("does not match"));
        let missing_metadata =
            verify_legacy_backup_password("MagicNet backup v1\npassword_set=1\n", "abc")
                .unwrap_err();
        assert!(
            missing_metadata.contains("metadata is missing"),
            "{missing_metadata}"
        );
    }

    #[test]
    fn restore_file_without_password_treats_only_argument_as_path() {
        let app = temp_app();
        let path = app.moddir.join("backup.txt");
        let text = legacy_v1_backup_text(["5ebe2294ecd0e0f0", "8eab7690d2a6ee69"]);
        let encrypted = encode_backup_bytes(&text, "secret").unwrap();
        fs::create_dir_all(&app.moddir).unwrap();
        fs::write(&path, crate::encode_base64(&encrypted)).unwrap();

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
        let text = legacy_v1_backup_text(["900150983cd24fb0", "d6963f7d28e17f72"]);
        let mut encrypted = ENCRYPTED_V1_PREFIX.to_vec();
        encrypted.extend(xor_with_password(text.as_bytes(), "secret"));
        fs::create_dir_all(&app.moddir).unwrap();
        fs::write(&path, crate::encode_base64(&encrypted)).unwrap();
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
