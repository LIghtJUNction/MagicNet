use std::fs;
use std::process::Command;

use serde_json::json;

use crate::connection_control::{
    close_connections_through_chain, close_matching_connections, close_top_connections,
    print_close_all_summary,
};
use crate::service::singbox_webui;
use crate::{run_magicnet_function, write_text_file, App};

pub(crate) fn api_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or_default() {
        "ui" => {
            api_ui(app, args.get(1).map(String::as_str).unwrap_or("current"));
            Ok(())
        }
        "groups" => curl(app, "/providers/proxies"),
        "proxies" => curl(app, "/proxies"),
        "select" => select_proxy(
            app,
            args.get(1).map(String::as_str).unwrap_or_default(),
            &args[2..].join(" "),
        ),
        "conns" => curl(app, "/connections"),
        "stats" => curl(app, "/traffic"),
        "close" => close_connection(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "close-top" => close_top_connections(app, args.get(1).map(String::as_str).unwrap_or("3")),
        "close-matching" => close_matching_connections(app, &args[1..].join(" ")),
        "close-all" => print_close_all_summary(app),
        _ => Err(
            "Usage: cli api {ui [current|sing-box|all]|groups|proxies|select <group> <node>|conns|stats|close <id>|close-top [count]|close-matching <query>|close-all}"
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
        "verify" => webui_verify(app),
        "install-local" => install_local(app, args),
        _ => {
            Err("Usage: cli webui {status|verify|install-local <download-url> [name]}".to_string())
        }
    }
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

fn curl_put_json(app: &App, path: &str, payload: &str) -> Result<(), String> {
    run_curl(&[
        "-fsS",
        "-X",
        "PUT",
        "-H",
        "Content-Type: application/json",
        "--data",
        payload,
        "--max-time",
        "5",
        &format!("{}{}", app.api, path),
    ])
}

fn select_proxy(app: &App, group: &str, node: &str) -> Result<(), String> {
    let clean_group = group.trim();
    let clean_node = node.trim();
    if clean_group.is_empty() || clean_node.is_empty() {
        return Err("Usage: cli api select <group> <node>".to_string());
    }
    let payload = json!({ "name": clean_node }).to_string();
    curl_put_json(
        app,
        &format!("/proxies/{}", encode_path_segment(clean_group)),
        &payload,
    )?;
    match close_connections_through_chain(app, clean_group) {
        Ok(summary) => {
            println!(
                "[info] {clean_group} selector set to {clean_node}; closed {}/{} stale connections",
                summary.closed, summary.targets
            );
            Ok(())
        }
        Err(err) => Err(format!(
            "selector changed to {clean_node}, but stale connections were not fully closed: {err}"
        )),
    }
}

fn close_connection(app: &App, id: &str) -> Result<(), String> {
    if id.is_empty() {
        return Err("Usage: cli api close <id>".to_string());
    }
    curl_delete(app, &format!("/connections/{}", encode_path_segment(id)))
}

fn encode_path_segment(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
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
    println!("sing-box={}", singbox_webui(app));
    println!(
        "version={}",
        fs::read_to_string(app.moddir.join("zashboard.version"))
            .unwrap_or_else(|_| "unknown".to_string())
            .lines()
            .next()
            .unwrap_or("unknown")
    );
}

fn webui_verify(app: &App) -> Result<(), String> {
    let module_webui = app.moddir.join("webroot");
    let singbox_panel = app.moddir.join(".config/sing-box/zashboard");
    let checks = [
        ("module_webui", module_webui.as_path()),
        ("singbox_zashboard", singbox_panel.as_path()),
    ];

    let mut failed = Vec::new();
    for (name, dir) in checks {
        let ok = contains_index(dir);
        println!(
            "{name}={} path={}",
            if ok { "ok" } else { "missing" },
            dir.display()
        );
        if !ok {
            failed.push(name);
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("webui verify failed: {}", failed.join(",")))
    }
}

fn api_ui(app: &App, target: &str) {
    match target {
        "sing-box" | "singbox" => println!("{}", singbox_webui(app)),
        "all" => {
            println!("sing-box={}", singbox_webui(app));
        }
        _ => println!("{}", singbox_webui(app)),
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
    run_magicnet_function(app, "magicnet_singbox_apply_zashboard")?;
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

    #[test]
    fn api_connection_id_is_encoded_as_path_segment() {
        assert_eq!(encode_path_segment("abc-123_~"), "abc-123_~");
        assert_eq!(encode_path_segment("id/with space"), "id%2Fwith%20space");
        assert_eq!(encode_path_segment("proxy/final"), "proxy%2Ffinal");
    }

    #[test]
    fn select_proxy_requires_group_and_node() {
        let app = temp_app();
        assert!(select_proxy(&app, "", "node")
            .unwrap_err()
            .contains("Usage"));
        assert!(select_proxy(&app, "proxy", "")
            .unwrap_err()
            .contains("Usage"));
    }
}
