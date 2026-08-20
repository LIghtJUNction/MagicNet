use std::env;
use std::io;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

const MODULE_DIR: &str = "/data/adb/modules/MagicNet";
const DEFAULT_API: &str = "http://127.0.0.1:9090";

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
        let api = local_api_from_env();
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

fn local_api_from_env() -> String {
    env::var("MAGICNET_API")
        .ok()
        .map(|value| value.trim_end_matches('/').to_string())
        .filter(|value| is_loopback_http_api(value))
        .unwrap_or_else(|| DEFAULT_API.to_string())
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
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let Some((host, port)) = rest.split_once("]:") else {
            return false;
        };
        (host, port)
    } else {
        let Some((host, port)) = authority.rsplit_once(':') else {
            return false;
        };
        if host.contains(':') {
            return false;
        }
        (host, port)
    };
    let Ok(address) = host.parse::<IpAddr>() else {
        return false;
    };
    address.is_loopback() && port.parse::<u16>().ok().is_some_and(|port| port != 0)
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
    use super::{infer_moddir_from_exe, is_loopback_http_api};
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
}
