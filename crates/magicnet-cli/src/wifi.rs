use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use crate::diagnostics::supervisor_pid;
use crate::utils::clean_module_lines;
use crate::webui_api::{current_clash_mode, set_clash_mode};
use crate::{read_kv, run_magicnet_function, write_kv, write_text_file, App};

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
        "status" | "list" => print_status(app),
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
    let relative = match kind {
        ListKind::Ssid => WIFI_SSID_LIST,
        ListKind::Bssid => WIFI_BSSID_LIST,
    };
    let mut values = clean_module_lines(app, Path::new(relative))
        .unwrap_or_default()
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
    let network = detect_wifi()?;
    apply_network(app, &config, &network, verbose)
}

fn apply_network(
    app: &App,
    config: &PolicyConfig,
    network: &WifiNetwork,
    verbose: bool,
) -> Result<bool, String> {
    let ssids = clean_module_lines(app, Path::new(WIFI_SSID_LIST)).unwrap_or_default();
    let bssids = clean_module_lines(app, Path::new(WIFI_BSSID_LIST))
        .unwrap_or_default()
        .into_iter()
        .filter_map(|value| normalize_bssid(&value))
        .collect::<Vec<_>>();
    let decision = decide(config, network, &ssids, &bssids);
    let current = current_clash_mode(app)?;
    let changed = current != decision.desired_mode;
    if changed {
        set_clash_mode(app, decision.desired_mode)?;
    }
    let current_mode = if changed {
        decision.desired_mode
    } else {
        current.as_str()
    };
    write_last_state(app, network, &decision, current_mode)?;
    crate::state::reconcile_wifi(app)
        .map_err(|err| format!("publish Wi-Fi canonical state: {err}"))?;
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
    let mut detector = WifiDetector::default();
    loop {
        let config = read_policy_config(app);
        if !config.enabled
            || app.moddir.join("disable").exists()
            || app.moddir.join("remove").exists()
        {
            break;
        }
        let network = match detector.detect() {
            Ok(network) => network,
            Err(error) => {
                // Unknown is not a disconnect and breaks consecutive-change
                // confirmation. Keep the last applied mode until a real sample.
                pending_network = None;
                pending_confirmations = 0;
                if last_error != error {
                    eprintln!("[warn] Wi-Fi policy check failed: {error}");
                    last_error = error;
                }
                thread::sleep(Duration::from_secs(config.interval_seconds));
                continue;
            }
        };
        let network_changed = applied_network
            .as_ref()
            .is_some_and(|last| last != &network);
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

const WIFI_PROBES: [(&str, &[&str]); 3] = [
    ("cmd", &["wifi", "status"]),
    ("dumpsys", &["wifi"]),
    ("iw", &["dev", "wlan0", "link"]),
];

#[derive(Default)]
struct WifiDetector {
    preferred: Option<usize>,
}

impl WifiDetector {
    fn detect(&mut self) -> Result<WifiNetwork, String> {
        self.detect_with(|index| {
            let (program, args) = WIFI_PROBES[index];
            let mut command = Command::new(program);
            command.args(args);
            let output =
                crate::run_bounded_command(command, Duration::from_secs(3), 1024 * 1024).ok()?;
            if output.timed_out
                || output.truncated
                || !output.status.is_some_and(|status| status.success())
            {
                return None;
            }
            let text = String::from_utf8(output.stdout).ok()?;
            if !command_output_available(&text, program) {
                return None;
            }
            let network = parse_wifi_status(&text);
            (network.connected || explicitly_disconnected(&text)).then_some(network)
        })
    }

    fn detect_with(
        &mut self,
        mut probe: impl FnMut(usize) -> Option<WifiNetwork>,
    ) -> Result<WifiNetwork, String> {
        let preferred = self.preferred;
        let order = preferred
            .into_iter()
            .chain((0..WIFI_PROBES.len()).filter(|index| Some(*index) != preferred));
        for index in order {
            if let Some(network) = probe(index) {
                self.preferred = Some(index);
                return Ok(network);
            }
        }
        // Drop a failed preference so a recovered primary backend gets a turn.
        self.preferred = None;
        Err("Wi-Fi state is unknown; preserving the current policy".to_string())
    }
}

fn detect_wifi() -> Result<WifiNetwork, String> {
    WifiDetector::default().detect()
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
    current_mode: &str,
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
        ("current_mode", current_mode.to_string()),
    ];
    let expected = values
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    if fs::read_to_string(app.moddir.join(WIFI_LAST_STATE))
        .ok()
        .as_deref()
        == Some(expected.as_str())
    {
        return Ok(());
    }
    write_kv(app, Path::new(WIFI_LAST_STATE), &values)
}

/// Private, explicit editor view. Generic wifi.status remains redacted.
/// Reuses the same detection/decision primitives as the resident policy loop.
pub(crate) fn inspect_machine(app: &App) -> Result<serde_json::Value, String> {
    let config = read_policy_config(app);
    let read_list =
        |path| crate::utils::clean_module_lines_bounded(app, Path::new(path), 64 * 1024);
    let ssids = read_list(WIFI_SSID_LIST)?;
    let bssids = read_list(WIFI_BSSID_LIST)?
        .into_iter()
        .map(|value| normalize_bssid(&value).ok_or_else(|| "invalid configured BSSID".to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let network = detect_wifi()?;
    let current = current_clash_mode(app).unwrap_or_else(|_| "unavailable".to_string());
    // A policy edit during the bounded device probe must not be combined with
    // an old decision. No state is persisted by this inspection.
    if config != read_policy_config(app)
        || ssids != read_list(WIFI_SSID_LIST)?
        || bssids
            != read_list(WIFI_BSSID_LIST)?
                .into_iter()
                .filter_map(|value| normalize_bssid(&value))
                .collect::<Vec<_>>()
    {
        return Err("Wi-Fi configuration changed during observation".to_string());
    }
    Ok(inspect_value(
        &config,
        &network,
        &ssids,
        &bssids,
        &current,
        &supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy"),
    ))
}

fn inspect_value(
    config: &PolicyConfig,
    network: &WifiNetwork,
    ssids: &[String],
    bssids: &[String],
    current: &str,
    supervisor: &str,
) -> serde_json::Value {
    let decision = decide(config, network, ssids, bssids);
    serde_json::json!({
        "policy": {"enabled": config.enabled, "mode": config.mode.as_str(),
                   "interval_seconds": config.interval_seconds, "supervisor": supervisor},
        "network": {"connected": network.connected, "matched": decision.matched,
                    "desired_mode": decision.desired_mode,
                    "ssid": network.ssid.as_deref().unwrap_or(""),
                    "bssid": network.bssid.as_deref().unwrap_or("")},
        "current_mode": current,
        "configuration": {"ssids": ssids, "bssids": bssids},
    })
}

fn print_status(app: &App) -> Result<(), String> {
    let config = read_policy_config(app);
    let network = detect_wifi()?;
    let ssids = clean_module_lines(app, Path::new(WIFI_SSID_LIST)).unwrap_or_default();
    let bssids = clean_module_lines(app, Path::new(WIFI_BSSID_LIST))
        .unwrap_or_default()
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
    Ok(())
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
    fn machine_inspector_preserves_editor_lists_and_real_policy_decision() {
        let config = config(PolicyMode::Blacklist);
        let network = WifiNetwork {
            connected: true,
            ssid: Some("Guest=WiFi".into()),
            bssid: None,
        };
        let ssids = vec!["Guest=WiFi".into(), "Office".into()];
        let value = inspect_value(&config, &network, &ssids, &[], "rule", "stopped");
        assert_eq!(value["network"]["ssid"], "Guest=WiFi");
        assert_eq!(value["network"]["matched"], true);
        assert_eq!(value["network"]["desired_mode"], "direct");
        assert_eq!(value["current_mode"], "rule");
        assert_eq!(value["configuration"]["ssids"], serde_json::json!(ssids));
        let disconnected = inspect_value(
            &config,
            &WifiNetwork::default(),
            &ssids,
            &[],
            "unavailable",
            "stopped",
        );
        assert_eq!(disconnected["network"]["connected"], false);
        assert_eq!(disconnected["network"]["ssid"], "");
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
        assert!(!explicitly_disconnected(
            "Wi-Fi is enabled\nscan state: idle"
        ));
        assert!(explicitly_disconnected(
            "Wi-Fi is enabled\nNetwork is not connected"
        ));
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

#[cfg(test)]
mod detector_tests {
    use super::{WifiDetector, WifiNetwork};

    fn connected() -> WifiNetwork {
        WifiNetwork {
            connected: true,
            ssid: Some("fixture".to_string()),
            bssid: None,
        }
    }

    #[test]
    fn failed_detection_is_not_a_disconnect() {
        let mut detector = WifiDetector::default();
        assert!(detector.detect_with(|_| None).is_err());
        assert_eq!(detector.preferred, None);
    }

    #[test]
    fn successful_backend_is_reused_without_repeating_failed_probes() {
        let mut detector = WifiDetector::default();
        let mut calls = Vec::new();
        assert!(detector
            .detect_with(|index| {
                calls.push(index);
                (index == 1).then(connected)
            })
            .is_ok());
        assert_eq!(calls, [0, 1]);
        calls.clear();
        assert!(detector
            .detect_with(|index| {
                calls.push(index);
                (index == 1).then(connected)
            })
            .is_ok());
        assert_eq!(calls, [1]);
    }

    #[test]
    fn failed_preferred_backend_falls_back_once_per_candidate() {
        let mut detector = WifiDetector { preferred: Some(1) };
        let mut calls = Vec::new();
        assert!(detector
            .detect_with(|index| {
                calls.push(index);
                (index == 2).then(connected)
            })
            .is_ok());
        assert_eq!(calls, [1, 0, 2]);
        assert_eq!(detector.preferred, Some(2));
    }

    #[test]
    fn explicit_disconnect_is_authoritative_without_expensive_fallback() {
        let mut detector = WifiDetector::default();
        let mut calls = Vec::new();
        let network = detector
            .detect_with(|index| {
                calls.push(index);
                Some(WifiNetwork::default())
            })
            .unwrap();
        assert!(!network.connected);
        assert_eq!(calls, [0]);
    }
}
