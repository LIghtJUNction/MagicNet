use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::{ebpf_runtime::inspect_ebpf_attachments, run_magicnet_function, App};

const CONFIG: &str = ".config/sing-box/config.json";
const CAPABILITY: &str = ".state/transparent-ebpf/capability";
const PROBE_REPORT: &str = ".state/transparent-ebpf/probe.json";
const SHARED_PENDING: &str = ".state/transparent-ebpf/shared.pending";
const TRANSACTION: &str = ".state/transparent-transaction";
const RECENT_ERROR: &str = ".state/transparent-recent-error";

pub(super) struct Status {
    pub(super) configured_mode: String,
    pub(super) effective_type: String,
    pub(super) effective_mode: String,
    pub(super) capability: String,
    pub(super) local_cgroup: &'static str,
    pub(super) shared_tc: &'static str,
    pub(super) shared_interface_count: usize,
    pub(super) transition: String,
    pub(super) has_recent_error: bool,
    pub(super) dataplane_ready: Option<bool>,
}

impl Status {
    pub(super) fn as_value(&self) -> Value {
        json!({
            // Keep `mode` as the compatibility alias introduced by schema 1.
            "mode": self.configured_mode,
            "configured_mode": self.configured_mode,
            "effective_type": self.effective_type,
            "effective_mode": self.effective_mode,
            "capability": self.capability,
            "local_cgroup": self.local_cgroup,
            "shared_tc": self.shared_tc,
            "shared_interface_count": self.shared_interface_count,
            "transition": self.transition,
            "has_recent_error": self.has_recent_error,
            "dataplane_ready": self.dataplane_ready,
        })
    }
}

pub(super) fn snapshot(app: &App, process_state: &str, configured_mode: &str) -> Status {
    let config = read_regular_text(&app.moddir.join(CONFIG), 4 * 1024 * 1024)
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let inbound = config
        .as_ref()
        .and_then(|value| value.get("inbounds"))
        .and_then(Value::as_array)
        .and_then(|inbounds| {
            inbounds
                .iter()
                .find(|inbound| inbound.get("tag").and_then(Value::as_str) == Some("tun-in"))
        });
    let effective_type = match inbound
        .and_then(|value| value.get("type"))
        .and_then(Value::as_str)
    {
        Some("tun") => "tun",
        Some("ebpf") => "ebpf",
        _ => configured_mode,
    }
    .to_string();
    let effective_mode = if effective_type == "ebpf" {
        inbound
            .and_then(|value| value.get("mode"))
            .and_then(Value::as_str)
            .filter(|mode| matches!(*mode, "local" | "shared" | "hybrid"))
            .unwrap_or("local")
            .to_string()
    } else {
        "tun".to_string()
    };
    let transition = transaction_phase(app).unwrap_or_else(|| "idle".to_string());
    let has_recent_error = regular_file_nonempty(&app.moddir.join(RECENT_ERROR));

    if effective_type != "ebpf" {
        let ready = match process_state {
            "running" => Some(tun_interface_ready(inbound)),
            "stopped" => Some(false),
            _ => None,
        };
        return Status {
            configured_mode: configured_mode.to_string(),
            effective_type,
            effective_mode,
            capability: "not_required".to_string(),
            local_cgroup: "inactive",
            shared_tc: "inactive",
            shared_interface_count: 0,
            transition,
            has_recent_error,
            dataplane_ready: ready,
        };
    }

    let shared_interfaces = shared_interfaces(inbound);
    let local_expected = matches!(effective_mode.as_str(), "local" | "hybrid");
    let shared_expected = matches!(effective_mode.as_str(), "shared" | "hybrid");
    let capability = read_regular_text(&app.moddir.join(CAPABILITY), 64)
        .map(|value| value.trim().to_string())
        .filter(|value| matches!(value.as_str(), "ok" | "failed"))
        .unwrap_or_else(|| "unknown".to_string());
    let attachments = if process_state == "running"
        && run_magicnet_function(
            app,
            "magicnet_ebpf_refresh_active_report >/dev/null 2>&1",
        )
        .is_ok()
    {
        read_regular_text(&app.moddir.join(PROBE_REPORT), 512 * 1024)
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .map(|report| {
                let cgroup_path = inbound
                    .and_then(|value| value.get("local"))
                    .and_then(|value| value.get("cgroup_path"))
                    .and_then(Value::as_str)
                    .filter(|path| Path::new(path).is_absolute())
                    .unwrap_or("/sys/fs/cgroup");
                inspect_ebpf_attachments(
                    app,
                    &report,
                    local_expected,
                    cgroup_path,
                    &network_values(inbound),
                    &shared_interfaces,
                )
            })
    } else {
        None
    };
    let local_cgroup = if !local_expected {
        "inactive"
    } else if process_state == "stopped" {
        "configured"
    } else if process_state != "running" {
        "unknown"
    } else if attachments
        .as_ref()
        .is_some_and(|evidence| evidence.local_attached)
    {
        "attached"
    } else if attachments.is_some() {
        "missing"
    } else {
        "unknown"
    };
    let shared_tc = if !shared_expected {
        if regular_file_nonempty(&app.moddir.join(SHARED_PENDING)) {
            "pending"
        } else {
            "inactive"
        }
    } else if shared_interfaces.is_empty() {
        "pending"
    } else if process_state == "stopped" {
        "configured"
    } else if process_state != "running" {
        "unknown"
    } else if attachments
        .as_ref()
        .is_some_and(|evidence| evidence.shared_attached)
    {
        "attached"
    } else if attachments.is_some() {
        "missing"
    } else {
        "unknown"
    };
    let dataplane_ready = match process_state {
        "stopped" => Some(false),
        "running" => attachments.as_ref().map(|evidence| {
            let local_ready = !local_expected || evidence.local_attached;
            let shared_ready = !shared_expected
                || (!shared_interfaces.is_empty() && evidence.shared_attached);
            capability == "ok" && local_ready && shared_ready
        }),
        _ => None,
    };

    Status {
        configured_mode: configured_mode.to_string(),
        effective_type,
        effective_mode,
        capability,
        local_cgroup,
        shared_tc,
        shared_interface_count: shared_interfaces.len(),
        transition,
        has_recent_error,
        dataplane_ready,
    }
}

fn tun_interface_ready(inbound: Option<&Value>) -> bool {
    let interface = inbound
        .and_then(|value| value.get("interface_name"))
        .and_then(Value::as_str)
        .filter(|value| valid_interface_name(value))
        .unwrap_or("magicnet0");
    Path::new("/sys/class/net").join(interface).exists()
}

fn valid_interface_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

fn shared_interfaces(inbound: Option<&Value>) -> Vec<String> {
    inbound
        .and_then(|value| value.get("shared"))
        .and_then(|value| value.get("interface"))
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .filter(|value| valid_interface_name(value))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn network_values(inbound: Option<&Value>) -> Vec<String> {
    let values = match inbound.and_then(|value| value.get("network")) {
        Some(Value::String(value)) if matches!(value.as_str(), "tcp" | "udp") => {
            vec![value.clone()]
        }
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(Value::as_str)
            .filter(|value| matches!(*value, "tcp" | "udp"))
            .map(str::to_string)
            .collect(),
        _ => Vec::new(),
    };
    if values.is_empty() {
        vec!["tcp".to_string(), "udp".to_string()]
    } else {
        values
    }
}

fn transaction_phase(app: &App) -> Option<String> {
    let value = read_regular_text(&app.moddir.join(TRANSACTION).join("phase"), 128)?;
    let value = value.trim();
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        Some(value.to_string())
    } else {
        None
    }
}

fn read_regular_text(path: &Path, max_bytes: u64) -> Option<String> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if !metadata.file_type().is_file() || metadata.len() > max_bytes {
        return None;
    }
    fs::read_to_string(path).ok()
}

fn regular_file_nonempty(path: &PathBuf) -> bool {
    fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_file() && metadata.len() > 0)
}

#[cfg(test)]
mod tests {
    use super::{network_values, valid_interface_name};
    use serde_json::json;

    #[test]
    fn interface_names_cannot_escape_sysfs_or_expose_paths() {
        assert!(valid_interface_name("magicnet0"));
        assert!(valid_interface_name("wlan0"));
        assert!(!valid_interface_name("../proc/self"));
        assert!(!valid_interface_name("rmnet/data0"));
    }

    #[test]
    fn network_values_are_bounded_to_supported_protocols() {
        let inbound = json!({"network": ["tcp", "icmp", "udp"]});
        assert_eq!(network_values(Some(&inbound)), vec!["tcp", "udp"]);
        assert_eq!(network_values(None), vec!["tcp", "udp"]);
    }
}
