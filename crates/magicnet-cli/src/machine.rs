use std::fs;

use serde_json::{json, Value};

use crate::{
    diagnostics::supervisor_pid, read_kv, service::singbox_webui, singbox_pid_summary, App,
};

const MACHINE_SCHEMA: u64 = 1;
const SELECTED_CORE_CONF: &str = ".config/magicnet/current-core.conf";
const TRANSPARENT_MODE_CONF: &str = ".config/magicnet/transparent-mode.conf";

pub(crate) fn dispatch(app: &App, args: &[String]) -> Option<Result<(), String>> {
    let is_service_status_json = matches!(
        args,
        [command, action, flag]
            if command == "service" && action == "status" && flag == "--json"
    ) || matches!(
        args,
        [flag, command, action]
            if flag == "--json" && command == "service" && action == "status"
    );

    is_service_status_json.then(|| print_service_status(app))
}

fn print_service_status(app: &App) -> Result<(), String> {
    let value = service_status_value(app);
    let encoded = serde_json::to_string(&value)
        .map_err(|err| format!("serialize service status: {err}"))?;
    println!("{encoded}");
    Ok(())
}

fn service_status_value(app: &App) -> Value {
    let singbox = singbox_pid_summary(app);
    let running = singbox != "stopped";
    let rss_kib = singbox_rss_kib(&singbox);
    let selected = config_value(
        app,
        SELECTED_CORE_CONF,
        "MAGICNET_DEFAULT_CORE",
        "sing-box",
        &["sing-box"],
    );
    let transparent = config_value(
        app,
        TRANSPARENT_MODE_CONF,
        "MAGICNET_TRANSPARENT_MODE",
        "tun",
        &["tun", "ebpf"],
    );
    let subscription_source = if app
        .moddir
        .join(".config/sing-box/subscription.local")
        .metadata()
        .map(|metadata| metadata.len() > 0)
        .unwrap_or(false)
    {
        "local_file"
    } else {
        "remote_url"
    };

    json!({
        "schema": MACHINE_SCHEMA,
        "ok": true,
        "command": "service.status",
        "data": {
            "core": {
                "selected": selected,
                "sing_box": {
                    "running": running,
                    "pid_summary": singbox,
                    "rss_kib": rss_kib,
                }
            },
            "supervisors": {
                "fswatch": supervisor_pid(app, "fswatch", "magicnet-config"),
                "wifi_policy": supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy"),
            },
            "transparent": {
                "mode": transparent,
            },
            "api": {
                "url": app.api,
                "webui": singbox_webui(app),
            },
            "subscription": {
                "source": subscription_source,
            }
        }
    })
}

fn config_value(
    app: &App,
    relative_path: &str,
    key: &str,
    default: &str,
    allowed: &[&str],
) -> String {
    let value = read_kv(app.moddir.join(relative_path))
        .remove(key)
        .unwrap_or_else(|| default.to_string());
    if allowed.contains(&value.as_str()) {
        value
    } else {
        "invalid".to_string()
    }
}

fn singbox_rss_kib(summary: &str) -> Option<u64> {
    summary.split(',').try_fold(0u64, |total, pid| {
        let pid = pid.parse::<u32>().ok()?;
        let status = fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
        total.checked_add(parse_rss_kib(&status)?)
    })
}

fn parse_rss_kib(status: &str) -> Option<u64> {
    let mut fields = status
        .lines()
        .find_map(|line| line.strip_prefix("VmRSS:"))?
        .split_whitespace();
    let value = fields.next()?.parse().ok()?;
    (fields.next()? == "kB").then_some(value)
}

#[cfg(test)]
mod tests {
    use super::{parse_rss_kib, service_status_value};
    use crate::App;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture() -> (std::path::PathBuf, App) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "magicnet-machine-status-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(root.join(".config/magicnet")).expect("create magicnet config");
        fs::create_dir_all(root.join(".config/sing-box")).expect("create sing-box config");
        let app = App::for_test(root.clone());
        (root, app)
    }

    #[test]
    fn service_status_machine_contract_is_versioned_and_does_not_expose_subscription_url() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/current-core.conf"),
            "MAGICNET_DEFAULT_CORE=sing-box\n",
        )
        .expect("write core config");
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=ebpf\n",
        )
        .expect("write transparent config");
        fs::write(
            root.join(".config/sing-box/subscription.url"),
            "https://user:secret@example.invalid/sub\n",
        )
        .expect("write subscription url");

        let value = service_status_value(&app);
        assert_eq!(value["schema"], 1);
        assert_eq!(value["ok"], true);
        assert_eq!(value["command"], "service.status");
        assert_eq!(value["data"]["core"]["selected"], "sing-box");
        assert_eq!(value["data"]["transparent"]["mode"], "ebpf");
        assert_eq!(
            value["data"]["subscription"]["source"],
            "remote_url"
        );
        assert!(!value.to_string().contains("example.invalid"));
        assert!(!value.to_string().contains("secret"));

        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn local_subscription_source_wins_and_invalid_modes_are_explicit() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=redirect\n",
        )
        .expect("write invalid transparent config");
        fs::write(
            root.join(".config/sing-box/subscription.local"),
            "proxies: []\n",
        )
        .expect("write local subscription");

        let value = service_status_value(&app);
        assert_eq!(value["data"]["transparent"]["mode"], "invalid");
        assert_eq!(value["data"]["subscription"]["source"], "local_file");

        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn parses_proc_rss_kib() {
        assert_eq!(parse_rss_kib("Name:\ttest\nVmRSS:\t2048 kB\n"), Some(2048));
        assert_eq!(parse_rss_kib("VmRSS:\t2 MB\n"), None);
    }
}
