use std::fs;
use std::path::{Path, PathBuf};

use rcgen::{
    date_time_ymd, BasicConstraints, CertificateParams, DistinguishedName, DnType, IsCa, KeyPair,
    KeyUsagePurpose,
};
use x509_parser::prelude::parse_x509_certificate;

use crate::{decode_base64, write_text_file, App};

const DEFAULT_KEY: &str = "magicnet-ca.key.pem";
const DEFAULT_MARKER: &str = "magicnet-ca.default";

pub(crate) fn cert_cmd(app: &App, args: &[String]) -> Result<(), String> {
    let dir = cert_dir(app);
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => {
            cert_list(app);
            Ok(())
        }
        "dir" => {
            println!("{}", dir.display());
            Ok(())
        }
        "ensure-default" | "generate" => cert_ensure_default(app),
        "install" => cert_install(app, args),
        "remove" => cert_remove(app, args),
        _ => Err("Usage: cli cert {list|dir|ensure-default|install <name|hash.0|auto> <base64-cert>|remove <filename.0>}".to_string()),
    }
}

fn cert_list(app: &App) {
    let dir = cert_dir(app);
    println!("dir={}", dir.display());
    println!(
        "default={}",
        default_installed_name(app).unwrap_or_else(|| "missing".to_string())
    );
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries
            .flatten()
            .filter(|entry| entry.file_type().map(|ft| ft.is_file()).unwrap_or(false))
        {
            let name = entry.file_name().to_string_lossy().to_string();
            if name == DEFAULT_KEY || name == DEFAULT_MARKER || !name.ends_with(".0") {
                continue;
            }
            println!("{name}");
        }
    }
}

fn cert_ensure_default(app: &App) -> Result<(), String> {
    let state_dir = app.moddir.join(".config/magicnet/certs");
    fs::create_dir_all(&state_dir)
        .map_err(|err| format!("mkdir {}: {err}", state_dir.display()))?;

    let key_path = state_dir.join(DEFAULT_KEY);
    let key_pair = if key_path.exists() {
        let pem = fs::read_to_string(&key_path)
            .map_err(|err| format!("read {}: {err}", key_path.display()))?;
        KeyPair::from_pem(&pem).map_err(|err| format!("parse default key: {err}"))?
    } else {
        let key = KeyPair::generate().map_err(|err| format!("generate default key: {err}"))?;
        write_text_file(key_path.clone(), &key.serialize_pem())?;
        key
    };

    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, "MagicNet Local CA");
    dn.push(DnType::OrganizationName, "MagicNet");

    let mut params = CertificateParams::default();
    params.not_before = date_time_ymd(2024, 1, 1);
    params.not_after = date_time_ymd(4096, 1, 1);
    params.distinguished_name = dn;
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::CrlSign,
        KeyUsagePurpose::DigitalSignature,
    ];
    let cert = params
        .self_signed(&key_pair)
        .map_err(|err| format!("generate default cert: {err}"))?;
    let pem = cert.pem();
    let filename = android_cert_filename(pem.as_bytes())?;
    let target = cert_dir(app).join(&filename);
    write_text_file(target.clone(), &pem)?;
    write_text_file(state_dir.join(DEFAULT_MARKER), &filename)?;
    println!(
        "[info] MagicNet default CA installed as {}",
        target.display()
    );
    println!("[info] Reboot is required for Android system CA trust to refresh.");
    Ok(())
}

fn cert_install(app: &App, args: &[String]) -> Result<(), String> {
    let name = args.get(1).map(String::as_str).unwrap_or_default();
    let payload = args.get(2).map(String::as_str).unwrap_or_default();
    if name.is_empty() || payload.is_empty() {
        return Err("Usage: cli cert install <name|hash.0|auto> <base64-cert>".to_string());
    }
    let bytes = decode_base64(payload)?;
    let filename = if name == "auto" || !name.ends_with(".0") {
        android_cert_filename(&bytes)?
    } else {
        name.to_string()
    };
    let target = cert_dir(app).join(sanitize_filename(&filename)?);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    fs::write(&target, bytes).map_err(|err| format!("write cert: {err}"))?;
    println!("[info] Installed cert {}", target.display());
    println!("[info] Reboot is required for Android system CA trust to refresh.");
    Ok(())
}

fn cert_remove(app: &App, args: &[String]) -> Result<(), String> {
    let name = args.get(1).map(String::as_str).unwrap_or_default();
    if name.is_empty() {
        return Err("Usage: cli cert remove <filename.0>".to_string());
    }
    let target = cert_dir(app).join(sanitize_filename(name)?);
    let _ = fs::remove_file(&target);
    if default_installed_name(app).as_deref() == Some(name) {
        let _ = fs::remove_file(
            app.moddir
                .join(".config/magicnet/certs")
                .join(DEFAULT_MARKER),
        );
    }
    println!("[info] Removed cert {}", target.display());
    Ok(())
}

fn android_cert_filename(cert: &[u8]) -> Result<String, String> {
    let der = pem_or_der_contents(cert)?;
    let (_, parsed) =
        parse_x509_certificate(&der).map_err(|err| format!("parse x509 cert: {err}"))?;
    let digest = md5::compute(parsed.subject().as_raw());
    let bytes = digest.0;
    let hash = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    Ok(format!("{hash:08x}.0"))
}

fn pem_or_der_contents(input: &[u8]) -> Result<Vec<u8>, String> {
    let text = String::from_utf8_lossy(input);
    if !text.contains("-----BEGIN CERTIFICATE-----") {
        return Ok(input.to_vec());
    }
    let body = text
        .lines()
        .filter(|line| !line.starts_with("-----BEGIN ") && !line.starts_with("-----END "))
        .collect::<String>();
    crate::decode_base64(&body)
}

fn default_installed_name(app: &App) -> Option<String> {
    let name = fs::read_to_string(
        app.moddir
            .join(".config/magicnet/certs")
            .join(DEFAULT_MARKER),
    )
    .ok()?;
    let name = name.trim();
    (!name.is_empty() && cert_dir(app).join(name).exists()).then(|| name.to_string())
}

fn cert_dir(app: &App) -> PathBuf {
    app.moddir.join("system/etc/security/cacerts")
}

fn sanitize_filename(name: &str) -> Result<String, String> {
    if name.contains('/') || name.contains('\\') || name == "." || name == ".." || name.is_empty() {
        return Err("invalid filename".to_string());
    }
    Ok(name.to_string())
}

#[allow(dead_code)]
fn _is_cert_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.ends_with(".0"))
}
