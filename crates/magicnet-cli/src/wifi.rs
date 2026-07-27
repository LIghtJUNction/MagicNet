use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use crate::diagnostics::supervisor_pid;
use crate::utils::command_text_full_timeout;
use crate::webui_api::{current_clash_mode, set_clash_mode};
use crate::{clean_lines, read_kv, run_magicnet_function, write_kv, write_text_file, App};

const DEFAULT_INTERVAL_SECONDS: u64 = 5;
const MIN_INTERVAL_SECONDS: u64 = 3;
const MAX_INTERVAL_SECONDS: u64 = 300;
const STABLE_RECONCILE_SECONDS: u64 = 60;
const NETWORK_CHANGE_CONFIRMATIONS: u8 = 2;
const WIFI_POLICY_CONF: &str = ".config/magicnet/wifi-policy.conf";
const WIFI_SSID_LIST: &str = ".config/magicnet/wifi-ssid.list";
const WIFI_BSSID_LIST: &str = ".config/magicnet/wifi-bssid.list";
const WIFI_LAST_STATE: &str = ".state/wifi-policy/last-state.conf";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PolicyMode {
    Blacklist,
    Whitelist,
}

impl PolicyMode {
    fn parse(value: &str) -> Result<Self, String> {
        match value.trim().to_ascii_lowercase().as_str() {
            "blacklist" => Ok(Self::Blacklist),
            "whitelist" => Ok(Self::Whitelist),
            _ => Err("Wi-Fi policy mode must be blacklist or whitelist".to_string()),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Blacklist => "blacklist",
            Self::Whitelist => "whitelist",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PolicyConfig {
    enabled: bool,
    mode: PolicyMode,
    interval_seconds: u64,
}

impl Default for PolicyConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            mode: PolicyMode::Blacklist,
            interval_seconds: DEFAULT_INTERVAL_SECONDS,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct WifiNetwork {
    connected: bool,
    ssid: Option<String>,
    bssid: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PolicyDecision {
    matched: bool,
    desired_mode: &'static str,
}

pub(crate) fn wifi_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" | "list" => {
            print_status(app);
            Ok(())
        }
        "enable" => set_enabled(app, true),
        "disable" => set_enabled(app, false),
        "mode" => set_policy_mode(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "interval" => set_interval(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "add-ssid" => update_list(app, ListKind::Ssid, &args[1..].join(" "), ListAction::Add),
        "remove-ssid" => update_list(
            app,
            ListKind::Ssid,
            &args[1..].join(" "),
            ListAction::Remove,
        ),
        "add-bssid" => update_list(
            app,
            ListKind::Bssid,
            args.get(1).map(String::as_str).unwrap_or_default(),
            ListAction::Add,
        ),
        "remove-bssid" => update_list(
            app,
            ListKind::Bssid,
            args.get(1).map(String::as_str).unwrap_or_default(),
            ListAction::Remove,
        ),
        "check" => {
            apply_once(app, true)?;
            Ok(())
        }
        "watch" => watch(app),
        _ => Err(wifi_usage()),
    }
}

fn wifi_usage() -> String {
    "Usage: cli wifi {status|enable|disable|mode <blacklist|whitelist>|interval <3-300>|add-ssid <ssid>|remove-ssid <ssid>|add-bssid <mac>|remove-bssid <mac>|check}"
        .to_string()
}

fn policy_config_path(app: &App) -> std::path::PathBuf {
    app.moddir.join(WIFI_POLICY_CONF)
}

fn ssid_list_path(app: &App) -> std::path::PathBuf {
    app.moddir.join(WIFI_SSID_LIST)
}

fn bssid_list_path(app: &App) -> std::path::PathBuf {
    app.moddir.join(WIFI_BSSID_LIST)
}

fn read_policy_config(app: &App) -> PolicyConfig {
    let values = read_kv(policy_config_path(app));
    let mode = values
        .get("MAGICNET_WIFI_POLICY_MODE")
        .and_then(|value| PolicyMode::parse(value).ok())
        .unwrap_or(PolicyMode::Blacklist);
    let interval_seconds = values
        .get("MAGICNET_WIFI_POLICY_INTERVAL")
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| (MIN_INTERVAL_SECONDS..=MAX_INTERVAL_SECONDS).contains(value))
        .unwrap_or(DEFAULT_INTERVAL_SECONDS);
    PolicyConfig {
        enabled: values
            .get("MAGICNET_WIFI_POLICY_ENABLED")
            .is_some_and(|value| value == "1"),
        mode,
        interval_seconds,
    }
}

fn write_policy_config(app: &App, config: &PolicyConfig) -> Result<(), String> {
    write_kv(
        app,
        Path::new(WIFI_POLICY_CONF),
        &[
            (
                "MAGICNET_WIFI_POLICY_ENABLED",
                if config.enabled { "1" } else { "0" }.to_string(),
            ),
            (
                "MAGICNET_WIFI_POLICY_MODE",
                config.mode.as_str().to_string(),
            ),
            (
                "MAGICNET_WIFI_POLICY_INTERVAL",
                config.interval_seconds.to_string(),
            ),
        ],
    )
}

fn set_enabled(app: &App, enabled: bool) -> Result<(), String> {
    let mut config = read_policy_config(app);
    config.enabled = enabled;
    write_policy_config(app, &config)?;
    if enabled {
        run_magicnet_function(app, "magicnet_wifi_policy_start")?;
        if let Err(err) = apply_once(app, false) {
            eprintln!("[warn] Wi-Fi policy enabled; initial check will retry: {err}");
        }
        println!("[info] Wi-Fi mode policy enabled");
    } else {
        run_magicnet_function(app, "magicnet_wifi_policy_stop")?;
        set_clash_mode(app, "rule")?;
        println!("[info] Wi-Fi mode policy disabled; mode restored to rule");
    }
    Ok(())
}

fn set_policy_mode(app: &App, mode: &str) -> Result<(), String> {
    let mut config = read_policy_config(app);
    config.mode = PolicyMode::parse(mode)?;
    write_policy_config(app, &config)?;
    apply_if_enabled(app, &config)?;
    println!("[info] Wi-Fi policy mode set to {}", config.mode.as_str());
    Ok(())
}

fn set_interval(app: &App, interval: &str) -> Result<(), String> {
    let value = interval
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|value| (MIN_INTERVAL_SECONDS..=MAX_INTERVAL_SECONDS).contains(value))
        .ok_or_else(|| "Wi-Fi policy interval must be between 3 and 300 seconds".to_string())?;
    let mut config = read_policy_config(app);
    config.interval_seconds = value;
    write_policy_config(app, &config)?;
    if config.enabled {
        run_magicnet_function(app, "magicnet_wifi_policy_stop; magicnet_wifi_policy_start")?;
    }
    println!("[info] Wi-Fi policy interval set to {value}s");
    Ok(())
}

#[derive(Clone, Copy)]
enum ListKind {
    Ssid,
    Bssid,
}

#[derive(Clone, Copy)]
enum ListAction {
    Add,
    Remove,
}

fn update_list(app: &App, kind: ListKind, value: &str, action: ListAction) -> Result<(), String> {
    let value = normalize_list_value(kind, value)?;
    let (path, relative) = match kind {
        ListKind::Ssid => (ssid_list_path(app), WIFI_SSID_LIST),
        ListKind::Bssid => (bssid_list_path(app), WIFI_BSSID_LIST),
    };
    let mut values = clean_lines(path)
        .into_iter()
        .map(|item| match kind {
            ListKind::Ssid => item,
            ListKind::Bssid => normalize_bssid(&item).unwrap_or(item),
        })
        .collect::<BTreeSet<_>>();
    match action {
        ListAction::Add => {
            values.insert(value.clone());
        }
        ListAction::Remove => {
            values.remove(&value);
        }
    }
    let text = if values.is_empty() {
        String::new()
    } else {
        format!("{}\n", values.into_iter().collect::<Vec<_>>().join("\n"))
    };
    write_text_file(app, Path::new(relative), &text)?;
    let config = read_policy_config(app);
    apply_if_enabled(app, &config)?;
    let noun = match kind {
        ListKind::Ssid => "SSID",
        ListKind::Bssid => "BSSID",
    };
    let verb = match action {
        ListAction::Add => "added",
        ListAction::Remove => "removed",
    };
    println!("[info] Wi-Fi {noun} {verb}: {value}");
    Ok(())
}

fn normalize_list_value(kind: ListKind, value: &str) -> Result<String, String> {
    let clean = value.trim();
    if clean.is_empty() || clean.contains('\n') || clean.contains('\r') {
        return Err(match kind {
            ListKind::Ssid => "SSID must not be empty".to_string(),
            ListKind::Bssid => "BSSID must be a MAC address".to_string(),
        });
    }
    match kind {
        ListKind::Ssid => Ok(clean.to_string()),
        ListKind::Bssid => normalize_bssid(clean)
            .ok_or_else(|| "BSSID must be a MAC address such as aa:bb:cc:dd:ee:ff".to_string()),
    }
}

fn apply_if_enabled(app: &App, config: &PolicyConfig) -> Result<(), String> {
    if config.enabled {
        if let Err(err) = apply_once(app, false) {
            eprintln!("[warn] Wi-Fi policy saved; live apply will retry: {err}");
        }
    }
    Ok(())
}

fn apply_once(app: &App, verbose: bool) -> Result<bool, String> {
    let config = read_policy_config(app);
    if !config.enabled {
        if verbose {
            println!("[info] Wi-Fi mode policy is disabled");
        }
        return Ok(false);
    }
    let network = detect_wifi();
    apply_network(app, &config, &network, verbose)
}

fn apply_network(
    app: &App,
    config: &PolicyConfig,
    network: &WifiNetwork,
    verbose: bool,
) -> Result<bool, String> {
    let ssids = clean_lines(ssid_list_path(app));
    let bssids = clean_lines(bssid_list_path(app))
        .into_iter()
        .filter_map(|value| normalize_bssid(&value))
        .collect::<Vec<_>>();
    let decision = decide(config, network, &ssids, &bssids);
    let current = current_clash_mode(app)?;
    let changed = current != decision.desired_mode;
    if changed {
        set_clash_mode(app, decision.desired_mode)?;
    }
    write_last_state(app, &network, &decision)?;
    if verbose || changed {
        println!(
            "[info] Wi-Fi policy: connected={} ssid={} bssid={} matched={} mode={}{}",
            network.connected as u8,
            network.ssid.as_deref().unwrap_or("-"),
            network.bssid.as_deref().unwrap_or("-"),
            decision.matched as u8,
            decision.desired_mode,
            if changed { " (applied)" } else { "" }
        );
    }
    Ok(changed)
}

fn watch(app: &App) -> Result<(), String> {
    let mut last_error = String::new();
    let mut applied_network: Option<WifiNetwork> = None;
    let mut pending_network: Option<WifiNetwork> = None;
    let mut pending_confirmations = 0_u8;
    let mut last_reconcile = Instant::now();
    loop {
        let config = read_policy_config(app);
        if !config.enabled
            || app.moddir.join("disable").exists()
            || app.moddir.join("remove").exists()
        {
            break;
        }
        let network = detect_wifi();
        let network_changed = applied_network.as_ref().is_some_and(|last| last != &network);
        let should_apply = if applied_network.is_none() {
            true
        } else if network_changed {
            if pending_network.as_ref() == Some(&network) {
                pending_confirmations = pending_confirmations.saturating_add(1);
            } else {
                pending_network = Some(network.clone());
                pending_confirmations = 1;
            }
            pending_confirmations >= NETWORK_CHANGE_CONFIRMATIONS
        } else {
            pending_network = None;
            pending_confirmations = 0;
            last_reconcile.elapsed() >= Duration::from_secs(STABLE_RECONCILE_SECONDS)
        };
        if should_apply {
            match apply_network(app, &config, &network, false) {
                Ok(_) => {
                    last_error.clear();
                    applied_network = Some(network);
                    pending_network = None;
                    pending_confirmations = 0;
                    last_reconcile = Instant::now();
                }
                Err(err) if err != last_error => {
                    eprintln!("[warn] Wi-Fi policy check failed: {err}");
                    last_error = err;
                }
                Err(_) => {}
            }
        }
        thread::sleep(Duration::from_secs(config.interval_seconds));
    }
    Ok(())
}

fn decide(
    config: &PolicyConfig,
    network: &WifiNetwork,
    ssids: &[String],
    bssids: &[String],
) -> PolicyDecision {
    let matched = network.connected
        && (network
            .ssid
            .as_ref()
            .is_some_and(|ssid| ssids.iter().any(|item| item == ssid))
            || network
                .bssid
                .as_ref()
                .is_some_and(|bssid| bssids.iter().any(|item| item == bssid)));
    let desired_mode = if !network.connected {
        "rule"
    } else {
        match config.mode {
            PolicyMode::Blacklist if matched => "direct",
            PolicyMode::Blacklist => "rule",
            PolicyMode::Whitelist if matched => "rule",
            PolicyMode::Whitelist => "direct",
        }
    };
    PolicyDecision {
        matched,
        desired_mode,
    }
}

fn detect_wifi() -> WifiNetwork {
    let output = command_text_full_timeout("cmd", &["wifi", "status"], Duration::from_secs(3));
    if command_output_available(&output, "cmd") {
        let network = parse_wifi_status(&output);
        if network.connected || explicitly_disconnected(&output) {
            return network;
        }
    }
    let output = command_text_full_timeout("dumpsys", &["wifi"], Duration::from_secs(3));
    if command_output_available(&output, "dumpsys") {
        let network = parse_wifi_status(&output);
        if network.connected || explicitly_disconnected(&output) {
            return network;
        }
    }
    let output = command_text_full_timeout("iw", &["dev", "wlan0", "link"], Duration::from_secs(3));
    if command_output_available(&output, "iw") {
        return parse_wifi_status(&output);
    }
    WifiNetwork::default()
}

fn explicitly_disconnected(output: &str) -> bool {
    let lower = output.to_ascii_lowercase();
    [
        "not connected",
        "disconnected",
        "wi-fi is disabled",
        "wifi is disabled",
        "state: disabled",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}

fn command_output_available(output: &str, program: &str) -> bool {
    let lower = output.to_ascii_lowercase();
    !lower.contains(&format!("{program} not available"))
        && !lower.contains("unknown command")
        && !lower.starts_with("timeout after")
        && !lower.starts_with("wait failed")
}

fn parse_wifi_status(text: &str) -> WifiNetwork {
    let ssid = extract_ssid(text);
    let bssid = extract_bssid(text);
    let connected = ssid.is_some() || bssid.is_some();
    WifiNetwork {
        connected,
        ssid,
        bssid,
    }
}

fn extract_ssid(text: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim();
        if !trimmed.contains("WifiInfo") && !trimmed.starts_with("SSID:") {
            continue;
        }
        for marker in ["SSID:", "SSID ="] {
            let Some(index) = trimmed.find(marker) else {
                continue;
            };
            if index > 0
                && trimmed
                    .as_bytes()
                    .get(index - 1)
                    .is_some_and(|value| value.is_ascii_alphanumeric())
            {
                continue;
            }
            let value = parse_field_value(&trimmed[index + marker.len()..]);
            if valid_ssid(&value) {
                return Some(value);
            }
        }
    }
    None
}

fn extract_bssid(text: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.contains("WifiInfo") {
            if let Some(index) = line.find("BSSID:") {
                let value = parse_field_value(&line[index + "BSSID:".len()..]);
                if let Some(value) = normalize_bssid(&value) {
                    if value != "02:00:00:00:00:00" && value != "00:00:00:00:00:00" {
                        return Some(value);
                    }
                }
            }
        }
        if let Some(value) = trimmed.strip_prefix("Connected to ") {
            if let Some(value) = normalize_bssid(value.split_whitespace().next().unwrap_or("")) {
                return Some(value);
            }
        }
    }
    None
}

fn parse_field_value(rest: &str) -> String {
    let clean = rest.trim_start();
    if let Some(quoted) = clean.strip_prefix('"') {
        return quoted
            .split_once('"')
            .map(|(value, _)| value)
            .unwrap_or(quoted)
            .trim()
            .to_string();
    }
    clean
        .split(',')
        .next()
        .unwrap_or(clean)
        .trim()
        .trim_matches('"')
        .to_string()
}

fn valid_ssid(value: &str) -> bool {
    let lower = value.trim().to_ascii_lowercase();
    !lower.is_empty()
        && !matches!(
            lower.as_str(),
            "<unknown ssid>" | "unknown ssid" | "null" | "<none>" | "none"
        )
}

fn normalize_bssid(value: &str) -> Option<String> {
    let clean = value
        .trim()
        .trim_matches(|ch: char| matches!(ch, '"' | ',' | '(' | ')'))
        .replace('-', ":")
        .to_ascii_lowercase();
    let parts = clean.split(':').collect::<Vec<_>>();
    if parts.len() == 6
        && parts
            .iter()
            .all(|part| part.len() == 2 && part.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        Some(clean)
    } else {
        None
    }
}

fn write_last_state(
    app: &App,
    network: &WifiNetwork,
    decision: &PolicyDecision,
) -> Result<(), String> {
    let values = [
            (
                "connected",
                if network.connected { "1" } else { "0" }.to_string(),
            ),
            ("ssid", network.ssid.clone().unwrap_or_default()),
            ("bssid", network.bssid.clone().unwrap_or_default()),
            (
                "matched",
                if decision.matched { "1" } else { "0" }.to_string(),
            ),
            ("desired_mode", decision.desired_mode.to_string()),
        ];
    let expected = values
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    if fs::read_to_string(app.moddir.join(WIFI_LAST_STATE)).as_deref() == Ok(expected.as_str()) {
        return Ok(());
    }
    write_kv(app, Path::new(WIFI_LAST_STATE), &values)
}

fn print_status(app: &App) {
    let config = read_policy_config(app);
    let network = detect_wifi();
    let ssids = clean_lines(ssid_list_path(app));
    let bssids = clean_lines(bssid_list_path(app))
        .into_iter()
        .filter_map(|value| normalize_bssid(&value))
        .collect::<Vec<_>>();
    let decision = decide(&config, &network, &ssids, &bssids);
    let current = current_clash_mode(app).unwrap_or_else(|_| "unavailable".to_string());
    let supervisor = supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy");
    println!("enabled={}", config.enabled as u8);
    println!("policy_mode={}", config.mode.as_str());
    println!("interval_seconds={}", config.interval_seconds);
    println!("supervisor={supervisor}");
    println!("connected={}", network.connected as u8);
    println!("ssid={}", network.ssid.as_deref().unwrap_or(""));
    println!("bssid={}", network.bssid.as_deref().unwrap_or(""));
    println!("matched={}", decision.matched as u8);
    println!("desired_mode={}", decision.desired_mode);
    println!("current_mode={current}");
    println!("ssid entries:");
    for value in ssids {
        println!("{value}");
    }
    println!("bssid entries:");
    for value in bssids {
        println!("{value}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(mode: PolicyMode) -> PolicyConfig {
        PolicyConfig {
            enabled: true,
            mode,
            interval_seconds: 5,
        }
    }

    #[test]
    fn parses_android_wifi_status_with_quoted_ssid() {
        let network = parse_wifi_status(
            "Wi-Fi is enabled\nWifiInfo: SSID: \"Home, 5G\", BSSID: AA:BB:CC:DD:EE:FF, MAC: 02:00:00:00:00:00",
        );
        assert_eq!(
            network,
            WifiNetwork {
                connected: true,
                ssid: Some("Home, 5G".to_string()),
                bssid: Some("aa:bb:cc:dd:ee:ff".to_string()),
            }
        );
    }

    #[test]
    fn parses_iw_link_output() {
        let network = parse_wifi_status(
            "Connected to 12:34:56:78:9A:BC (on wlan0)\n\tSSID: Office WiFi\n\tfreq: 5180",
        );
        assert_eq!(network.ssid.as_deref(), Some("Office WiFi"));
        assert_eq!(network.bssid.as_deref(), Some("12:34:56:78:9a:bc"));
        assert!(network.connected);
    }

    #[test]
    fn ignores_android_privacy_placeholders() {
        let network = parse_wifi_status(
            "WifiInfo: SSID: <unknown ssid>, BSSID: 02:00:00:00:00:00, MAC: 02:00:00:00:00:00",
        );
        assert_eq!(network, WifiNetwork::default());
    }

    #[test]
    fn partial_wifi_status_is_not_treated_as_an_explicit_disconnect() {
        assert!(!explicitly_disconnected("Wi-Fi is enabled\nscan state: idle"));
        assert!(explicitly_disconnected("Wi-Fi is enabled\nNetwork is not connected"));
        assert!(explicitly_disconnected("Wi-Fi is disabled"));
    }

    #[test]
    fn blacklist_directs_matches_and_rules_everything_else() {
        let network = WifiNetwork {
            connected: true,
            ssid: Some("Home".to_string()),
            bssid: Some("aa:bb:cc:dd:ee:ff".to_string()),
        };
        let matched = decide(
            &config(PolicyMode::Blacklist),
            &network,
            &["Home".to_string()],
            &[],
        );
        assert_eq!(matched.desired_mode, "direct");
        assert!(matched.matched);

        let unmatched = decide(
            &config(PolicyMode::Blacklist),
            &network,
            &["Office".to_string()],
            &[],
        );
        assert_eq!(unmatched.desired_mode, "rule");
        assert!(!unmatched.matched);
    }

    #[test]
    fn whitelist_only_rules_matching_wifi_and_mobile_restores_rule() {
        let network = WifiNetwork {
            connected: true,
            ssid: None,
            bssid: Some("aa:bb:cc:dd:ee:ff".to_string()),
        };
        assert_eq!(
            decide(
                &config(PolicyMode::Whitelist),
                &network,
                &[],
                &["aa:bb:cc:dd:ee:ff".to_string()],
            )
            .desired_mode,
            "rule"
        );
        assert_eq!(
            decide(
                &config(PolicyMode::Whitelist),
                &network,
                &[],
                &["11:22:33:44:55:66".to_string()],
            )
            .desired_mode,
            "direct"
        );
        assert_eq!(
            decide(
                &config(PolicyMode::Whitelist),
                &WifiNetwork::default(),
                &[],
                &[],
            )
            .desired_mode,
            "rule"
        );
    }
}
