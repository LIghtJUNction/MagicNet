mod mihomo;
#[cfg(test)]
mod mihomo_tests;
mod singbox;
#[cfg(test)]
mod singbox_tests;

use crate::{read_kv, run_magicnet_function, write_kv, App};
use mihomo::apply_mihomo;
use singbox::apply_singbox;

const CONF_REL: &str = ".config/magicnet/tailscale.conf";
pub(crate) const TS_TAG: &str = "MagicNet-Tailscale";
pub(crate) const TS_ENDPOINT: &str = "magicnet-ts";
pub(crate) const TS_DNS: &str = "magicnet-ts-dns";

#[derive(Default)]
pub(crate) struct TailscaleConfig {
    pub(crate) enabled: bool,
    pub(crate) auth_key: String,
    pub(crate) hostname: String,
    pub(crate) state_dir: String,
    pub(crate) accept_routes: bool,
    pub(crate) subnets: Vec<String>,
}

pub(crate) fn tailscale_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            print_status(app);
            Ok(())
        }
        "disable" => {
            let mut cfg = read_config(app);
            cfg.enabled = false;
            write_config(app, &cfg)?;
            apply_tailscale(app)?;
            println!("[info] Tailscale shortcut disabled");
            Ok(())
        }
        "set" => set_config(app, args),
        "apply" => apply_tailscale(app),
        _ => Err("Usage: cli tailscale {status|set <auth-key|-keep> [hostname] [subnets_csv]|disable|apply}".to_string()),
    }
}

fn set_config(app: &App, args: &[String]) -> Result<(), String> {
    let auth = args.get(1).map(String::as_str).unwrap_or_default();
    if auth.is_empty() {
        return Err(
            "Usage: cli tailscale set <auth-key|-keep> [hostname] [subnets_csv]".to_string(),
        );
    }
    let mut cfg = read_config(app);
    cfg.enabled = true;
    if auth != "-keep" {
        cfg.auth_key = auth.to_string();
    }
    if let Some(hostname) = args.get(2).filter(|value| !value.trim().is_empty()) {
        cfg.hostname = hostname.trim().to_string();
    }
    if let Some(subnets) = args.get(3) {
        cfg.subnets = subnets
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .collect();
    }
    if cfg.hostname.is_empty() {
        cfg.hostname = "android-magicnet".to_string();
    }
    if cfg.state_dir.is_empty() {
        cfg.state_dir = app
            .moddir
            .join(".config/tailscale")
            .to_string_lossy()
            .to_string();
    }
    write_config(app, &cfg)?;
    apply_tailscale(app)?;
    println!("[info] Tailscale shortcut saved");
    Ok(())
}

fn print_status(app: &App) {
    let cfg = read_config(app);
    println!("enabled={}", cfg.enabled as u8);
    println!("auth_key_set={}", (!cfg.auth_key.is_empty()) as u8);
    println!("hostname={}", cfg.hostname);
    println!("state_dir={}", cfg.state_dir);
    println!("accept_routes={}", cfg.accept_routes as u8);
    println!("subnets={}", cfg.subnets.join(","));
}

fn read_config(app: &App) -> TailscaleConfig {
    let path = app.moddir.join(CONF_REL);
    let kv = read_kv(path);
    TailscaleConfig {
        enabled: kv
            .get("MAGICNET_TAILSCALE_ENABLED")
            .is_some_and(|v| v == "1"),
        auth_key: kv
            .get("MAGICNET_TAILSCALE_AUTH_KEY")
            .cloned()
            .unwrap_or_default(),
        hostname: kv
            .get("MAGICNET_TAILSCALE_HOSTNAME")
            .cloned()
            .unwrap_or_else(|| "android-magicnet".to_string()),
        state_dir: kv
            .get("MAGICNET_TAILSCALE_STATE_DIR")
            .cloned()
            .unwrap_or_else(|| {
                app.moddir
                    .join(".config/tailscale")
                    .to_string_lossy()
                    .to_string()
            }),
        accept_routes: kv
            .get("MAGICNET_TAILSCALE_ACCEPT_ROUTES")
            .map(|v| v != "0")
            .unwrap_or(true),
        subnets: kv
            .get("MAGICNET_TAILSCALE_SUBNETS")
            .map(|v| {
                v.split(',')
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToOwned::to_owned)
                    .collect()
            })
            .unwrap_or_else(|| vec!["100.64.0.0/10".to_string()]),
    }
}

fn write_config(app: &App, cfg: &TailscaleConfig) -> Result<(), String> {
    write_kv(
        app.moddir.join(CONF_REL),
        &[
            (
                "MAGICNET_TAILSCALE_ENABLED",
                (cfg.enabled as u8).to_string(),
            ),
            ("MAGICNET_TAILSCALE_AUTH_KEY", cfg.auth_key.clone()),
            ("MAGICNET_TAILSCALE_HOSTNAME", cfg.hostname.clone()),
            ("MAGICNET_TAILSCALE_STATE_DIR", cfg.state_dir.clone()),
            (
                "MAGICNET_TAILSCALE_ACCEPT_ROUTES",
                (cfg.accept_routes as u8).to_string(),
            ),
            ("MAGICNET_TAILSCALE_SUBNETS", cfg.subnets.join(",")),
        ],
    )
}

fn apply_tailscale(app: &App) -> Result<(), String> {
    let cfg = read_config(app);
    apply_singbox(app, &cfg)?;
    apply_mihomo(app, &cfg)?;
    run_magicnet_function(app, "magicnet_apply_runtime_config")?;
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
    fn read_config_uses_safe_defaults_without_leaking_auth_key() {
        let app = temp_app();

        let cfg = read_config(&app);

        assert!(!cfg.enabled);
        assert!(cfg.auth_key.is_empty());
        assert_eq!(cfg.hostname, "android-magicnet");
        assert!(cfg.state_dir.ends_with(".config/tailscale"));
        assert!(cfg.accept_routes);
        assert_eq!(cfg.subnets, vec!["100.64.0.0/10"]);
    }

    #[test]
    fn write_config_persists_all_tailscale_fields() {
        let app = temp_app();
        let cfg = TailscaleConfig {
            enabled: true,
            auth_key: "tskey-secret".to_string(),
            hostname: "phone".to_string(),
            state_dir: "/tmp/ts-state".to_string(),
            accept_routes: false,
            subnets: vec!["100.64.0.0/10".to_string(), "192.168.7.0/24".to_string()],
        };

        write_config(&app, &cfg).unwrap();
        let loaded = read_config(&app);

        assert!(loaded.enabled);
        assert_eq!(loaded.auth_key, "tskey-secret");
        assert_eq!(loaded.hostname, "phone");
        assert_eq!(loaded.state_dir, "/tmp/ts-state");
        assert!(!loaded.accept_routes);
        assert_eq!(loaded.subnets, cfg.subnets);
    }

    #[test]
    fn read_config_trims_empty_subnets_and_keeps_existing_auth_key() {
        let app = temp_app();
        let path = app.moddir.join(CONF_REL);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            path,
            "MAGICNET_TAILSCALE_ENABLED=1\n\
             MAGICNET_TAILSCALE_AUTH_KEY='tskey-kept'\n\
             MAGICNET_TAILSCALE_HOSTNAME=phone\n\
             MAGICNET_TAILSCALE_STATE_DIR=/state\n\
             MAGICNET_TAILSCALE_ACCEPT_ROUTES=0\n\
             MAGICNET_TAILSCALE_SUBNETS=100.64.0.0/10, ,192.168.7.0/24\n",
        )
        .unwrap();

        let loaded = read_config(&app);

        assert!(loaded.enabled);
        assert_eq!(loaded.auth_key, "tskey-kept");
        assert!(!loaded.accept_routes);
        assert_eq!(
            loaded.subnets,
            vec!["100.64.0.0/10".to_string(), "192.168.7.0/24".to_string()]
        );
    }
}
