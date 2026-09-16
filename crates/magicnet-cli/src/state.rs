use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::diagnostics::supervisor_pid;
use crate::utils::read_json_file_bounded as read_json;
use crate::{
    clean_module_lines, cmdline_has_script, proc_start_time, read_kv, read_proc_argv,
    read_proc_text_bounded, replace_module_text_files_transactionally, singbox_pid_summary, App,
    MAX_PROC_STAT_BYTES,
};

const STATE_ROOT: &str = ".state/machines";
const STARTUP_ERROR: &str = ".state/startup-error";
const TRANSPARENT_TRANSACTION: &str = ".state/transparent-transaction";
const TRANSPARENT_RECENT_ERROR: &str = ".state/transparent-recent-error";
const TRANSPARENT_CAPABILITY: &str = ".state/transparent-ebpf/capability";
const TRANSPARENT_SHARED_PENDING: &str = ".state/transparent-ebpf/shared.pending";
const SUBSCRIPTION_STATUS: &str = ".state/sing-box/subscription-status";
const SUBSCRIPTION_TRANSACTION: &str = ".state/sing-box/subscription-transaction";
const SUBSCRIPTION_UPDATE_LOCK: &str = ".state/sing-box/subscription-update.lock";
const SUBSCRIPTION_REFRESH_OWNER: &str = ".state/watchdog/magicnet-subscription-refresh.owner";
const SUBSCRIPTION_REFRESH_LOOP: &str = ".state/watchdog/magicnet-subscription-refresh.loop.sh";
const SELECTOR_SELECTIONS: &str = ".config/magicnet/selector-selections.json";
const LEGACY_SELECTOR_SELECTIONS: &str = ".state/sing-box/selector-selections.json";
const APP_MODE_CONF: &str = ".config/magicnet/app-mode.conf";
const APP_INCLUDE_UIDS: &str = ".state/app-policy/include-uids.list";
const APP_EXCLUDE_UIDS: &str = ".state/app-policy/exclude-uids.list";
const WIFI_POLICY_CONF: &str = ".config/magicnet/wifi-policy.conf";
const WIFI_LAST_STATE: &str = ".state/wifi-policy/last-state.conf";
const HOTSPOT_OFFLOAD_OWNER: &str = ".state/hotspot/tether-offload.previous";
const HOTSPOT_TUN_RULES: &str = ".state/hotspot/tun-rules.list";
const DNS_GUARD_INTERFACES: &str = ".state/dns-leak-guard.ifaces";
const MCP_CONF: &str = ".config/magicnet/mcp.conf";
const MCP_PID: &str = ".state/magicnet-mcp.pid";
const TAILSCALE_AUTH: &str = ".config/sing-box/tailscale-auth.json";
const SINGBOX_CONFIG: &str = ".config/sing-box/config.json";
const TRANSPARENT_MODE_CONF: &str = ".config/magicnet/transparent-mode.conf";
const SELECTED_CORE_CONF: &str = ".config/magicnet/current-core.conf";
const SUBSCRIPTION_URL: &str = ".config/sing-box/subscription.url";
const SUBSCRIPTION_LOCAL: &str = ".config/sing-box/subscription.local";
const SUBSCRIPTION_REFRESH_HOURS: &str = ".config/magicnet/subscription-refresh-hours";
const MODULE_TRANSACTION_STAGE: &str = ".tmp/magicnet-app-transaction";

#[derive(Clone, Copy)]
enum Domain {
    Service,
    Transparent,
    Subscription,
    SubscriptionRefresh,
    Selectors,
    AppPolicy,
    Supervisors,
    Wifi,
    Hotspot,
    Dns,
    Mcp,
    Tailscale,
    Transactions,
}

impl Domain {
    fn name(self) -> &'static str {
        match self {
            Self::Service => "service",
            Self::Transparent => "transparent",
            Self::Subscription => "subscription",
            Self::SubscriptionRefresh => "subscription-refresh",
            Self::Selectors => "selectors",
            Self::AppPolicy => "app-policy",
            Self::Supervisors => "supervisors",
            Self::Wifi => "wifi",
            Self::Hotspot => "hotspot",
            Self::Dns => "dns",
            Self::Mcp => "mcp",
            Self::Tailscale => "tailscale",
            Self::Transactions => "transactions",
        }
    }

    fn path(self) -> PathBuf {
        Path::new(STATE_ROOT).join(format!("{}.state", self.name()))
    }
}

struct StateRecord {
    domain: &'static str,
    fields: BTreeMap<&'static str, String>,
}

impl StateRecord {
    fn new(domain: Domain) -> Self {
        Self {
            domain: domain.name(),
            fields: BTreeMap::new(),
        }
    }

    fn field(mut self, key: &'static str, value: impl Into<String>) -> Self {
        self.fields.insert(key, sanitize_token(value.into()));
        self
    }

    fn bool(self, key: &'static str, value: bool) -> Self {
        self.field(key, if value { "1" } else { "0" })
    }

    fn encode(&self) -> String {
        let mut output = format!("schema=1\ndomain={}\n", self.domain);
        for (key, value) in &self.fields {
            output.push_str(key);
            output.push('=');
            output.push_str(value);
            output.push('\n');
        }
        output
    }
}

fn sanitize_token(value: String) -> String {
    let value = value.trim();
    if !value.is_empty()
        && value.len() <= 128
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':' | b',')
        })
    {
        value.to_string()
    } else {
        "unknown".to_string()
    }
}

pub(crate) fn reconcile(app: &App) -> Result<(), String> {
    let config = read_json(&app.moddir.join(SINGBOX_CONFIG), 4 * 1024 * 1024);
    let wifi_supervisor = supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy");
    let records = [
        (Domain::Service, service_record(app)),
        (
            Domain::Transparent,
            transparent_record(app, config.as_ref()),
        ),
        (Domain::Subscription, subscription_record(app)),
        (
            Domain::SubscriptionRefresh,
            subscription_refresh_record(app),
        ),
        (Domain::Selectors, selectors_record(app)),
        (Domain::AppPolicy, app_policy_record(app)),
        (
            Domain::Supervisors,
            supervisors_record(app, &wifi_supervisor),
        ),
        (
            Domain::Wifi,
            wifi_record_with_supervisor(app, &wifi_supervisor),
        ),
        (Domain::Hotspot, hotspot_record(app)),
        (Domain::Dns, dns_record(app)),
        (Domain::Mcp, mcp_record(app)),
        (Domain::Tailscale, tailscale_record(app, config.as_ref())),
        (Domain::Transactions, transactions_record(app)),
    ];

    publish_records(app, &records)
}

pub(crate) fn reconcile_wifi(app: &App) -> Result<(), String> {
    let supervisor = supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy");
    publish_records(
        app,
        &[
            (Domain::Wifi, wifi_record_with_supervisor(app, &supervisor)),
            (Domain::Supervisors, supervisors_record(app, &supervisor)),
        ],
    )
}

fn publish_records(app: &App, records: &[(Domain, StateRecord)]) -> Result<(), String> {
    let mut changed = Vec::new();
    for (domain, record) in records {
        let relative = domain.path();
        let encoded = record.encode();
        let current = fs::read_to_string(app.moddir.join(&relative)).ok();
        if current.as_deref() != Some(encoded.as_str()) {
            changed.push((relative, encoded));
        }
    }
    if changed.is_empty() {
        return Ok(());
    }
    let replacements = changed
        .iter()
        .map(|(path, text)| (path.as_path(), text.as_str()))
        .collect::<Vec<_>>();
    replace_module_text_files_transactionally(app, &replacements)
        .map_err(|error| format!("reconcile canonical state plane: {error}"))
}

fn service_record(app: &App) -> StateRecord {
    let summary = singbox_pid_summary(app);
    let process_state = process_state(&summary);
    let transparent_phase = transparent_phase(app);
    let lifecycle = match process_state {
        "stopped" => "stopped",
        "unknown" => "unknown",
        "running" if transparent_phase != "idle" => "reconfiguring",
        "running" => "running",
        _ => "unknown",
    };
    let selected = read_kv(app.moddir.join(SELECTED_CORE_CONF))
        .remove("MAGICNET_DEFAULT_CORE")
        .map(|value| match value.as_str() {
            "sing-box" | "singbox" => "sing-box".to_string(),
            _ => "invalid".to_string(),
        })
        .unwrap_or_else(|| "sing-box".to_string());
    let pid_count = if process_state == "running" {
        summary.split(',').count()
    } else {
        0
    };
    StateRecord::new(Domain::Service)
        .field("state", process_state)
        .field("lifecycle", lifecycle)
        .field("selected_core", selected)
        .field("process_count", pid_count.to_string())
        .field("transparent_phase", transparent_phase)
        .bool(
            "startup_error",
            regular_nonempty(&app.moddir.join(STARTUP_ERROR)),
        )
}

fn process_state(summary: &str) -> &'static str {
    if summary == "stopped" {
        "stopped"
    } else if summary == "unknown" {
        "unknown"
    } else if summary
        .split(',')
        .all(|pid| !pid.is_empty() && pid.bytes().all(|byte| byte.is_ascii_digit()))
    {
        "running"
    } else {
        "unknown"
    }
}

fn transparent_record(app: &App, config: Option<&Value>) -> StateRecord {
    let configured = read_kv(app.moddir.join(TRANSPARENT_MODE_CONF))
        .remove("MAGICNET_TRANSPARENT_MODE")
        .map(|mode| match mode.as_str() {
            "tun" | "ebpf" => mode,
            _ => "invalid".to_string(),
        })
        .unwrap_or_else(|| "tun".to_string());
    let (effective_type, effective_mode, shared_interfaces) =
        effective_transparent(config, &configured);
    let phase = transparent_phase(app);
    let transaction = app.moddir.join(TRANSPARENT_TRANSACTION).is_dir();
    let capability = if effective_type == "ebpf" {
        read_token(app.moddir.join(TRANSPARENT_CAPABILITY), "unknown")
    } else {
        "not_required".to_string()
    };
    StateRecord::new(Domain::Transparent)
        .field(
            "state",
            if transaction {
                "transitioning"
            } else {
                "stable"
            },
        )
        .field("configured", configured)
        .field("effective_type", effective_type)
        .field("effective_mode", effective_mode)
        .field("phase", phase)
        .field("capability", capability)
        .bool("transaction_active", transaction)
        .bool(
            "shared_pending",
            regular_nonempty(&app.moddir.join(TRANSPARENT_SHARED_PENDING)),
        )
        .field("shared_interface_count", shared_interfaces.to_string())
        .bool(
            "recent_error",
            regular_nonempty(&app.moddir.join(TRANSPARENT_RECENT_ERROR)),
        )
}

fn effective_transparent(config: Option<&Value>, configured: &str) -> (String, String, usize) {
    let Some(config) = config else {
        return (configured.to_string(), configured.to_string(), 0);
    };
    let inbound = config
        .get("inbounds")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("tag").and_then(Value::as_str) == Some("tun-in"))
        });
    let effective_type = inbound
        .and_then(|item| item.get("type"))
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "tun" | "ebpf"))
        .unwrap_or(configured)
        .to_string();
    let effective_mode = if effective_type == "ebpf" {
        inbound
            .and_then(|item| item.get("mode"))
            .and_then(Value::as_str)
            .filter(|value| matches!(*value, "local" | "shared" | "hybrid"))
            .unwrap_or("local")
            .to_string()
    } else {
        "tun".to_string()
    };
    let shared_interfaces = inbound
        .and_then(|item| item.get("shared"))
        .and_then(|value| value.get("interface"))
        .and_then(Value::as_array)
        .map(|values| values.iter().filter_map(Value::as_str).count())
        .unwrap_or(0);
    (effective_type, effective_mode, shared_interfaces)
}

fn transparent_phase(app: &App) -> String {
    let journal = app.moddir.join(TRANSPARENT_TRANSACTION);
    if !journal.is_dir() {
        return "idle".to_string();
    }
    read_token(journal.join("phase"), "unknown")
}

fn subscription_record(app: &App) -> StateRecord {
    let values = read_kv(app.moddir.join(SUBSCRIPTION_STATUS));
    let stored_result = map_value(&values, "result", "never");
    let owner = subscription_update_owner_state(app);
    let result = effective_subscription_result(&stored_result, owner);
    let phase = map_value(&values, "phase", "never");
    let lock_present = app.moddir.join(SUBSCRIPTION_UPDATE_LOCK).is_dir();
    let transaction_pending = app.moddir.join(SUBSCRIPTION_TRANSACTION).is_dir();
    let state = if owner == "active" {
        "running"
    } else if owner == "pending" {
        "pending"
    } else if owner == "unknown" {
        "unknown"
    } else if transaction_pending {
        "recovery_pending"
    } else {
        match result {
            "success" => "success",
            "failed" => "failed",
            "interrupted" => "interrupted",
            "never" => "idle",
            _ => "unknown",
        }
    };
    let local = regular_nonempty(&app.moddir.join(SUBSCRIPTION_LOCAL));
    let configured_count = if local {
        1
    } else {
        clean_module_lines(app, Path::new(SUBSCRIPTION_URL))
            .map(|items| items.len())
            .unwrap_or(0)
    };
    StateRecord::new(Domain::Subscription)
        .field("state", state)
        .field("phase", phase)
        .field("result", result)
        .field("owner", owner)
        .field("source", if local { "local" } else { "url" })
        .field("configured_count", configured_count.to_string())
        .field("generation", map_value(&values, "generation_id", "none"))
        .bool("update_lock", lock_present)
        .bool("transaction_pending", transaction_pending)
}

fn subscription_refresh_record(app: &App) -> StateRecord {
    let schedule = read_token(app.moddir.join(SUBSCRIPTION_REFRESH_HOURS), "off");
    let schedule = if matches!(schedule.as_str(), "12" | "24" | "48" | "72") {
        schedule
    } else {
        "off".to_string()
    };
    let owner = refresh_owner_state(app);
    StateRecord::new(Domain::SubscriptionRefresh)
        .field("state", owner)
        .field("schedule_hours", schedule.clone())
        .bool("enabled", schedule != "off")
}

/// Stored `running` is not evidence of a live update after a crash.
pub(crate) fn effective_subscription_result<'a>(stored: &'a str, owner: &str) -> &'a str {
    if stored == "running" && matches!(owner, "none" | "stale") {
        "interrupted"
    } else {
        stored
    }
}

/// Observe the existing lock; never remove it or interfere with the flock holder.
pub(crate) fn subscription_update_owner_state(app: &App) -> &'static str {
    let lock = app.moddir.join(SUBSCRIPTION_UPDATE_LOCK);
    let metadata = match fs::symlink_metadata(&lock) {
        Ok(value) if value.is_dir() => value,
        Ok(_) => return "stale",
        Err(error) if error.kind() == io::ErrorKind::NotFound => return "none",
        Err(_) => return "unknown",
    };
    let owner = inspect_process_owner(&lock.join("owner"), None, None, Path::new("/proc"));
    if owner != "none" {
        return owner;
    }
    // The shell publishes its owner just after mkdir. An in-flight acquisition
    // is pending, not proven running; after the existing five-second grace the
    // empty directory is stale. Clock/metadata uncertainty stays unknown.
    match metadata
        .modified()
        .ok()
        .and_then(|time| SystemTime::now().duration_since(time).ok())
    {
        Some(age) if age < Duration::from_secs(5) => "pending",
        Some(_) => "stale",
        None => "unknown",
    }
}

pub(crate) fn refresh_owner_state(app: &App) -> &'static str {
    inspect_process_owner(
        &app.moddir.join(SUBSCRIPTION_REFRESH_OWNER),
        Some("subscription-refresh-v1"),
        Some(&app.moddir.join(SUBSCRIPTION_REFRESH_LOOP)),
        Path::new("/proc"),
    )
}

fn read_owner_record(path: &Path) -> io::Result<String> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > 256 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid owner record",
        ));
    }
    let mut text = String::new();
    file.take(257).read_to_string(&mut text)?;
    if text.len() > 256 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "oversized owner record",
        ));
    }
    Ok(text)
}

fn inspect_process_owner(
    owner_path: &Path,
    marker: Option<&str>,
    script: Option<&Path>,
    proc_root: &Path,
) -> &'static str {
    let owner = match read_owner_record(owner_path) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return "none",
        Err(error) if error.kind() == io::ErrorKind::InvalidData => return "stale",
        Err(_) => return "unknown",
    };
    if owner.trim().is_empty() {
        return "none";
    }
    let mut fields = owner.trim().split(':');
    let Some(pid) = fields
        .next()
        .filter(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|pid| *pid > 0)
    else {
        return "unknown";
    };
    let Some(start) = fields
        .next()
        .filter(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
    else {
        return "unknown";
    };
    let Some(token) = fields.next().filter(|value| {
        !value.is_empty()
            && value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    }) else {
        return "unknown";
    };
    if fields.next().is_some() {
        return "unknown";
    }
    if marker.is_some_and(|expected| token != expected) {
        return "stale";
    }
    let proc_dir = proc_root.join(pid.to_string());
    match proc_dir.try_exists() {
        Ok(false) => return "stale",
        Err(_) => return "unknown",
        Ok(true) => {}
    }
    let stat = match read_proc_text_bounded(&proc_dir.join("stat"), MAX_PROC_STAT_BYTES) {
        Ok(value) => value,
        Err(_) if matches!(proc_dir.try_exists(), Ok(false)) => return "stale",
        Err(_) => return "unknown",
    };
    let Some(live_start) = proc_start_time(&stat) else {
        return "unknown";
    };
    if live_start != start {
        return "stale";
    }
    let state = stat
        .rsplit_once(')')
        .and_then(|(_, tail)| tail.split_whitespace().next());
    if matches!(state, Some("Z" | "X")) {
        return "stale";
    }
    if let Some(script) = script {
        let argv = match read_proc_argv(&proc_dir.join("cmdline")) {
            Ok(value) => value,
            Err(_) if matches!(proc_dir.try_exists(), Ok(false)) => return "stale",
            Err(_) => return "unknown",
        };
        if !cmdline_has_script(&argv, &script.to_string_lossy()) {
            return "stale";
        }
    }
    "active"
}

fn selectors_record(app: &App) -> StateRecord {
    let primary = app.moddir.join(SELECTOR_SELECTIONS);
    let legacy = app.moddir.join(LEGACY_SELECTOR_SELECTIONS);
    let path = if primary.is_file() { &primary } else { &legacy };
    let (state, count) = match read_json(path, 256 * 1024) {
        Some(Value::Object(values)) if values.is_empty() => ("empty", 0),
        Some(Value::Object(values)) => ("ready", values.len()),
        Some(_) => ("invalid", 0),
        None if path.is_file() => ("invalid", 0),
        None => ("empty", 0),
    };
    StateRecord::new(Domain::Selectors)
        .field("state", state)
        .field("selection_count", count.to_string())
}

fn app_policy_record(app: &App) -> StateRecord {
    let mode = read_kv(app.moddir.join(APP_MODE_CONF))
        .remove("MAGICNET_APP_MODE")
        .map(|value| match value.as_str() {
            "whitelist" => "whitelist".to_string(),
            _ => "blacklist".to_string(),
        })
        .unwrap_or_else(|| "blacklist".to_string());
    let include_count = clean_line_count(&app.moddir.join(APP_INCLUDE_UIDS));
    let exclude_count = clean_line_count(&app.moddir.join(APP_EXCLUDE_UIDS));
    let resolved =
        app.moddir.join(APP_INCLUDE_UIDS).is_file() || app.moddir.join(APP_EXCLUDE_UIDS).is_file();
    StateRecord::new(Domain::AppPolicy)
        .field("state", if resolved { "resolved" } else { "unresolved" })
        .field("mode", mode)
        .field("include_uid_count", include_count.to_string())
        .field("exclude_uid_count", exclude_count.to_string())
}

fn supervisors_record(app: &App, wifi_supervisor: &str) -> StateRecord {
    StateRecord::new(Domain::Supervisors)
        .field(
            "fswatch",
            normalize_supervisor_state(&supervisor_pid(app, "fswatch", "magicnet-config")),
        )
        .field("wifi_policy", normalize_supervisor_state(wifi_supervisor))
        .field(
            "kernel_watchdog",
            pidfile_state(&app.moddir.join(".state/watchdog/magicnet-kernel.pid")),
        )
        .field(
            "hotspot_watchdog",
            pidfile_state(
                &app.moddir
                    .join(".state/watchdog/magicnet-hotspot-route.pid"),
            ),
        )
}

fn normalize_supervisor_state(value: &str) -> &'static str {
    if value.bytes().all(|byte| byte.is_ascii_digit()) && !value.is_empty() {
        "running"
    } else if value.starts_with("orphan:") {
        "orphan"
    } else if value.eq_ignore_ascii_case("stopped") {
        "stopped"
    } else {
        "unknown"
    }
}

fn pidfile_state(path: &Path) -> &'static str {
    let Ok(value) = fs::read_to_string(path) else {
        return "stopped";
    };
    let Some(pid) = value.trim().parse::<u32>().ok().filter(|pid| *pid > 0) else {
        return "unknown";
    };
    if Path::new(&format!("/proc/{pid}")).is_dir() {
        "running"
    } else {
        "stale"
    }
}

fn wifi_record_with_supervisor(app: &App, wifi_supervisor: &str) -> StateRecord {
    let config = read_kv(app.moddir.join(WIFI_POLICY_CONF));
    let last = read_kv(app.moddir.join(WIFI_LAST_STATE));
    let enabled = config
        .get("MAGICNET_WIFI_POLICY_ENABLED")
        .is_some_and(|value| value == "1");
    let supervisor = normalize_supervisor_state(wifi_supervisor);
    let state = if !enabled {
        "disabled"
    } else if supervisor == "running" {
        "active"
    } else {
        "waiting"
    };
    StateRecord::new(Domain::Wifi)
        .field("state", state)
        .bool("enabled", enabled)
        .field(
            "policy",
            match config.get("MAGICNET_WIFI_POLICY_MODE").map(String::as_str) {
                Some("whitelist") => "whitelist",
                _ => "blacklist",
            },
        )
        .field("supervisor", supervisor)
        .field("connected", map_value(&last, "connected", "0"))
        .field("matched", map_value(&last, "matched", "0"))
        .field("desired_mode", map_value(&last, "desired_mode", "rule"))
        .field("current_mode", map_value(&last, "current_mode", "unknown"))
        .bool(
            "has_ssid",
            last.get("ssid")
                .is_some_and(|value| !value.is_empty() && value != "-"),
        )
        .bool(
            "has_bssid",
            last.get("bssid")
                .is_some_and(|value| !value.is_empty() && value != "-"),
        )
}

fn hotspot_record(app: &App) -> StateRecord {
    let owned = app.moddir.join(HOTSPOT_OFFLOAD_OWNER).is_file();
    let rule_count = clean_line_count(&app.moddir.join(HOTSPOT_TUN_RULES));
    let configured_mode = read_kv(app.moddir.join(TRANSPARENT_MODE_CONF))
        .remove("MAGICNET_TRANSPARENT_MODE")
        .unwrap_or_else(|| "tun".to_string());
    let state = if !owned {
        "disabled"
    } else if configured_mode == "ebpf" {
        "shared"
    } else if rule_count > 0 {
        "active"
    } else {
        "waiting"
    };
    StateRecord::new(Domain::Hotspot)
        .field("state", state)
        .bool("offload_owned", owned)
        .field("tun_rule_count", rule_count.to_string())
}

fn dns_record(app: &App) -> StateRecord {
    let interface_count = clean_line_count(&app.moddir.join(DNS_GUARD_INTERFACES));
    StateRecord::new(Domain::Dns)
        .field("state", if interface_count > 0 { "owned" } else { "idle" })
        .field("guard_interface_count", interface_count.to_string())
}

fn mcp_record(app: &App) -> StateRecord {
    let config = read_kv(app.moddir.join(MCP_CONF));
    let enabled = config
        .get("MAGICNET_MCP_ENABLED")
        .is_some_and(|value| value == "1");
    let process = pidfile_state(&app.moddir.join(MCP_PID));
    let state = if !enabled {
        "disabled"
    } else if process == "running" {
        "running"
    } else {
        "stopped"
    };
    StateRecord::new(Domain::Mcp)
        .field("state", state)
        .bool("enabled", enabled)
        .field("process", process)
        .bool(
            "secret_set",
            config
                .get("MAGICNET_MCP_SECRET")
                .is_some_and(|value| !value.is_empty()),
        )
}

fn tailscale_record(app: &App, config: Option<&Value>) -> StateRecord {
    let count = config
        .and_then(|config| config.get("endpoints").and_then(Value::as_array))
        .map(|endpoints| {
            endpoints
                .iter()
                .filter(|endpoint| {
                    endpoint.get("type").and_then(Value::as_str) == Some("tailscale")
                })
                .count()
        })
        .unwrap_or(0);
    let state = match count {
        0 => "absent",
        1 => "configured",
        _ => "multiple",
    };
    StateRecord::new(Domain::Tailscale)
        .field("state", state)
        .field("endpoint_count", count.to_string())
        .bool(
            "auth_material",
            regular_nonempty(&app.moddir.join(TAILSCALE_AUTH)),
        )
}

fn transactions_record(app: &App) -> StateRecord {
    let transparent = app.moddir.join(TRANSPARENT_TRANSACTION).is_dir();
    let subscription = app.moddir.join(SUBSCRIPTION_TRANSACTION).is_dir();
    let module = directory_has_entries(&app.moddir.join(MODULE_TRANSACTION_STAGE));
    StateRecord::new(Domain::Transactions)
        .field(
            "state",
            if transparent || subscription || module {
                "active"
            } else {
                "idle"
            },
        )
        .bool("transparent", transparent)
        .bool("subscription", subscription)
        .bool("module_files", module)
}

fn map_value(
    values: &std::collections::HashMap<String, String>,
    key: &str,
    fallback: &str,
) -> String {
    values
        .get(key)
        .map(|value| sanitize_token(value.clone()))
        .filter(|value| value != "unknown")
        .unwrap_or_else(|| fallback.to_string())
}

fn read_token(path: PathBuf, fallback: &str) -> String {
    fs::read_to_string(path)
        .ok()
        .map(sanitize_token)
        .filter(|value| value != "unknown")
        .unwrap_or_else(|| fallback.to_string())
}

fn regular_nonempty(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_file() && metadata.len() > 0)
}

fn clean_line_count(path: &Path) -> usize {
    fs::read_to_string(path)
        .ok()
        .map(|text| {
            text.lines()
                .filter(|line| {
                    let line = line.trim();
                    !line.is_empty() && !line.starts_with('#')
                })
                .count()
        })
        .unwrap_or(0)
}

fn directory_has_entries(path: &Path) -> bool {
    fs::read_dir(path)
        .ok()
        .and_then(|mut entries| entries.next())
        .is_some()
}

#[cfg(test)]
fn wifi_record(app: &App) -> StateRecord {
    wifi_record_with_supervisor(
        app,
        &supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy"),
    )
}

#[cfg(test)]
mod tests {
    use super::{
        app_policy_record, selectors_record, subscription_record, wifi_record, Domain, StateRecord,
    };
    use crate::App;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture() -> (std::path::PathBuf, App) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "magicnet-state-test-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(root.join(".config/magicnet")).expect("create config");
        fs::create_dir_all(root.join(".config/sing-box")).expect("create sing-box config");
        fs::create_dir_all(root.join(".state/wifi-policy")).expect("create wifi state");
        fs::create_dir_all(root.join(".state/sing-box")).expect("create subscription state");
        let app = App::for_test(root.clone());
        (root, app)
    }

    #[test]
    fn state_record_is_a_bounded_token_file() {
        let text = StateRecord::new(Domain::Service)
            .field("state", "running\nsecret=value")
            .encode();
        assert!(text.contains("schema=1\n"));
        assert!(text.contains("domain=service\n"));
        assert!(text.contains("state=unknown\n"));
        assert!(!text.contains("secret=value"));
    }

    #[test]
    fn wifi_state_never_persists_network_identity() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/wifi-policy.conf"),
            "MAGICNET_WIFI_POLICY_ENABLED=0\nMAGICNET_WIFI_POLICY_MODE=blacklist\n",
        )
        .expect("write wifi config");
        fs::write(
            root.join(".state/wifi-policy/last-state.conf"),
            "connected=1\nssid=private-network-name\nbssid=aa:bb:cc:dd:ee:ff\nmatched=1\ndesired_mode=direct\ncurrent_mode=direct\n",
        )
        .expect("write wifi state");
        let text = wifi_record(&app).encode();
        assert!(text.contains("has_ssid=1"));
        assert!(text.contains("has_bssid=1"));
        assert!(!text.contains("private-network-name"));
        assert!(!text.contains("aa:bb:cc:dd:ee:ff"));
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn selector_state_exposes_only_count() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/selector-selections.json"),
            r#"{"private-group":"private-node","another-group":"another-node"}"#,
        )
        .expect("write selector state");
        let text = selectors_record(&app).encode();
        assert!(text.contains("state=ready"));
        assert!(text.contains("selection_count=2"));
        assert!(!text.contains("private-group"));
        assert!(!text.contains("private-node"));
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn app_policy_state_exposes_only_uid_counts() {
        let (root, app) = fixture();
        fs::create_dir_all(root.join(".state/app-policy")).expect("create app policy state");
        fs::write(
            root.join(".state/app-policy/include-uids.list"),
            "10001\n10002\n",
        )
        .expect("write include uids");
        fs::write(
            root.join(".state/app-policy/exclude-uids.list"),
            "0\n10003\n",
        )
        .expect("write exclude uids");
        let text = app_policy_record(&app).encode();
        assert!(text.contains("include_uid_count=2"));
        assert!(text.contains("exclude_uid_count=2"));
        assert!(!text.contains("10001"));
        assert!(!text.contains("10003"));
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn subscription_journal_without_owner_is_recovery_pending() {
        let (root, app) = fixture();
        fs::write(
            root.join(".state/sing-box/subscription-status"),
            "phase=commit\nresult=success\ngeneration_id=123-456\n",
        )
        .expect("write subscription status");
        fs::create_dir_all(root.join(".state/sing-box/subscription-transaction"))
            .expect("create transaction");
        let text = subscription_record(&app).encode();
        assert!(text.contains("state=recovery_pending"));
        assert!(text.contains("transaction_pending=1"));
        fs::remove_dir_all(root).expect("remove fixture");
    }
    #[test]
    fn subscription_stale_lock_never_proves_running() {
        let (root, app) = fixture();
        let lock = root.join(super::SUBSCRIPTION_UPDATE_LOCK);
        fs::create_dir_all(&lock).unwrap();
        fs::write(lock.join("owner"), "4294967295:1:expired\n").unwrap();
        fs::write(
            root.join(super::SUBSCRIPTION_STATUS),
            "result=running\nphase=commit\n",
        )
        .unwrap();
        let text = subscription_record(&app).encode();
        assert!(text.contains("state=interrupted\n"), "{text}");
        assert!(text.contains("owner=stale\n"), "{text}");
        assert!(lock.join("owner").exists());
        fs::create_dir_all(root.join(super::SUBSCRIPTION_TRANSACTION)).unwrap();
        assert!(subscription_record(&app)
            .encode()
            .contains("state=recovery_pending\n"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn empty_subscription_lock_is_pending_not_running() {
        let (root, app) = fixture();
        fs::create_dir_all(root.join(super::SUBSCRIPTION_UPDATE_LOCK)).unwrap();
        let text = subscription_record(&app).encode();
        assert!(text.contains("state=pending\n"), "{text}");
        assert!(!text.contains("state=running\n"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn update_owner_requires_start_time_and_complete_identity() {
        let (root, app) = fixture();
        let lock = root.join(super::SUBSCRIPTION_UPDATE_LOCK);
        fs::create_dir_all(&lock).unwrap();
        let pid = std::process::id();
        let start =
            crate::proc_start_time(&fs::read_to_string(format!("/proc/{pid}/stat")).unwrap())
                .unwrap();
        fs::write(lock.join("owner"), format!("{pid}:{start}:test-nonce\n")).unwrap();
        assert_eq!(super::subscription_update_owner_state(&app), "active");
        for owner in [
            format!("{pid}:0:nonce"),
            format!("{pid}:{start}"),
            format!("0:{start}:nonce"),
            format!("{pid}:{start}:nonce:extra"),
            format!("{pid}::nonce"),
        ] {
            fs::write(lock.join("owner"), &owner).unwrap();
            let expected = if owner == format!("{pid}:0:nonce") {
                "stale"
            } else {
                "unknown"
            };
            assert_eq!(super::subscription_update_owner_state(&app), expected);
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn process_inspection_failure_is_unknown_and_owner_reads_are_bounded() {
        let (root, _app) = fixture();
        let owner = root.join("owner");
        let proc_root = root.join("fake-proc");
        fs::create_dir_all(proc_root.join("123")).unwrap();
        fs::write(&owner, "123:456:nonce").unwrap();
        assert_eq!(
            super::inspect_process_owner(&owner, None, None, &proc_root),
            "unknown"
        );
        fs::write(&owner, "x".repeat(257)).unwrap();
        assert_eq!(
            super::inspect_process_owner(&owner, None, None, &proc_root),
            "stale"
        );
        fs::remove_file(&owner).unwrap();
        std::os::unix::fs::symlink(root.join("missing"), &owner).unwrap();
        assert_eq!(
            super::inspect_process_owner(&owner, None, None, &proc_root),
            "unknown"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn config_records_borrow_the_same_observation() {
        let (root, app) = fixture();
        fs::write(root.join(super::SINGBOX_CONFIG), "{}").unwrap();
        let observed = serde_json::json!({
            "inbounds": [{"tag":"tun-in", "type":"ebpf", "mode":"shared"}],
            "endpoints": [{"type":"tailscale", "tag":"private-tailnet"}]
        });
        assert!(super::transparent_record(&app, Some(&observed))
            .encode()
            .contains("effective_type=ebpf"));
        let tailnet = super::tailscale_record(&app, Some(&observed)).encode();
        assert!(tailnet.contains("endpoint_count=1"));
        assert!(!tailnet.contains("private-tailnet"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn wifi_publication_does_not_touch_unrelated_domains() {
        let (root, app) = fixture();
        fs::create_dir_all(root.join(super::STATE_ROOT)).unwrap();
        let unrelated = root.join(super::STATE_ROOT).join("transparent.state");
        fs::write(&unrelated, "unchanged-observation\n").unwrap();
        super::reconcile_wifi(&app).unwrap();
        assert_eq!(
            fs::read_to_string(&unrelated).unwrap(),
            "unchanged-observation\n"
        );
        assert!(root.join(super::STATE_ROOT).join("wifi.state").is_file());
        assert!(root
            .join(super::STATE_ROOT)
            .join("supervisors.state")
            .is_file());
        assert!(!root
            .join(super::STATE_ROOT)
            .join("tailscale.state")
            .exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn json_observation_rejects_oversized_and_nonregular_sources() {
        let (root, _) = fixture();
        let file = root.join("bounded.json");
        fs::write(&file, "{\"value\":123}").unwrap();
        assert!(super::read_json(&file, 4).is_none());
        assert!(super::read_json(&file, 128).is_some());
        let link = root.join("link.json");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(super::read_json(&link, 128).is_none());
        let fifo = root.join("fifo.json");
        let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert!(super::read_json(&fifo, 128).is_none());
        fs::remove_dir_all(root).unwrap();
    }
}
