//! App network-policy observations are independent of sing-box dataplane health.
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::process::Command;
use std::time::Duration;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::{run_bounded_command, App};

const BRIDGE: &str = "libexec/network-policy-bridge.jar";
const LIMIT: usize = 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug)]
struct Policy {
    provider: &'static str,
    uid: u32,
    value: u32,
    packages: Vec<String>,
}

impl Policy {
    fn candidate(&self) -> String {
        let bytes = json!([self.provider, self.uid, self.value, self.packages]).to_string();
        format!("{:x}", Sha256::digest(bytes.as_bytes()))
    }

    fn known_oem_deny(&self) -> bool {
        self.provider == "oplus"
            && self.uid % 100000 >= 10000
            && self.uid % 100000 < 90000
            && matches!(self.value, 1 | 2 | 4)
            && !self.packages.is_empty()
    }

    fn public(&self) -> Value {
        json!({
            "candidate": self.candidate(),
            "provider": self.provider,
            "packages": self.packages,
            "shared_identity": self.packages.len() > 1,
            "configured": match (self.provider, self.value) {
                (_, 0) => "none",
                ("oplus", 1) => "reject_mobile",
                ("oplus", 2) => "reject_wifi",
                ("oplus", 4) => "reject_all",
                ("android", value) if value & 1 != 0 => "reject_metered_background",
                _ => "unknown_policy",
            },
            "effective": "not_probed",
            "known_oem_deny": self.known_oem_deny(),
        })
    }
}

fn bridge(app: &App, args: &[&str]) -> Result<Value, &'static str> {
    let path = app.moddir.join(BRIDGE);
    let metadata = fs::symlink_metadata(&path).map_err(|_| "bridge_unavailable")?;
    if !metadata.is_file()
        || metadata.len() > LIMIT as u64
        || metadata.permissions().mode() & 0o022 != 0
        || (metadata.uid() != 0 && metadata.uid() != unsafe { libc::geteuid() })
    {
        return Err("bridge_unsafe");
    }
    let mut command = Command::new("app_process");
    command
        .env("CLASSPATH", &path)
        .args(["/system/bin", "io.github.magicnet.NetworkPolicyBridge"])
        .args(args);
    let output = run_bounded_command(command, TIMEOUT, LIMIT).map_err(|_| "bridge_unavailable")?;
    if output.timed_out || output.truncated || !output.status.is_some_and(|status| status.success())
    {
        return Err("observation_failed");
    }
    let value: Value =
        serde_json::from_slice(&output.stdout).map_err(|_| "invalid_bridge_response")?;
    if value["schema"] != 1 {
        return Err("invalid_bridge_response");
    }
    if value["ok"] != true {
        return Err(match value["error"].as_str() {
            Some("provider_unsupported") => "provider_unsupported",
            Some("policy_conflict") => "policy_conflict",
            Some("repair_not_effective") => "repair_not_effective",
            Some("repair_unsupported") => "repair_unsupported",
            _ => "observation_failed",
        });
    }
    Ok(value)
}

fn packages_from_text(text: &str) -> Result<BTreeMap<u32, Vec<String>>, &'static str> {
    let mut result: BTreeMap<u32, Vec<String>> = BTreeMap::new();
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let (name, uid) = line
            .strip_prefix("package:")
            .and_then(|line| line.rsplit_once(" uid:"))
            .ok_or("package_inventory_invalid")?;
        if name.is_empty()
            || name.len() > 255
            || !name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._".contains(&b))
        {
            return Err("package_inventory_invalid");
        }
        let uid = uid
            .parse::<u32>()
            .map_err(|_| "package_inventory_invalid")?;
        result.entry(uid).or_default().push(name.to_string());
    }
    if result.is_empty() {
        return Err("package_inventory_unavailable");
    }
    for names in result.values_mut() {
        names.sort();
        names.dedup();
    }
    Ok(result)
}

fn package_inventory() -> Result<BTreeMap<u32, Vec<String>>, &'static str> {
    let mut command = Command::new("cmd");
    command.args(["package", "list", "packages", "-U"]);
    let output = run_bounded_command(command, TIMEOUT, LIMIT)
        .map_err(|_| "package_inventory_unavailable")?;
    if output.timed_out || output.truncated || !output.status.is_some_and(|status| status.success())
    {
        return Err("package_inventory_unavailable");
    }
    packages_from_text(
        std::str::from_utf8(&output.stdout).map_err(|_| "package_inventory_invalid")?,
    )
}

fn parse_policies(
    provider: &'static str,
    value: &Value,
    packages: &BTreeMap<u32, Vec<String>>,
) -> Result<Vec<Policy>, &'static str> {
    if value["provider"] != provider {
        return Err("invalid_bridge_response");
    }
    let entries = value["entries"]
        .as_array()
        .ok_or("invalid_bridge_response")?;
    if entries.len() > 16384 {
        return Err("invalid_bridge_response");
    }
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    for item in entries {
        let uid = item["uid"]
            .as_u64()
            .and_then(|v| u32::try_from(v).ok())
            .ok_or("invalid_bridge_response")?;
        let policy = item["policy"]
            .as_u64()
            .and_then(|v| u32::try_from(v).ok())
            .ok_or("invalid_bridge_response")?;
        if !seen.insert(uid) {
            return Err("invalid_bridge_response");
        }
        if policy != 0 {
            result.push(Policy {
                provider,
                uid,
                value: policy,
                packages: packages.get(&uid).cloned().unwrap_or_default(),
            });
        }
    }
    Ok(result)
}

fn collect(app: &App) -> (Vec<Value>, Vec<Policy>, Option<&'static str>) {
    let inventory = package_inventory();
    let empty = BTreeMap::new();
    let packages = inventory.as_ref().unwrap_or(&empty);
    let mut providers = Vec::new();
    let mut policies = Vec::new();
    for provider in ["android", "oplus"] {
        match bridge(app, &["inspect", provider])
            .and_then(|v| parse_policies(provider, &v, packages))
        {
            Ok(entries) => {
                providers.push(json!({"provider":provider,"status":"observed","configured_entry_count":entries.len(),"coverage":if provider == "android" {"metered_background_policy"} else {"vendor_uid_policies"}}));
                policies.extend(entries);
            }
            Err(reason) => providers.push(json!({
                "provider":provider,
                "status":if reason == "provider_unsupported" { "unsupported" } else { "unknown" },
                "reason":reason,
                "configured_entry_count":Value::Null,
            })),
        }
    }
    (providers, policies, inventory.err())
}

pub(crate) fn inspect(app: &App, private: bool) -> Value {
    let (providers, policies, inventory_error) = collect(app);
    let mut result = json!({
        "providers":providers,
        "package_inventory":if inventory_error.is_none() { "observed" } else { "unknown" },
        "package_inventory_error":inventory_error,
        "known_restriction_count":policies.len(),
        "known_oem_deny_count":policies.iter().filter(|p| p.known_oem_deny()).count(),
        "effective_system_dns":"not_probed",
        "coverage":"available_policy_adapters",
        "repair_supported":false,
    });
    if private {
        result["entries"] = policies.iter().map(Policy::public).collect();
    }
    result
}

pub(crate) fn command(app: &App, args: &[String]) -> Result<(), String> {
    let value = match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        [] | ["status"] => inspect(app, false),
        ["inspect"] => inspect(app, true),
        _ => return Err("cli network-access {status|inspect}".to_string()),
    };
    println!("{value}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_inventory_preserves_shared_identities_and_rejects_partial_garbage() {
        let map = packages_from_text(
            "package:com.google.android.gms uid:10109\npackage:com.google.android.gsf uid:10109\n",
        )
        .unwrap();
        assert_eq!(map[&10109].len(), 2);
        assert!(packages_from_text("package:app.good uid:10001\npermission denied").is_err());
        assert!(packages_from_text("").is_err());
    }

    #[test]
    fn candidate_changes_when_scope_or_policy_changes() {
        let mut p = Policy {
            provider: "oplus",
            uid: 10001,
            value: 4,
            packages: vec!["app.one".into()],
        };
        let old = p.candidate();
        p.packages.push("app.shared".into());
        assert_ne!(old, p.candidate());
        let shared = p.candidate();
        p.value = 1;
        assert_ne!(shared, p.candidate());
    }

    #[test]
    fn repair_rejects_system_isolated_unknown_and_user_data_saver_policies() {
        let mut p = Policy {
            provider: "oplus",
            uid: 10001,
            value: 4,
            packages: vec!["app.one".into()],
        };
        assert!(p.known_oem_deny());
        p.uid = 1000;
        assert!(!p.known_oem_deny());
        p.uid = 99001;
        assert!(!p.known_oem_deny());
        p.uid = 110001;
        assert!(p.known_oem_deny());
        p.value = 3;
        assert!(!p.known_oem_deny());
        p.value = 4;
        p.provider = "android";
        assert!(!p.known_oem_deny());
    }

    #[test]
    fn duplicate_uids_and_inconsistent_provider_are_not_accepted() {
        let packages = BTreeMap::new();
        let value = json!({"provider":"oplus","entries":[{"uid":10001,"policy":4},{"uid":10001,"policy":0}]});
        assert!(parse_policies("oplus", &value, &packages).is_err());
        assert!(parse_policies("android", &value, &packages).is_err());
    }

    #[test]
    fn configured_restriction_does_not_claim_effective_dns_failure_or_expose_uid() {
        let p = Policy {
            provider: "oplus",
            uid: 10001,
            value: 4,
            packages: vec!["app.one".into()],
        };
        let value = p.public();
        assert_eq!(value["configured"], "reject_all");
        assert_eq!(value["effective"], "not_probed");
        assert!(value.get("uid").is_none());
    }
}
