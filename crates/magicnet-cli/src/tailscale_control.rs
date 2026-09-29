//! Tailscale is optional. Pausing preserves identity; logout forgets this device.
//! Only lifecycle commands write; `--json tailscale status` is observation-only.
use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path};

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::{owned_singbox_pids, replace_module_text_files_transactionally, App};

const CONFIG: &str = ".config/sing-box/config.json";
const PAUSED: &str = ".config/sing-box/tailscale-paused.json";
const AUTH: &str = ".config/sing-box/tailscale-auth.json";
const STATE: &str = ".state/sing-box/tailscale";
const STANDALONE: &str = ".config/sing-box/standalone-config";
const LIMIT: u64 = 1024 * 1024;
type Result<T> = std::result::Result<T, &'static str>;

#[derive(Clone)]
struct Settings {
    config: Value,
    paused: Value,
    auth: Value,
}

fn safe_path(app: &App, relative: &Path) -> Result<()> {
    let mut path = app.moddir.clone();
    for part in relative.components() {
        let Component::Normal(part) = part else {
            return Err("tailscale.unsafe_path");
        };
        path.push(part);
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err("tailscale.unsafe_path")
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(_) => return Err("tailscale.read_failed"),
        }
    }
    Ok(())
}

fn read_json(app: &App, relative: &str, fallback: Value) -> Result<Value> {
    safe_path(app, Path::new(relative))?;
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(app.moddir.join(relative))
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(fallback),
        Err(_) => return Err("tailscale.read_failed"),
    };
    let metadata = file.metadata().map_err(|_| "tailscale.read_failed")?;
    if !metadata.is_file() || metadata.len() > LIMIT {
        return Err("tailscale.invalid_config");
    }
    let mut text = String::new();
    file.take(LIMIT + 1)
        .read_to_string(&mut text)
        .map_err(|_| "tailscale.read_failed")?;
    if text.len() as u64 > LIMIT {
        return Err("tailscale.invalid_config");
    }
    serde_json::from_str(&text).map_err(|_| "tailscale.invalid_config")
}

fn endpoints(config: &Value) -> Result<Vec<Value>> {
    match config.get("endpoints") {
        None if config.is_object() => Ok(Vec::new()),
        Some(Value::Array(items)) if items.iter().all(Value::is_object) => Ok(items.clone()),
        _ => Err("tailscale.invalid_config"),
    }
}

fn tailnets(config: &Value) -> Result<Vec<Value>> {
    let items: Vec<_> = endpoints(config)?
        .into_iter()
        .filter(|item| item["type"] == "tailscale")
        .collect();
    let mut tags = BTreeSet::new();
    for item in &items {
        let tag = item["tag"]
            .as_str()
            .filter(|tag| !tag.is_empty())
            .ok_or("tailscale.invalid_config")?;
        if !tags.insert(tag) {
            return Err("tailscale.invalid_config");
        }
    }
    Ok(items)
}

impl Settings {
    fn read(app: &App) -> Result<Self> {
        let data = Self {
            config: read_json(app, CONFIG, json!({}))?,
            paused: read_json(
                app,
                PAUSED,
                json!({"schema":1,"phase":"idle","endpoints":[]}),
            )?,
            auth: read_json(app, AUTH, json!({}))?,
        };
        tailnets(&data.config)?;
        if data.paused["schema"] != 1
            || !data.auth.is_object()
            || !matches!(
                data.paused["phase"].as_str(),
                Some("idle" | "logout-pending")
            )
            || tailnets(&data.paused)?.len() != endpoints(&data.paused)?.len()
        {
            return Err("tailscale.invalid_config");
        }
        Ok(data)
    }

    fn revision(&self) -> String {
        let value = json!([self.config, self.paused, self.auth]);
        format!("{:x}", Sha256::digest(value.to_string().as_bytes()))
    }

    fn persist(&self, app: &App) -> Result<()> {
        let config = serde_json::to_string_pretty(&self.config)
            .map_err(|_| "tailscale.invalid_config")?
            + "\n";
        let paused = self.paused.to_string() + "\n";
        let auth = self.auth.to_string() + "\n";
        replace_module_text_files_transactionally(
            app,
            &[
                (Path::new(CONFIG), &config),
                (Path::new(PAUSED), &paused),
                (Path::new(AUTH), &auth),
                (Path::new(STANDALONE), "validated\n"),
            ],
        )
        .map_err(|_| "tailscale.persist_failed")
    }
}

fn has_local_state(app: &App) -> Result<bool> {
    safe_path(app, Path::new(STATE))?;
    match fs::read_dir(app.moddir.join(STATE)) {
        Ok(mut entries) => match entries.next() {
            None => Ok(false),
            Some(Ok(_)) => Ok(true),
            Some(Err(_)) => Err("tailscale.read_failed"),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("tailscale.read_failed"),
    }
}

fn observation_lock(app: &App) -> Result<Option<File>> {
    safe_path(app, Path::new(".state/config-apply.lock"))?;
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(app.moddir.join(".state/config-apply.lock"))
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("tailscale.busy"),
    };
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
        return Err("tailscale.busy");
    }
    Ok(Some(file))
}

pub(crate) fn paused_state(app: &App) -> Result<(bool, bool)> {
    let paused = read_json(
        app,
        PAUSED,
        json!({"schema":1,"phase":"idle","endpoints":[]}),
    )?;
    if paused["schema"] != 1 {
        return Err("tailscale.invalid_config");
    }
    Ok((
        !tailnets(&paused)?.is_empty(),
        paused["phase"] == "logout-pending",
    ))
}

pub(crate) fn status(app: &App) -> Result<Value> {
    // A status read must never create lock files or state directories.
    let guard = observation_lock(app)?;
    if app
        .moddir
        .join(".state/sing-box/subscription-update.lock")
        .exists()
    {
        return Err("tailscale.busy");
    }
    let data = Settings::read(app)?;
    if guard.is_none() && app.moddir.join(".state/config-apply.lock").exists() {
        return Err("tailscale.busy");
    }
    Ok(json!({
        "enabled": !tailnets(&data.config)?.is_empty(),
        "resumable": !tailnets(&data.paused)?.is_empty(),
        "logout_pending": data.paused["phase"] == "logout-pending",
        "local_identity": if data.auth.as_object().is_some_and(|keys| !keys.is_empty()) { Some(true) } else { has_local_state(app).ok() },
        "revision": data.revision(),
        "core": match owned_singbox_pids(app) {
            Ok(pids) if pids.is_empty() => "stopped", Ok(_) => "running", Err(_) => "unknown",
        },
    }))
}

// Remove only rules owned by the module, including pre-1.5.15 spellings.
// A custom reference is never silently discarded or redirected to the Internet.
fn remove_routes(config: &mut Value, tags: &BTreeSet<String>) -> Result<()> {
    let mut dns_tags = BTreeSet::new();
    if let Some(servers) = config
        .pointer_mut("/dns/servers")
        .and_then(Value::as_array_mut)
    {
        for server in servers.iter() {
            if server["type"] == "tailscale"
                && server["endpoint"]
                    .as_str()
                    .is_some_and(|tag| tags.contains(tag))
            {
                let tag = server["tag"]
                    .as_str()
                    .ok_or("tailscale.custom_references")?;
                if *server != json!({"type":"tailscale","tag":tag,"endpoint":server["endpoint"]}) {
                    return Err("tailscale.custom_references");
                }
                dns_tags.insert(tag.to_string());
            }
        }
        servers.retain(|server| {
            !server["tag"]
                .as_str()
                .is_some_and(|tag| dns_tags.contains(tag))
        });
    }
    if let Some(rules) = config
        .pointer_mut("/dns/rules")
        .and_then(Value::as_array_mut)
    {
        rules.retain(|rule| {
            !dns_tags
                .iter()
                .any(|tag| *rule == json!({"domain_suffix":["ts.net"],"server":tag}))
        });
    }
    if let Some(rules) = config
        .pointer_mut("/route/rules")
        .and_then(Value::as_array_mut)
    {
        rules.retain(|rule| !tags.iter().any(|tag| {
            let mut domain = json!({"domain_suffix":["ts.net"],"outbound":tag});
            let mut ip = json!({"ip_cidr":["100.64.0.0/10","fd7a:115c:a1e0::/48"],"preferred_by":[tag],"outbound":tag});
            for action in [false, true] {
                if action { domain["action"] = json!("route"); ip["action"] = json!("route"); }
                if *rule == domain || *rule == ip { return true; }
                let mut legacy = ip.clone(); legacy["preferred_by"] = json!(["tailscale"]);
                if *rule == legacy { return true; }
            }
            false
        }));
    }
    fn references(value: &Value, tags: &BTreeSet<String>, dns: &BTreeSet<String>) -> bool {
        match value {
            Value::Array(items) => items.iter().any(|item| references(item, tags, dns)),
            Value::Object(items) => items.iter().any(|(key, item)| {
                let endpoint_key = matches!(
                    key.as_str(),
                    "outbound" | "outbounds" | "endpoint" | "detour" | "final" | "preferred_by"
                );
                let dns_key = matches!(key.as_str(), "server" | "final");
                let matches_tag = |text: &str| {
                    (endpoint_key && tags.contains(text)) || (dns_key && dns.contains(text))
                };
                item.as_str().is_some_and(matches_tag)
                    || item.as_array().is_some_and(|items| {
                        items
                            .iter()
                            .any(|item| item.as_str().is_some_and(matches_tag))
                    })
                    || references(item, tags, dns)
            }),
            _ => false,
        }
    }
    if references(config, tags, &dns_tags) {
        return Err("tailscale.custom_references");
    }
    Ok(())
}

fn plan(data: &Settings, action: &str) -> Result<Settings> {
    let mut next = data.clone();
    let active = tailnets(&data.config)?;
    let paused = tailnets(&data.paused)?;
    if action == "enable" {
        if data.paused["phase"] == "logout-pending" {
            return Err("tailscale.logout_pending");
        }
        if !active.is_empty() {
            return Ok(next);
        }
        if paused.is_empty() {
            return Err("tailscale.not_configured");
        }
        let mut used = BTreeSet::new();
        for key in ["inbounds", "outbounds", "endpoints"] {
            if let Some(items) = next.config[key].as_array() {
                for item in items {
                    if let Some(tag) = item["tag"].as_str() {
                        used.insert(tag.to_string());
                    }
                }
            }
        }
        if paused
            .iter()
            .any(|item| item["tag"].as_str().is_some_and(|tag| used.contains(tag)))
        {
            return Err("tailscale.tag_conflict");
        }
        let mut all = endpoints(&next.config)?;
        all.extend(paused);
        next.config["endpoints"] = json!(all);
        next.paused = json!({"schema":1,"phase":"idle","endpoints":[]});
        return Ok(next);
    }
    let tags: BTreeSet<String> = active
        .iter()
        .filter_map(|item| item["tag"].as_str().map(str::to_string))
        .collect();
    let mut saved = paused;
    for mut item in active {
        let tag = item["tag"]
            .as_str()
            .ok_or("tailscale.invalid_config")?
            .to_string();
        if let Some(key) = item
            .as_object_mut()
            .and_then(|item| item.remove("auth_key"))
        {
            if key.as_str().is_some_and(|key| !key.is_empty()) {
                next.auth[&tag] = key;
            }
        }
        saved.retain(|old| old["tag"] != tag);
        saved.push(item);
    }
    if !tags.is_empty() {
        next.config["endpoints"] = json!(endpoints(&next.config)?
            .into_iter()
            .filter(|item| item["type"] != "tailscale")
            .collect::<Vec<_>>());
        remove_routes(&mut next.config, &tags)?;
    }
    next.paused = json!({"schema":1,"phase":if action == "logout" {"logout-pending"} else {data.paused["phase"].as_str().unwrap_or("idle")},"endpoints":saved});
    if action == "logout" {
        next.auth = json!({});
    }
    Ok(next)
}

fn forget_identity(app: &App, paused: &Value) -> Result<()> {
    let owned = app.moddir.join(STATE);
    for endpoint in tailnets(paused)? {
        if let Some(directory) = endpoint["state_directory"]
            .as_str()
            .filter(|value| !value.is_empty())
        {
            // Never interpret an endpoint's arbitrary filesystem path as permission
            // to recursively delete it. Unknown legacy paths require manual review.
            if Path::new(directory) != owned {
                return Err("tailscale.custom_state");
            }
        }
    }
    safe_path(app, Path::new(STATE))?;
    match fs::symlink_metadata(&owned) {
        Ok(metadata) if !metadata.is_dir() => return Err("tailscale.unsafe_path"),
        Ok(_) => fs::remove_dir_all(&owned).map_err(|_| "tailscale.cleanup_failed")?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("tailscale.cleanup_failed"),
    }
    Ok(())
}

pub(crate) fn command(app: &App, args: &[String]) -> std::result::Result<(), String> {
    let action = args.first().map(String::as_str).unwrap_or("status");
    if action == "status" && args.len() <= 1 {
        let data = status(app).map_err(str::to_string)?;
        println!(
            "enabled={} resumable={} core={}",
            data["enabled"], data["resumable"], data["core"]
        );
        return Ok(());
    }
    if !matches!(action, "enable" | "disable" | "logout")
        || args.len() != 2
        || args[1].len() != 64
        || !args[1].bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(
            "Usage: cli tailscale {status|enable <revision>|disable <revision>|logout <revision>}"
                .into(),
        );
    }
    apply(app, action, &args[1]).map_err(str::to_string)
}

trait Runtime {
    fn validate(&mut self, app: &App, config: &Value) -> Result<()>;
    fn running(&mut self, app: &App) -> Result<bool>;
    fn stop(&mut self, app: &App) -> Result<()>;
    fn start(&mut self, app: &App) -> Result<()>;
}

#[derive(Default)]
struct NativeRuntime {
    source: Option<crate::subscriptions::SubscriptionSourceGuard>,
}
impl Runtime for NativeRuntime {
    fn validate(&mut self, app: &App, config: &Value) -> Result<()> {
        self.source = Some(
            crate::subscriptions::SubscriptionSourceGuard::acquire(app)
                .map_err(|_| "tailscale.busy")?,
        );
        if app
            .moddir
            .join(".state/sing-box/subscription-transaction")
            .exists()
        {
            return Err("tailscale.busy");
        }
        crate::config_editor::validate_override_text(app, &config.to_string())
            .map_err(|_| "tailscale.validation_failed")
    }
    fn running(&mut self, app: &App) -> Result<bool> {
        owned_singbox_pids(app)
            .map(|pids| !pids.is_empty())
            .map_err(|_| "tailscale.runtime_unknown")
    }
    fn stop(&mut self, app: &App) -> Result<()> {
        crate::service::stop_all_direct(app, false).map_err(|_| "tailscale.stop_failed")
    }
    fn start(&mut self, app: &App) -> Result<()> {
        crate::service::start_after_tailscale_change(app).map_err(|_| "tailscale.restart_failed")
    }
}

fn apply(app: &App, action: &str, expected: &str) -> Result<()> {
    apply_with(app, action, expected, &mut NativeRuntime::default())
}

fn apply_with(app: &App, action: &str, expected: &str, runtime: &mut impl Runtime) -> Result<()> {
    let _guard = crate::service::config_apply_lock(app).map_err(|_| "tailscale.busy")?;
    let original = Settings::read(app)?;
    if original.revision() != expected {
        return Err("tailscale.conflict");
    }
    if action == "logout"
        && tailnets(&original.config)?.is_empty()
        && tailnets(&original.paused)?.is_empty()
        && original
            .auth
            .as_object()
            .is_some_and(|keys| keys.is_empty())
        && original.paused["phase"] == "idle"
        && !has_local_state(app)?
    {
        return Ok(());
    }
    let mut next = plan(&original, action)?;
    if action != "logout" && next.revision() == original.revision() {
        return Ok(());
    }
    runtime.validate(app, &next.config)?;
    // The editor/subscription producer can change the source during validation.
    if Settings::read(app)?.revision() != expected {
        return Err("tailscale.conflict");
    }
    let running = runtime.running(app)?;
    // This stops owned supervisors and restores both TUN/eBPF interception before
    // taking down the old process. Unknown process state never authorizes deletion.
    runtime.stop(app)?;
    if runtime.running(app)? {
        return Err("tailscale.stop_failed");
    }
    if !Settings::read(app).is_ok_and(|observed| observed.revision() == expected) {
        if running {
            let _ = runtime.start(app);
        }
        return Err("tailscale.conflict");
    }
    if let Err(error) = next.persist(app) {
        if running {
            let _ = runtime.start(app);
        }
        return Err(error);
    }
    let cleanup = if action == "logout" {
        // Persist disabled/no-key intent FIRST: interruption cannot auto-login.
        forget_identity(app, &next.paused).and_then(|()| {
            next.paused = json!({"schema":1,"phase":"idle","endpoints":[]});
            next.persist(app)
        })
    } else {
        Ok(())
    };
    if running && runtime.start(app).is_err() {
        // Enable failure returns to the known disabled configuration. Never
        // rollback a logout or disable into an unwanted connected identity.
        if action == "enable" {
            runtime.stop(app)?;
            original.persist(app)?;
            let _ = runtime.start(app);
        }
        return Err("tailscale.restart_failed");
    }
    cleanup
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::temp_app;

    fn settings() -> Settings {
        Settings {
            config: json!({"endpoints":[{"type":"tailscale","tag":"mesh","hostname":"phone","system_interface":false}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","rules":[{"domain_suffix":["example.com"],"outbound":"direct"},{"domain_suffix":["ts.net"],"action":"route","outbound":"mesh"},{"ip_cidr":["100.64.0.0/10","fd7a:115c:a1e0::/48"],"preferred_by":["mesh"],"action":"route","outbound":"mesh"}]},"dns":{"servers":[{"type":"tailscale","tag":"mesh-dns","endpoint":"mesh"}],"rules":[{"domain_suffix":["ts.net"],"server":"mesh-dns"}]}}),
            paused: json!({"schema":1,"phase":"idle","endpoints":[]}),
            auth: json!({"mesh":"fixture-value"}),
        }
    }

    #[derive(Default)]
    struct FakeRuntime {
        running: bool,
        stop_fails: bool,
        unknown: bool,
        start_failures: usize,
        starts: usize,
        stops: usize,
    }
    impl Runtime for FakeRuntime {
        fn validate(&mut self, _: &App, _: &Value) -> Result<()> {
            Ok(())
        }
        fn running(&mut self, _: &App) -> Result<bool> {
            if self.unknown {
                Err("tailscale.runtime_unknown")
            } else {
                Ok(self.running)
            }
        }
        fn stop(&mut self, _: &App) -> Result<()> {
            self.stops += 1;
            if self.stop_fails {
                return Err("tailscale.stop_failed");
            }
            self.running = false;
            Ok(())
        }
        fn start(&mut self, _: &App) -> Result<()> {
            self.starts += 1;
            if self.start_failures > 0 {
                self.start_failures -= 1;
                return Err("tailscale.restart_failed");
            }
            self.running = true;
            Ok(())
        }
    }

    #[test]
    fn repeated_disable_does_not_restart_and_stopped_core_stays_stopped() {
        let app = temp_app();
        let before = settings();
        before.persist(&app).unwrap();
        let mut runtime = FakeRuntime::default();
        apply_with(&app, "disable", &before.revision(), &mut runtime).unwrap();
        let disabled = Settings::read(&app).unwrap();
        apply_with(&app, "disable", &disabled.revision(), &mut runtime).unwrap();
        assert_eq!((runtime.starts, runtime.stops), (0, 1));
        apply_with(&app, "enable", &disabled.revision(), &mut runtime).unwrap();
        assert_eq!(runtime.starts, 0);
        assert!(!tailnets(&Settings::read(&app).unwrap().config)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn logout_from_enabled_paused_or_legacy_residue_forgets_local_identity() {
        for initial in ["enabled", "paused", "legacy"] {
            let app = temp_app();
            let mut before = settings();
            if initial != "enabled" {
                before = plan(&before, "disable").unwrap();
            }
            if initial == "legacy" {
                before.paused["endpoints"] = json!([]);
            }
            before.persist(&app).unwrap();
            fs::create_dir_all(app.moddir.join(STATE)).unwrap();
            fs::write(app.moddir.join(STATE).join("identity"), "private-fixture").unwrap();
            let mut runtime = FakeRuntime {
                running: true,
                ..Default::default()
            };
            apply_with(&app, "logout", &before.revision(), &mut runtime).unwrap();
            let after = Settings::read(&app).unwrap();
            assert!(tailnets(&after.config).unwrap().is_empty());
            assert!(tailnets(&after.paused).unwrap().is_empty());
            assert_eq!(after.auth, json!({}));
            assert!(!has_local_state(&app).unwrap());
            apply_with(&app, "logout", &after.revision(), &mut runtime).unwrap();
            assert_eq!((runtime.starts, runtime.stops), (1, 1));
        }
    }

    #[test]
    fn stop_failure_and_unknown_runtime_never_delete_identity_or_config() {
        for unknown in [false, true] {
            let app = temp_app();
            let before = settings();
            before.persist(&app).unwrap();
            fs::create_dir_all(app.moddir.join(STATE)).unwrap();
            fs::write(app.moddir.join(STATE).join("identity"), "private-fixture").unwrap();
            let mut runtime = FakeRuntime {
                running: true,
                stop_fails: true,
                unknown,
                ..Default::default()
            };
            assert!(apply_with(&app, "logout", &before.revision(), &mut runtime).is_err());
            assert_eq!(Settings::read(&app).unwrap().revision(), before.revision());
            assert!(has_local_state(&app).unwrap());
            assert_eq!(runtime.starts, 0);
        }
    }

    #[test]
    fn enable_restart_failure_rolls_back_but_disable_failure_never_reconnects() {
        for action in ["enable", "disable"] {
            let app = temp_app();
            let before = if action == "enable" {
                plan(&settings(), "disable").unwrap()
            } else {
                settings()
            };
            before.persist(&app).unwrap();
            let mut runtime = FakeRuntime {
                running: true,
                start_failures: 1,
                ..Default::default()
            };
            assert_eq!(
                apply_with(&app, action, &before.revision(), &mut runtime),
                Err("tailscale.restart_failed")
            );
            let after = Settings::read(&app).unwrap();
            assert!(tailnets(&after.config).unwrap().is_empty());
            assert!(!tailnets(&after.paused).unwrap().is_empty());
            if action == "enable" {
                assert_eq!(after.revision(), before.revision());
                assert_eq!(runtime.starts, 2);
            } else {
                assert_eq!(runtime.starts, 1);
            }
        }
    }

    #[test]
    fn incomplete_logout_persists_disabled_intent_and_cannot_resume() {
        let app = temp_app();
        let mut before = settings();
        before.config["endpoints"][0]["state_directory"] = json!("/not-owned");
        before.persist(&app).unwrap();
        let mut runtime = FakeRuntime {
            running: true,
            ..Default::default()
        };
        assert_eq!(
            apply_with(&app, "logout", &before.revision(), &mut runtime),
            Err("tailscale.custom_state")
        );
        let after = Settings::read(&app).unwrap();
        assert_eq!(after.auth, json!({}));
        assert!(tailnets(&after.config).unwrap().is_empty());
        assert_eq!(
            apply_with(&app, "enable", &after.revision(), &mut runtime),
            Err("tailscale.logout_pending")
        );
        assert_eq!(runtime.starts, 1);
    }

    #[test]
    fn disable_preserves_identity_and_removes_current_owned_routes() {
        let before = settings();
        let disabled = plan(&before, "disable").unwrap();
        assert!(tailnets(&disabled.config).unwrap().is_empty());
        assert_eq!(disabled.auth, before.auth);
        assert_eq!(
            disabled.config["route"]["rules"].as_array().unwrap().len(),
            1
        );
        assert_eq!(disabled.config["dns"]["servers"], json!([]));
        assert_eq!(disabled.config["dns"]["rules"], json!([]));
        assert_eq!(
            plan(&disabled, "disable").unwrap().revision(),
            disabled.revision()
        );
        let enabled = plan(&disabled, "enable").unwrap();
        assert_eq!(enabled.config["endpoints"], before.config["endpoints"]);
        assert_eq!(enabled.auth, before.auth);
        assert_eq!(
            plan(&enabled, "enable").unwrap().revision(),
            enabled.revision()
        );
    }

    #[test]
    fn logout_removes_key_and_blocks_resume_until_cleanup_finishes() {
        let pending = plan(&settings(), "logout").unwrap();
        assert_eq!(pending.auth, json!({}));
        assert!(tailnets(&pending.config).unwrap().is_empty());
        assert!(matches!(
            plan(&pending, "enable"),
            Err("tailscale.logout_pending")
        ));
    }

    #[test]
    fn custom_references_are_not_discarded_or_redirected() {
        for rule in [
            json!({"domain_suffix":["private.example"],"outbound":"mesh"}),
            json!({"outbound":"direct","preferred_by":["mesh"]}),
        ] {
            let mut data = settings();
            data.config["route"]["rules"]
                .as_array_mut()
                .unwrap()
                .push(rule);
            assert!(matches!(
                plan(&data, "disable"),
                Err("tailscale.custom_references")
            ));
        }
    }

    #[test]
    fn resume_refuses_tag_reuse_and_pause_protects_inline_keys() {
        let mut data = settings();
        data.config["endpoints"][0]["auth_key"] = json!("private-fixture");
        let mut disabled = plan(&data, "disable").unwrap();
        assert!(disabled.paused["endpoints"][0].get("auth_key").is_none());
        assert_eq!(disabled.auth["mesh"], "private-fixture");
        disabled.config["outbounds"]
            .as_array_mut()
            .unwrap()
            .push(json!({"type":"direct","tag":"mesh"}));
        assert!(matches!(
            plan(&disabled, "enable"),
            Err("tailscale.tag_conflict")
        ));
    }

    #[test]
    fn identity_cleanup_is_idempotent_and_never_follows_a_symlink() {
        use std::os::unix::fs::symlink;
        let app = temp_app();
        let paused = json!({"endpoints":[]});
        fs::create_dir_all(app.moddir.join(STATE)).unwrap();
        fs::write(app.moddir.join(STATE).join("state"), "fixture").unwrap();
        forget_identity(&app, &paused).unwrap();
        forget_identity(&app, &paused).unwrap();
        let outside = app.moddir.join("unrelated");
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("keep"), "untouched").unwrap();
        symlink(&outside, app.moddir.join(STATE)).unwrap();
        assert_eq!(forget_identity(&app, &paused), Err("tailscale.unsafe_path"));
        assert_eq!(
            fs::read_to_string(outside.join("keep")).unwrap(),
            "untouched"
        );
    }

    #[test]
    fn custom_state_path_is_never_recursively_deleted() {
        let app = temp_app();
        assert_eq!(
            forget_identity(
                &app,
                &json!({"endpoints":[{"type":"tailscale","tag":"mesh","state_directory":"/some/other/app"}]})
            ),
            Err("tailscale.custom_state")
        );
    }

    #[test]
    fn status_is_read_only_on_a_fresh_module() {
        let app = temp_app();
        let observed = status(&app).unwrap();
        assert_eq!(observed["enabled"], false);
        assert_eq!(observed["resumable"], false);
        assert!(fs::read_dir(&app.moddir).unwrap().next().is_none());
    }

    #[test]
    fn revisions_cover_concurrent_edits_and_persistence_roundtrips() {
        let app = temp_app();
        let data = settings();
        data.persist(&app).unwrap();
        assert_eq!(Settings::read(&app).unwrap().revision(), data.revision());
        let mut changed = data.clone();
        changed.config["log"] = json!({"level":"error"});
        assert_ne!(changed.revision(), data.revision());
        assert_eq!(
            apply(&app, "disable", &"0".repeat(64)),
            Err("tailscale.conflict")
        );
    }
}
