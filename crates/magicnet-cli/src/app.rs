use std::env;
use std::fs;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};

use serde_json::Value;

const MODULE_DIR: &str = "/data/adb/modules/MagicNet";
const DEFAULT_API: &str = "http://127.0.0.1:9090";
const SINGBOX_CONFIG: &str = ".config/sing-box/config.json";

#[derive(Clone)]
pub(crate) struct App {
    pub(crate) moddir: PathBuf,
    pub(crate) api: String,
    pub(crate) log_dir: PathBuf,
}

impl App {
    pub(crate) fn from_env() -> Self {
        let moddir = if cfg!(target_os = "android") {
            // On the device the module directory is a privileged code/data
            // boundary. Do not allow a caller-provided MODDIR to redirect
            // root shell execution to an arbitrary writable directory.
            current_exe_moddir().unwrap_or_else(|_| PathBuf::from(MODULE_DIR))
        } else {
            // Host-side fixture tests intentionally provide their own module
            // root while invoking the workspace binary.
            env::var("MODDIR")
                .map(PathBuf::from)
                .or_else(|_| current_exe_moddir())
                .unwrap_or_else(|_| PathBuf::from(MODULE_DIR))
        };
        let api = local_api(&moddir);
        Self {
            log_dir: moddir.join(".log"),
            moddir,
            api,
        }
    }

    #[cfg(test)]
    pub(crate) fn for_test(moddir: PathBuf) -> Self {
        let api = DEFAULT_API.to_string();
        Self {
            log_dir: moddir.join(".log"),
            moddir,
            api,
        }
    }
}

fn local_api(moddir: &Path) -> String {
    env::var("MAGICNET_API")
        .ok()
        .map(|value| value.trim_end_matches('/').to_string())
        .filter(|value| is_loopback_http_api(value))
        .or_else(|| local_api_from_config(moddir))
        .unwrap_or_else(|| DEFAULT_API.to_string())
}

fn local_api_from_config(moddir: &Path) -> Option<String> {
    let config = fs::read(moddir.join(SINGBOX_CONFIG)).ok()?;
    let config: Value = serde_json::from_slice(&config).ok()?;
    let controller = config
        .pointer("/experimental/clash_api/external_controller")?
        .as_str()?;
    api_from_controller(controller)
}

fn api_from_controller(value: &str) -> Option<String> {
    let address = value.trim().parse::<SocketAddr>().ok()?;
    if address.port() == 0 {
        return None;
    }

    // A wildcard controller is still reached locally through loopback. Keep
    // root-side CLI traffic local instead of trying to request 0.0.0.0/::.
    let ip = if address.ip().is_loopback() {
        address.ip()
    } else if address.ip().is_unspecified() {
        match address.ip() {
            IpAddr::V4(_) => IpAddr::V4(Ipv4Addr::LOCALHOST),
            IpAddr::V6(_) => IpAddr::V6(Ipv6Addr::LOCALHOST),
        }
    } else {
        return None;
    };

    Some(match ip {
        IpAddr::V4(ip) => format!("http://{ip}:{}", address.port()),
        IpAddr::V6(ip) => format!("http://[{ip}]:{}", address.port()),
    })
}

fn is_loopback_http_api(value: &str) -> bool {
    let Some(authority) = value.strip_prefix("http://") else {
        return false;
    };
    if authority.is_empty()
        || authority
            .bytes()
            .any(|byte| matches!(byte, b'/' | b'?' | b'#' | b'@'))
        || authority.chars().any(char::is_whitespace)
    {
        return false;
    }
    authority
        .parse::<SocketAddr>()
        .ok()
        .is_some_and(|address| address.ip().is_loopback() && address.port() != 0)
}

fn current_exe_moddir() -> io::Result<PathBuf> {
    let exe = env::current_exe()?;
    Ok(infer_moddir_from_exe(&exe).unwrap_or_else(|| PathBuf::from(MODULE_DIR)))
}

fn infer_moddir_from_exe(exe: &Path) -> Option<PathBuf> {
    for candidate in exe.ancestors().skip(1) {
        if candidate.join("module.prop").is_file() && candidate.join("lib/kamfw/.kamfwrc").is_file()
        {
            return Some(candidate.to_path_buf());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{
        api_from_controller, infer_moddir_from_exe, is_loopback_http_api, local_api_from_config,
    };
    use std::env;
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture_root() -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos();
        let root = env::temp_dir().join(format!(
            "magicnet-cli-path-test-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(root.join("module/lib/kamfw")).expect("create kamfw dir");
        fs::create_dir_all(root.join("module/bin")).expect("create bin dir");
        fs::write(root.join("module/module.prop"), "id=MagicNet\n").expect("write module.prop");
        fs::write(root.join("module/lib/kamfw/.kamfwrc"), "").expect("write .kamfwrc");
        root
    }

    fn assert_infers(root: &Path, exe_rel: &str) {
        let module = root.join("module");
        assert_eq!(infer_moddir_from_exe(&module.join(exe_rel)), Some(module));
    }

    #[test]
    fn infers_module_root_from_cli_entry_locations() {
        let root = fixture_root();
        assert_infers(&root, "cli");
        assert_infers(&root, "bin/magicnet-cli");
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn api_override_is_loopback_http_only() {
        assert!(is_loopback_http_api("http://127.0.0.1:9090"));
        assert!(is_loopback_http_api("http://[::1]:19090"));
        assert!(!is_loopback_http_api("https://127.0.0.1:9090"));
        assert!(!is_loopback_http_api("http://localhost:9090"));
        assert!(!is_loopback_http_api("http://127.0.0.1:9090@evil.example"));
        assert!(!is_loopback_http_api("http://127.0.0.1:0"));
    }

    #[test]
    fn controller_address_keeps_configured_port() {
        assert_eq!(
            api_from_controller("127.0.0.1:19090").as_deref(),
            Some("http://127.0.0.1:19090")
        );
        assert_eq!(
            api_from_controller("[::1]:29090").as_deref(),
            Some("http://[::1]:29090")
        );
    }

    #[test]
    fn wildcard_controller_uses_local_loopback_with_same_port() {
        assert_eq!(
            api_from_controller("0.0.0.0:19090").as_deref(),
            Some("http://127.0.0.1:19090")
        );
        assert_eq!(
            api_from_controller("[::]:29090").as_deref(),
            Some("http://[::1]:29090")
        );
    }

    #[test]
    fn remote_controller_is_not_used_by_root_cli() {
        assert_eq!(api_from_controller("192.0.2.10:19090"), None);
    }

    #[test]
    fn reads_controller_from_singbox_config() {
        let root = fixture_root();
        let module = root.join("module");
        fs::create_dir_all(module.join(".config/sing-box")).expect("create sing-box config dir");
        fs::write(
            module.join(".config/sing-box/config.json"),
            r#"{"experimental":{"clash_api":{"external_controller":"127.0.0.1:19090"}}}"#,
        )
        .expect("write sing-box config");
        assert_eq!(
            local_api_from_config(&module).as_deref(),
            Some("http://127.0.0.1:19090")
        );
        fs::remove_dir_all(root).expect("remove fixture");
    }
}
