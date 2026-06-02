use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

#[derive(Clone)]
struct App {
    moddir: PathBuf,
    legacy: PathBuf,
    api: String,
    mihomo_webui: String,
    singbox_webui: String,
    log_dir: PathBuf,
}

fn main() {
    let app = App::from_env();
    let args: Vec<String> = env::args().skip(1).collect();
    let code = match dispatch(&app, &args) {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("[error] {err}");
            1
        }
    };
    std::process::exit(code);
}

impl App {
    fn from_env() -> Self {
        let moddir = env::var("MODDIR")
            .map(PathBuf::from)
            .or_else(|_| current_exe_moddir())
            .unwrap_or_else(|_| PathBuf::from("/data/adb/modules/MagicNet"));
        let api = env::var("MAGICNET_API").unwrap_or_else(|_| "http://127.0.0.1:9090".to_string());
        let mihomo_webui =
            env::var("MAGICNET_MIHOMO_WEBUI").unwrap_or_else(|_| format!("{api}/ui/cubex/"));
        let singbox_webui = env::var("MAGICNET_SINGBOX_WEBUI")
            .unwrap_or_else(|_| format!("{api}/ui/#/setup?hostname=127.0.0.1&port=9090"));
        Self {
            legacy: moddir.join("cli.legacy.sh"),
            log_dir: moddir.join(".log"),
            moddir,
            api,
            mihomo_webui,
            singbox_webui,
        }
    }
}

fn current_exe_moddir() -> io::Result<PathBuf> {
    let exe = env::current_exe()?;
    Ok(exe
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("/data/adb/modules/MagicNet")))
}

fn dispatch(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("help") {
        "service" if args.get(1).map(String::as_str).unwrap_or("status") == "status" => {
            service_status(app);
            Ok(())
        }
        "service" if args.get(1).map(String::as_str) == Some("logs") => service_logs(app, args),
        "core" if args.get(1).map(String::as_str).unwrap_or("status") == "status" => {
            core_status(app);
            Ok(())
        }
        "node" if args.get(1).map(String::as_str).unwrap_or("list") == "list" => {
            node_list(app);
            Ok(())
        }
        "sub" if args.get(1).map(String::as_str) == Some("list") => {
            sub_list(app);
            Ok(())
        }
        "sub" if args.get(1).map(String::as_str) == Some("get") => {
            sub_get(app, args.get(2).map(String::as_str).unwrap_or("sing-box"));
            Ok(())
        }
        "sub" if args.get(1).map(String::as_str) == Some("set") => sub_set(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("set-file") => sub_set_file(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("filter-free") => {
            sub_filter_free(app, &args[2..])
        }
        "sub"
            if matches!(
                args.get(1).map(String::as_str),
                Some("file") | Some("copy-path")
            ) =>
        {
            println!(
                "{}",
                sub_target_file(app, args.get(2).map(String::as_str).unwrap_or("sing-box"))
                    .display()
            );
            Ok(())
        }
        "route" if args.get(1).map(String::as_str).unwrap_or("list") == "list" => {
            route_list(app);
            Ok(())
        }
        "capture" if args.get(1).map(String::as_str).unwrap_or("list") == "list" => {
            capture_list(app);
            Ok(())
        }
        "cert" if args.get(1).map(String::as_str).unwrap_or("list") == "list" => {
            cert_list(app);
            Ok(())
        }
        "cert" if args.get(1).map(String::as_str) == Some("dir") => {
            println!(
                "{}",
                app.moddir.join("system/etc/security/cacerts").display()
            );
            Ok(())
        }
        "app" if args.get(1).map(String::as_str).unwrap_or("list") == "list" => {
            app_list(app);
            Ok(())
        }
        "block" if args.get(1).map(String::as_str).unwrap_or("list") == "list" => {
            block_list(app);
            Ok(())
        }
        "mcp" => mcp(app, &args[1..]),
        "webui" if args.get(1).map(String::as_str).unwrap_or("status") == "status" => {
            webui_status(app);
            Ok(())
        }
        "api" if args.get(1).map(String::as_str) == Some("ui") => {
            api_ui(app, args.get(2).map(String::as_str).unwrap_or("current"));
            Ok(())
        }
        "help" | "-h" | "--help" => {
            help();
            Ok(())
        }
        _ => legacy(app, args),
    }
}

fn legacy(app: &App, args: &[String]) -> Result<(), String> {
    if !app.legacy.exists() {
        return Err(format!("legacy CLI missing: {}", app.legacy.display()));
    }
    let status = Command::new(&app.legacy)
        .args(args)
        .env("MODDIR", &app.moddir)
        .status()
        .map_err(|err| format!("failed to run legacy CLI: {err}"))?;
    if status.success() {
        Ok(())
    } else {
        std::process::exit(status.code().unwrap_or(1));
    }
}

fn pid_summary(name: &str) -> String {
    let mut pids = Vec::new();
    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let file_name = entry.file_name();
            let Some(pid) = file_name
                .to_str()
                .filter(|value| value.bytes().all(|b| b.is_ascii_digit()))
            else {
                continue;
            };
            let comm = entry.path().join("comm");
            if fs::read_to_string(comm)
                .map(|value| value.trim() == name)
                .unwrap_or(false)
            {
                pids.push(pid.to_string());
            }
        }
    }
    if pids.is_empty() {
        "stopped".to_string()
    } else {
        pids.join(",")
    }
}

fn service_status(app: &App) {
    let singbox = pid_summary("sing-box");
    let mihomo = pid_summary("mihomo");
    let webui = if singbox != "stopped" {
        &app.singbox_webui
    } else if mihomo != "stopped" {
        &app.mihomo_webui
    } else {
        &app.mihomo_webui
    };
    println!("MagicNet");
    println!("  sing-box: {singbox}");
    println!(
        "  sing-box-disabled: {}",
        bool_file(app.moddir.join(".disable_sing_box")) as u8
    );
    println!("  mihomo:   {mihomo}");
    println!("  watchdog: {}", pid_summary("watchdog"));
    println!("  fswatch:  {}", pid_summary("fswatch"));
    println!("  Transparent: {}", transparent_mode(app));
    println!("  API:      {}", app.api);
    println!("  WebUI:    {webui}");
    println!(
        "  Sub URL:  {}",
        app.moddir
            .join(".config/sing-box/subscription.url")
            .display()
    );
}

fn transparent_mode(app: &App) -> &'static str {
    let path = app.moddir.join(".config/magicnet/transparent-mode.conf");
    fs::read_to_string(path)
        .ok()
        .filter(|text| {
            text.lines()
                .any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=tproxy")
        })
        .map(|_| "tproxy")
        .unwrap_or("tun")
}

fn bool_file(path: PathBuf) -> bool {
    path.exists()
}

fn core_status(app: &App) {
    println!(
        "sing-box-disabled={}",
        bool_file(app.moddir.join(".disable_sing_box")) as u8
    );
}

fn service_logs(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or("sing-box");
    let lines = args
        .get(3)
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(120);
    let file = match target {
        "sing-box" | "singbox" | "core" => app.log_dir.join("sing-box.log"),
        "mihomo" => app.log_dir.join("mihomo.log"),
        other => app.log_dir.join(format!("{other}.log")),
    };
    let text = fs::read_to_string(&file)
        .map_err(|err| format!("log not found {}: {err}", file.display()))?;
    for line in tail_lines(&text, lines) {
        println!("{line}");
    }
    Ok(())
}

fn tail_lines(text: &str, lines: usize) -> Vec<&str> {
    let all: Vec<&str> = text.lines().collect();
    let start = all.len().saturating_sub(lines);
    all[start..].to_vec()
}

fn clean_lines(path: PathBuf) -> Vec<String> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(ToOwned::to_owned)
        .collect()
}

fn first_clean_line(path: PathBuf) -> String {
    clean_lines(path).into_iter().next().unwrap_or_default()
}

fn node_list(app: &App) {
    let limit = env::var("MAGICNET_NODE_LIST_LIMIT")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(48);
    let cache = app.moddir.join(".tmp/magicnet-node-list.cache");
    if env::var("MAGICNET_NODE_CACHE").unwrap_or_else(|_| "1".to_string()) != "0" {
        if let Ok(text) = fs::read_to_string(&cache) {
            if !text.trim().is_empty() {
                print!("{text}");
                return;
            }
        }
    }
    let dir = app.moddir.join(".config/mihomo/proxies");
    let mut names = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            if entry.path().extension().and_then(|v| v.to_str()) != Some("yaml") {
                continue;
            }
            let Ok(text) = fs::read_to_string(entry.path()) else {
                continue;
            };
            for line in text.lines() {
                let trimmed = line.trim_start();
                let Some(rest) = trimmed.strip_prefix("- name:") else {
                    continue;
                };
                let name = rest.trim().trim_matches('"').trim_matches('\'').to_string();
                if name.is_empty()
                    || is_builtin_node(&name)
                    || is_obvious_group(&name)
                    || names.contains(&name)
                {
                    continue;
                }
                names.push(name);
                if names.len() >= limit {
                    break;
                }
            }
            if names.len() >= limit {
                break;
            }
        }
    }
    if !names.is_empty() {
        if let Some(parent) = cache.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let text = format!("{}\n", names.join("\n"));
        let _ = fs::write(cache, &text);
        print!("{text}");
    }
}

fn is_builtin_node(name: &str) -> bool {
    matches!(
        name,
        "" | "DIRECT" | "REJECT" | "REJECT-DROP" | "PASS" | "COMPATIBLE"
    )
}

fn is_obvious_group(name: &str) -> bool {
    matches!(name, "GLOBAL" | "Global" | "global")
        || name.contains("选择")
        || name.contains("策略")
        || name.contains("Selector")
        || name.contains("selector")
        || name.contains("URLTest")
        || name.contains("urltest")
        || name.contains("Fallback")
        || name.contains("fallback")
}

fn sub_target_file(app: &App, target: &str) -> PathBuf {
    match target {
        "mihomo" | "clash" => app.moddir.join(".config/mihomo/subscription.url"),
        "sing-box" | "singbox" => app.moddir.join(".config/sing-box/subscription.url"),
        _ => app.moddir.join(".config/sing-box/subscription.url"),
    }
}

fn free_filter_conf_path(app: &App) -> PathBuf {
    app.moddir.join(".config/magicnet/provider-filter.conf")
}

fn free_filter_enabled(app: &App) -> bool {
    fs::read_to_string(free_filter_conf_path(app))
        .ok()
        .map(|text| {
            text.lines()
                .any(|line| line.trim() == "MAGICNET_FILTER_FREE_PROVIDERS=1")
        })
        .unwrap_or(false)
}

fn write_free_filter_conf(app: &App, enabled: bool) -> Result<(), String> {
    write_text_file(
        free_filter_conf_path(app),
        &format!(
            "MAGICNET_FILTER_FREE_PROVIDERS={}\n",
            if enabled { 1 } else { 0 }
        ),
    )
}

fn validate_subscription_url(url: &str) -> Result<(), String> {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("Subscription URL must start with http:// or https://".to_string());
    }
    if url.chars().any(char::is_whitespace) {
        return Err("Subscription URL must not contain whitespace".to_string());
    }
    Ok(())
}

fn write_text_file(path: PathBuf, text: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    fs::write(&path, text).map_err(|err| format!("write {}: {err}", path.display()))
}

fn clear_node_cache(app: &App) {
    let _ = fs::remove_file(app.moddir.join(".tmp/magicnet-node-list.cache"));
}

fn sub_set(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let (provider, url) = match target {
        "mihomo" | "clash" => match (args.get(3), args.get(4)) {
            (Some(provider), Some(url)) => (Some(provider.as_str()), url.as_str()),
            (Some(url), None) => (None, url.as_str()),
            _ => {
                return Err(
                    "Usage: cli sub set <sing-box|mihomo|clash> [provider] <url>".to_string(),
                )
            }
        },
        "sing-box" | "singbox" => match args.get(3) {
            Some(url) => (None, url.as_str()),
            None => {
                return Err(
                    "Usage: cli sub set <sing-box|mihomo|clash> [provider] <url>".to_string(),
                )
            }
        },
        _ => return Err("Subscription target must be sing-box or mihomo".to_string()),
    };
    validate_subscription_url(url)?;
    clear_node_cache(app);
    write_text_file(sub_target_file(app, target), &format!("{url}\n"))?;
    if matches!(target, "mihomo" | "clash") {
        update_mihomo_config_url(app, url, provider)?;
    }
    println!(
        "[info] Saved {target}{} subscription URL to {}",
        provider
            .map(|value| format!(" provider {value}"))
            .unwrap_or_default(),
        sub_target_file(app, target).display()
    );
    Ok(())
}

fn sub_set_file(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let payload = args.get(3).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli sub set-file <sing-box> <base64-lines>".to_string());
    }
    let file = match target {
        "sing-box" | "singbox" => sub_target_file(app, "sing-box"),
        _ => return Err("set-file currently supports sing-box only".to_string()),
    };
    let bytes = decode_base64(payload)?;
    let text =
        String::from_utf8(bytes).map_err(|err| format!("subscription text is not UTF-8: {err}"))?;
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        validate_subscription_url(line)?;
    }
    clear_node_cache(app);
    write_text_file(file.clone(), &text)?;
    println!(
        "[info] Saved sing-box subscription URL list to {}",
        file.display()
    );
    Ok(())
}

fn sub_list(app: &App) {
    for (idx, url) in clean_lines(app.moddir.join(".config/sing-box/subscription.url"))
        .iter()
        .enumerate()
    {
        println!("sing-box.{}={}", idx + 1, url);
    }
    println!(
        "sing-box={}",
        first_clean_line(app.moddir.join(".config/sing-box/subscription.url"))
    );
    println!("free-filter={}", free_filter_enabled(app) as u8);
    for (name, url) in mihomo_providers(app) {
        println!("mihomo.{name}={url}");
    }
    println!(
        "mihomo={}",
        first_clean_line(app.moddir.join(".config/mihomo/subscription.url"))
    );
}

fn sub_filter_free(app: &App, args: &[String]) -> Result<(), String> {
    let enabled = match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            println!("free-filter={}", free_filter_enabled(app) as u8);
            return Ok(());
        }
        "on" | "enable" | "1" => true,
        "off" | "disable" | "0" => false,
        "apply" => free_filter_enabled(app),
        _ => return Err("Usage: cli sub filter-free {status|on|off|apply}".to_string()),
    };
    write_free_filter_conf(app, enabled)?;
    apply_mihomo_provider_filter(app, enabled)?;
    clear_node_cache(app);
    println!(
        "[info] Free provider filter {}",
        if enabled { "enabled" } else { "disabled" }
    );
    Ok(())
}

fn sub_get(app: &App, target: &str) {
    println!("{}", first_clean_line(sub_target_file(app, target)));
}

fn mihomo_provider_key(line: &str) -> Option<String> {
    if !line.starts_with("  ") || line.starts_with("    ") {
        return None;
    }
    let trimmed = line.trim();
    let key = trimmed.split_once(':')?.0.trim();
    if key.is_empty()
        || key.contains(char::is_whitespace)
        || key.ends_with("-http")
        || matches!(key, "health-check" | "type" | "interval" | "path" | "url")
    {
        return None;
    }
    Some(key.to_string())
}

fn mihomo_providers(app: &App) -> Vec<(String, String)> {
    let text =
        fs::read_to_string(app.moddir.join(".config/mihomo/config.yaml")).unwrap_or_default();
    let mut providers = Vec::new();
    let mut in_providers = false;
    let mut current: Option<String> = None;
    for line in text.lines() {
        if matches!(
            line.trim(),
            "proxy-providers:" | "proxy-provider-templates:"
        ) {
            in_providers = true;
            continue;
        }
        if in_providers && !line.starts_with(' ') && line.ends_with(':') {
            break;
        }
        if !in_providers {
            continue;
        }
        let trimmed = line.trim();
        if let Some(provider) = mihomo_provider_key(line) {
            current = Some(provider);
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("url:") {
            if let Some(name) = current.clone() {
                providers.push((
                    name,
                    rest.trim().trim_matches('"').trim_matches('\'').to_string(),
                ));
            }
        }
    }
    providers
}

fn mihomo_config_path(app: &App) -> PathBuf {
    app.moddir.join(".config/mihomo/config.yaml")
}

fn update_mihomo_config_url(
    app: &App,
    url: &str,
    target_provider: Option<&str>,
) -> Result<(), String> {
    let path = mihomo_config_path(app);
    let Ok(text) = fs::read_to_string(&path) else {
        return Ok(());
    };
    let mut out = Vec::new();
    let mut in_providers = false;
    let mut current_provider: Option<String> = None;
    let mut done = false;
    for line in text.lines() {
        let trimmed = line.trim();
        if matches!(trimmed, "proxy-providers:" | "proxy-provider-templates:") {
            in_providers = true;
            out.push(line.to_string());
            continue;
        }
        if in_providers && !line.starts_with(' ') && line.ends_with(':') {
            in_providers = false;
            current_provider = None;
        }
        if in_providers {
            if let Some(provider) = mihomo_provider_key(line) {
                current_provider = Some(provider);
            }
        }
        let provider_matches = target_provider
            .map(|target| current_provider.as_deref() == Some(target))
            .unwrap_or(true);
        if in_providers && provider_matches && !done && trimmed.starts_with("url:") {
            let indent_len = line.len().saturating_sub(line.trim_start().len());
            let indent = &line[..indent_len];
            out.push(format!("{indent}url: \"{url}\""));
            done = true;
            continue;
        }
        out.push(line.to_string());
    }
    if done {
        write_text_file(path, &format!("{}\n", out.join("\n")))?;
    }
    Ok(())
}

fn apply_mihomo_provider_filter(app: &App, enabled: bool) -> Result<(), String> {
    let path = mihomo_config_path(app);
    let Ok(text) = fs::read_to_string(&path) else {
        return Ok(());
    };
    let replacement = if enabled {
        "use: *PREMIUM_PROVIDERS"
    } else {
        "use: *ALL_PROVIDERS"
    };
    let mut changed = false;
    let mut out = Vec::new();
    for line in text.lines() {
        if line.trim() == "use: *ALL_PROVIDERS" || line.trim() == "use: *PREMIUM_PROVIDERS" {
            let indent_len = line.len().saturating_sub(line.trim_start().len());
            let indent = &line[..indent_len];
            let next = format!("{indent}{replacement}");
            if next != line {
                changed = true;
            }
            out.push(next);
        } else {
            out.push(line.to_string());
        }
    }
    if changed {
        write_text_file(path, &format!("{}\n", out.join("\n")))?;
    }
    Ok(())
}

fn route_list(app: &App) {
    for target in ["proxy", "direct", "block"] {
        println!("{target} domain suffixes:");
        for line in clean_lines(app.moddir.join(format!(
            ".config/magicnet/route-{target}-domain-suffix.list"
        ))) {
            println!("  {line}");
        }
    }
}

fn capture_list(app: &App) {
    let conf = read_kv(app.moddir.join(".config/magicnet/capture.conf"));
    println!(
        "enabled={}",
        conf.get("MAGICNET_CAPTURE_ENABLED")
            .map(String::as_str)
            .unwrap_or("0")
    );
    println!(
        "host={}",
        conf.get("MAGICNET_CAPTURE_HOST")
            .map(String::as_str)
            .unwrap_or("192.168.1.100")
    );
    println!(
        "port={}",
        conf.get("MAGICNET_CAPTURE_PORT")
            .map(String::as_str)
            .unwrap_or("8888")
    );
    println!(
        "name={}",
        conf.get("MAGICNET_CAPTURE_NAME")
            .map(String::as_str)
            .unwrap_or("MagicNet-Capture")
    );
    println!("apps:");
    for line in clean_lines(app.moddir.join(".config/magicnet/capture-app.list")) {
        println!("  {line}");
    }
    println!("domain suffixes:");
    for line in clean_lines(
        app.moddir
            .join(".config/magicnet/capture-domain-suffix.list"),
    ) {
        println!("  {line}");
    }
}

fn cert_list(app: &App) {
    let dir = app.moddir.join("system/etc/security/cacerts");
    println!("dir={}", dir.display());
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            if entry.file_type().map(|ft| ft.is_file()).unwrap_or(false) {
                println!("{}", entry.file_name().to_string_lossy());
            }
        }
    }
}

fn app_list(app: &App) {
    let conf = read_kv(app.moddir.join(".config/magicnet/app-mode.conf"));
    println!(
        "mode={}",
        conf.get("MAGICNET_APP_MODE")
            .map(String::as_str)
            .unwrap_or("blacklist")
    );
    println!("proxy apps:");
    for line in clean_lines(app.moddir.join(".config/magicnet/app-proxy.list")) {
        println!("  {line}");
    }
    println!("bypass apps:");
    for line in clean_lines(app.moddir.join(".config/magicnet/app-bypass.list")) {
        println!("  {line}");
    }
}

fn block_list(app: &App) {
    let dir = app.moddir.join(".config/magicnet");
    let conf = read_kv(dir.join("block.conf"));
    println!(
        "enabled={}",
        conf.get("MAGICNET_BLOCK_ENABLED")
            .map(String::as_str)
            .unwrap_or("1")
    );
    println!(
        "community={}",
        conf.get("MAGICNET_BLOCK_COMMUNITY_ENABLED")
            .map(String::as_str)
            .unwrap_or("1")
    );
    println!(
        "url={}",
        conf.get("MAGICNET_BLOCK_URL")
            .map(String::as_str)
            .unwrap_or("https://raw.githubusercontent.com/LIghtJUNction/MagicMihomo/main/ruleset/magicnet/ban.yaml")
    );
    println!("manual domain suffixes:");
    for line in clean_lines(dir.join("block-domain-suffix.list")) {
        println!("  {line}");
    }
    let allow = clean_lines(dir.join("block-allow-rules.list"));
    println!("community rules:");
    for line in clean_lines(dir.join("community-ban-rules.list")) {
        if !allow.contains(&line) {
            println!("  {line}");
        }
    }
    println!("community domain suffixes:");
    for line in clean_lines(dir.join("community-ban-domain-suffix.list")) {
        println!("  {line}");
    }
    println!("local allow rules:");
    for line in allow {
        println!("  {line}");
    }
}

fn read_kv(path: PathBuf) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let text = fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        map.insert(key.trim().to_string(), value);
    }
    map
}

fn mcp_conf_path(app: &App) -> PathBuf {
    app.moddir.join(".config/magicnet/mcp.conf")
}

fn mcp_pid_path(app: &App) -> PathBuf {
    env::var("KAM_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| app.moddir.clone())
        .join(".state/magicnet-mcp.pid")
}

fn mcp_load(app: &App) -> (String, String, String) {
    let conf = read_kv(mcp_conf_path(app));
    (
        conf.get("MAGICNET_MCP_ENABLED")
            .cloned()
            .unwrap_or_else(|| "0".to_string()),
        conf.get("MAGICNET_MCP_BIND")
            .cloned()
            .unwrap_or_else(|| "127.0.0.1".to_string()),
        conf.get("MAGICNET_MCP_PORT")
            .cloned()
            .unwrap_or_else(|| "8765".to_string()),
    )
}

fn mcp_write(app: &App, enabled: &str, bind: &str, port: &str) -> Result<(), String> {
    let path = mcp_conf_path(app);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    fs::write(
        path,
        format!(
            "MAGICNET_MCP_ENABLED={enabled}\nMAGICNET_MCP_BIND={bind}\nMAGICNET_MCP_PORT={port}\n"
        ),
    )
    .map_err(|err| format!("write mcp.conf: {err}"))
}

fn live_pid(pid_file: PathBuf) -> Option<i32> {
    let text = fs::read_to_string(pid_file).ok()?;
    let pid = text.trim().parse::<i32>().ok()?;
    if Path::new("/proc").join(pid.to_string()).exists() {
        Some(pid)
    } else {
        None
    }
}

fn mcp(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            let (enabled, bind, port) = mcp_load(app);
            println!("enabled={enabled}");
            println!("bind={bind}");
            println!("port={port}");
            if let Some(pid) = live_pid(mcp_pid_path(app)) {
                println!("pid={pid}");
                println!("url=http://{bind}:{port}/mcp");
            } else {
                println!("pid=stopped");
            }
            Ok(())
        }
        "enable" => {
            let (_, bind, port) = mcp_load(app);
            mcp_write(app, "1", &bind, &port)?;
            mcp_start(app)
        }
        "disable" => {
            let (_, bind, port) = mcp_load(app);
            mcp_write(app, "0", &bind, &port)?;
            mcp_stop(app)
        }
        "start" => mcp_start(app),
        "stop" => mcp_stop(app),
        "restart" => {
            let _ = mcp_stop(app);
            mcp_start(app)
        }
        _ => Err("Usage: cli mcp {status|enable|disable|start|stop|restart}".to_string()),
    }
}

fn mcp_start(app: &App) -> Result<(), String> {
    let (_, bind, port) = mcp_load(app);
    if let Some(pid) = live_pid(mcp_pid_path(app)) {
        println!("[info] MCP server already running: {pid}");
        return mcp(app, &[String::from("status")]);
    }
    let bin = app.moddir.join(".local/bin/magicnet-mcp-server");
    let fallback = app.moddir.join("mcp-server.sh");
    let target = if bin.exists() { bin } else { fallback };
    if !target.exists() {
        return Err(format!("MCP server missing: {}", target.display()));
    }
    fs::create_dir_all(app.log_dir.clone()).map_err(|err| format!("mkdir log dir: {err}"))?;
    if let Some(parent) = mcp_pid_path(app).parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir state dir: {err}"))?;
    }
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(app.log_dir.join("mcp-server.log"))
        .map_err(|err| format!("open mcp log: {err}"))?;
    let log_err = log
        .try_clone()
        .map_err(|err| format!("clone mcp log: {err}"))?;
    let mut command = Command::new(&target);
    if target.file_name().and_then(|v| v.to_str()) == Some("mcp-server.sh") {
        command.arg("serve");
    }
    let child = command
        .env("MODDIR", &app.moddir)
        .env("MAGICNET_MCP_BIND", &bind)
        .env("MAGICNET_MCP_PORT", &port)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
        .map_err(|err| format!("start MCP server: {err}"))?;
    let pid = child.id();
    fs::write(mcp_pid_path(app), format!("{pid}\n")).map_err(|err| format!("write pid: {err}"))?;
    thread::sleep(Duration::from_millis(350));
    if Path::new("/proc").join(pid.to_string()).exists() {
        println!("[info] MCP server started: http://{bind}:{port}/mcp");
        Ok(())
    } else {
        Err(format!(
            "MCP server failed to start; see {}",
            app.log_dir.join("mcp-server.log").display()
        ))
    }
}

fn mcp_stop(app: &App) -> Result<(), String> {
    if let Some(pid) = live_pid(mcp_pid_path(app)) {
        let _ = Command::new("kill").arg(pid.to_string()).status();
        thread::sleep(Duration::from_millis(250));
        if Path::new("/proc").join(pid.to_string()).exists() {
            let _ = Command::new("kill").arg("-9").arg(pid.to_string()).status();
        }
    }
    let _ = fs::remove_file(mcp_pid_path(app));
    println!("[info] MCP server stopped");
    Ok(())
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
        _ => {
            let singbox = pid_summary("sing-box");
            if singbox != "stopped" {
                println!("{}", app.singbox_webui);
            } else {
                println!("{}", app.mihomo_webui);
            }
        }
    }
}

fn help() {
    println!(
        "MagicNet CLI\n\nUsage:\n  cli service {{status|start|ensure|stop|restart [current|sing-box|mihomo|auto]|toggle <sing-box|mihomo>|logs [sing-box|mihomo] [lines]}}\n  cli health\n  cli pingtest\n  cli topology\n  cli sysroute {{list|snapshot|add-rule <priority> <table>|del-rule <priority>|add-route <table> <dest|default> <dev> [via]|del-route <table> <dest|default>}}\n  cli repair\n  cli support bundle\n  cli setup <subscription-url>\n  cli config {{apply}}\n  cli config-editor {{get|path|validate|save}} <mihomo|sing-box> [base64-config]\n  cli transparent {{status|set <tun|tproxy>|apply}}\n  cli core {{status|sing-box {{status|enable|disable|toggle}}}}\n  cli node {{list|current|use <name>}}\n  cli mode [rule|global|direct]\n  cli route {{list|add-domain <proxy|direct|block> <domain-suffix>|remove-domain <proxy|direct|block> <domain-suffix>|apply}}\n  cli sub {{update|update-all|list|get <sing-box|mihomo>|set <sing-box|mihomo|clash> [provider] <url>|set-file <sing-box> <base64-lines>|filter-free {{status|on|off|apply}}|file [sing-box|mihomo]}}\n  cli cert {{list|install <name|hash.0> <base64-cert>|remove <filename.0>|dir}}\n  cli capture {{list|set <host> <port> [name]|enable|disable|add-app <package>|remove-app <package>|add-domain <suffix>|remove-domain <suffix>|apply}}\n  cli block {{list|enable|disable|community <on|off>|url <http-url>|update|add-domain <suffix>|remove-domain <suffix>|allow-rule <rule>|unallow-rule <rule>|diff|apply}}\n  cli mcp {{status|enable|disable|start|stop|restart}}\n  cli webui {{status|install-local <download-url> [name]}}\n  cli backup {{export [password]|restore [password|-] <base64>}}\n  cli api {{ui [current|mihomo|sing-box|all]|groups|conns|stats|close-all}}\n  cli app {{list|mode <blacklist|whitelist>|add <package> [proxy|bypass]|remove <package>|apply}}\n  cli hotspot reload\n  cli vpn reload\n  cli diagnose"
    );
}

#[allow(dead_code)]
fn safe_module_path(app: &App, rel: &str) -> Result<PathBuf, String> {
    let rel = rel.trim_start_matches('/');
    let path = Path::new(rel);
    for component in path.components() {
        match component {
            Component::Normal(_) => {}
            _ => return Err("invalid path".to_string()),
        }
    }
    Ok(app.moddir.join(path))
}

#[allow(dead_code)]
fn read_stdin() -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    io::stdin().read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(input.len() * 3 / 4);
    let mut buf = 0_u32;
    let mut bits = 0_u8;
    for byte in input.bytes().filter(|b| !b.is_ascii_whitespace()) {
        if byte == b'=' {
            break;
        }
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return Err(format!("invalid base64 byte {byte}")),
        } as u32;
        buf = (buf << 6) | value;
        bits += 6;
        while bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xff) as u8);
        }
    }
    Ok(out)
}
