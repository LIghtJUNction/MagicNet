mod base64;
#[cfg(test)]
mod base64_tests;
mod config_editor;
mod diagnostics;
mod mcp;
mod nodes;
mod ping;
mod rules;
mod service;
mod subscriptions;
mod tailscale;
mod utils;
mod webui_api;

use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

pub(crate) use base64::{decode_base64, encode_base64};
use config_editor::config_editor;
use diagnostics::{health, support, sysroute, topology};
use mcp::mcp;
use nodes::node_list;
use ping::pingtest;
use rules::{app_cmd, block_cmd, capture_cmd, cert_cmd, route_cmd};
use service::{
    config_cmd, core_cmd, hotspot_cmd, repair, service_cmd, service_logs, service_status,
    supervisor_cmd, transparent_cmd, vpn_cmd, watchdog_cmd,
};
use subscriptions::{
    setup_subscription, sub_get, sub_list, sub_set, sub_set_file, sub_target_file, sub_update,
    sub_update_all,
};
use tailscale::tailscale_cmd;
pub(crate) use utils::{
    clean_lines, clear_node_cache, command_text_timeout, first_clean_line, read_kv, write_kv,
    write_text_file,
};
use webui_api::{api_cmd, backup_cmd, webui_cmd};

const SHORT_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Clone)]
pub(crate) struct App {
    pub(crate) moddir: PathBuf,
    api: String,
    mihomo_webui: String,
    singbox_webui: String,
    log_dir: PathBuf,
}

fn main() {
    let app = App::from_env();
    let args: Vec<String> = env::args().skip(1).collect();
    let code = match dispatch(&app, &args) {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("[error] {err}");
            1
        }
    };
    std::process::exit(code);
}

impl App {
    fn from_env() -> Self {
        let moddir = env::var("MODDIR")
            .map(PathBuf::from)
            .or_else(|_| current_exe_moddir())
            .unwrap_or_else(|_| PathBuf::from("/data/adb/modules/MagicNet"));
        let api = env::var("MAGICNET_API").unwrap_or_else(|_| "http://127.0.0.1:9090".to_string());
        let mihomo_webui = env::var("MAGICNET_MIHOMO_WEBUI").unwrap_or_else(|_| {
            "https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=9090&secret="
                .to_string()
        });
        let singbox_webui = env::var("MAGICNET_SINGBOX_WEBUI")
            .unwrap_or_else(|_| format!("{api}/ui/#/setup?hostname=127.0.0.1&port=9090"));
        Self {
            log_dir: moddir.join(".log"),
            moddir,
            api,
            mihomo_webui,
            singbox_webui,
        }
    }

    #[cfg(test)]
    pub(crate) fn for_test(moddir: PathBuf) -> Self {
        let api = "http://127.0.0.1:9090".to_string();
        Self {
            log_dir: moddir.join(".log"),
            moddir,
            mihomo_webui:
                "https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=9090&secret="
                    .to_string(),
            singbox_webui: format!("{api}/ui/#/setup?hostname=127.0.0.1&port=9090"),
            api,
        }
    }
}

fn current_exe_moddir() -> io::Result<PathBuf> {
    let exe = env::current_exe()?;
    Ok(infer_moddir_from_exe(&exe).unwrap_or_else(|| PathBuf::from("/data/adb/modules/MagicNet")))
}

fn infer_moddir_from_exe(exe: &Path) -> Option<PathBuf> {
    for candidate in exe.ancestors().skip(1) {
        if candidate.join("module.prop").is_file()
            && candidate.join("lib/kamfw/.kamfwrc").is_file()
        {
            return Some(candidate.to_path_buf());
        }
    }
    None
}

#[cfg(test)]
mod path_tests {
    use super::infer_moddir_from_exe;
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
}

fn dispatch(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("help") {
        "service" if args.get(1).map(String::as_str).unwrap_or("status") == "status" => {
            service_status(app);
            Ok(())
        }
        "service" if args.get(1).map(String::as_str) == Some("logs") => service_logs(app, args),
        "service" => service_cmd(app, &args[1..]),
        "supervisor" => supervisor_cmd(app, &args[1..]),
        "watchdog" => watchdog_cmd(app, &args[1..]),
        "pingtest" => {
            pingtest();
            Ok(())
        }
        "health" => health(app),
        "diagnose" => run_magicnet_function(app, "magicnet_action_diagnose"),
        "repair" => repair(app),
        "topology" => topology(app),
        "sysroute" => sysroute(args),
        "support" => support(app, &args[1..]),
        "setup" => setup_subscription(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "config" => config_cmd(app, &args[1..]),
        "transparent" => transparent_cmd(app, &args[1..]),
        "core" => core_cmd(app, &args[1..]),
        "hotspot" => hotspot_cmd(app, &args[1..]),
        "vpn" => vpn_cmd(app, &args[1..]),
        "tailscale" => tailscale_cmd(app, &args[1..]),
        "api" => api_cmd(app, &args[1..]),
        "node" if args.get(1).map(String::as_str).unwrap_or("list") == "list" => {
            node_list(app);
            Ok(())
        }
        "sub" if args.get(1).map(String::as_str) == Some("list") => {
            sub_list(app);
            Ok(())
        }
        "sub" if args.get(1).map(String::as_str) == Some("get") => {
            sub_get(app, args.get(2).map(String::as_str).unwrap_or("sing-box"));
            Ok(())
        }
        "sub" if args.get(1).map(String::as_str) == Some("set") => sub_set(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("set-file") => sub_set_file(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("update") => sub_update(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("update-all") => sub_update_all(app),
        "config-editor" => config_editor(app, &args[1..]),
        "sub"
            if matches!(
                args.get(1).map(String::as_str),
                Some("file") | Some("copy-path")
            ) =>
        {
            println!(
                "{}",
                sub_target_file(app, args.get(2).map(String::as_str).unwrap_or("sing-box"))
                    .display()
            );
            Ok(())
        }
        "route" => route_cmd(app, &args[1..]),
        "capture" => capture_cmd(app, &args[1..]),
        "cert" => cert_cmd(app, &args[1..]),
        "app" => app_cmd(app, &args[1..]),
        "block" => block_cmd(app, &args[1..]),
        "mcp" => mcp(app, &args[1..]),
        "webui" => webui_cmd(app, &args[1..]),
        "backup" => backup_cmd(app, &args[1..]),
        "help" | "-h" | "--help" => {
            help();
            Ok(())
        }
        _ => Err(format!(
            "unknown command: {}\nRun `cli help` for usage.",
            args.join(" ")
        )),
    }
}

pub(crate) fn pid_summary(name: &str) -> String {
    let mut pids = Vec::new();
    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let file_name = entry.file_name();
            let Some(pid) = file_name
                .to_str()
                .filter(|value| value.bytes().all(|b| b.is_ascii_digit()))
            else {
                continue;
            };
            let comm = entry.path().join("comm");
            if fs::read_to_string(comm)
                .map(|value| value.trim() == name)
                .unwrap_or(false)
            {
                pids.push(pid.to_string());
            }
        }
    }
    if pids.is_empty() {
        "stopped".to_string()
    } else {
        pids.join(",")
    }
}

pub(crate) fn run_magicnet_function(app: &App, function_name: &str) -> Result<(), String> {
    let script = format!(
        ". '{0}/lib/kamfw/.kamfwrc'; export PATH='{0}/bin':'{0}/system/bin':\"$PATH\"; import __runtime__; . '{0}/lib/magicnet.sh'; {function_name}",
        app.moddir.display(),
    );
    let status = Command::new("sh")
        .arg("-c")
        .arg(script)
        .arg(app.moddir.join("cli").to_string_lossy().to_string())
        .env("MODDIR", &app.moddir)
        .env("MODPATH", &app.moddir)
        .stdin(Stdio::null())
        .output()
        .map_err(|err| format!("failed to run {function_name}: {err}"))?;
    if !status.stdout.is_empty() {
        print!("{}", String::from_utf8_lossy(&status.stdout));
    }
    if !status.stderr.is_empty() {
        eprint!("{}", String::from_utf8_lossy(&status.stderr));
    }
    if status.status.success() {
        Ok(())
    } else {
        if should_report_startup_error(function_name) {
            if let Some(err) = startup_error(app) {
                return Err(err);
            }
        }
        Err(format!(
            "{function_name} failed with status {}",
            status.status.code().unwrap_or(1)
        ))
    }
}

fn should_report_startup_error(function_name: &str) -> bool {
    function_name.contains("magicnet_start_kernel")
        || function_name.contains("magicnet_ensure_kernel")
        || function_name.contains("magicnet_watchdog_start")
}

fn startup_error(app: &App) -> Option<String> {
    let text = fs::read_to_string(app.moddir.join(".state/startup-error")).ok()?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

fn help() {
    println!(
        "MagicNet CLI\n\nUsage:\n  cli service {{status|start|ensure|stop|restart [current|sing-box|mihomo|auto]|toggle <sing-box|mihomo>|logs [sing-box|mihomo] [lines]}}\n  cli supervisor {{status|start|stop|restart}} [watchdog|fswatch|all]\n  cli watchdog {{status|start|stop|restart}}\n  cli health\n  cli pingtest\n  cli topology\n  cli sysroute {{list|snapshot|add-rule <priority> <table>|del-rule <priority>|add-route <table> <dest|default> <dev> [via]|del-route <table> <dest|default>}}\n  cli repair\n  cli support bundle\n  cli setup <subscription-url>\n  cli config {{apply}}\n  cli config-editor {{get|path|validate|save|save-file|sync-template}} <mihomo|sing-box|all> [base64-config|tmp-path]\n  cli transparent {{status|set <tun|tproxy>|apply}}\n  cli core {{status|selected|select <sing-box|mihomo>}}\n  cli tailscale {{status|set <auth-key|-keep> [hostname] [subnets_csv]|disable|apply}}\n  cli node {{list|current|use <name>}}\n  cli mode [rule|global|direct]\n  cli route {{list|add-domain <proxy|direct|block> <domain-suffix>|remove-domain <proxy|direct|block> <domain-suffix>|apply}}\n  cli sub {{update <sing-box|mihomo|all>|update-all|list|get <sing-box|mihomo>|set <sing-box|mihomo|clash> [provider] <url>|set-file <sing-box> <base64-lines>|file [sing-box|mihomo]}}\n  cli cert {{list|dir|ensure-default|install <name|hash.0|auto> <base64-cert>|remove <filename.0>}}\n  cli capture {{list|set <host> <port> [name]|enable|disable|add-app <package>|remove-app <package>|add-domain <suffix>|remove-domain <suffix>|apply}}\n  cli block {{list|enable|disable|community <on|off>|url <http-url>|update|add-domain <suffix>|remove-domain <suffix>|allow-rule <rule>|unallow-rule <rule>|diff|apply}}\n  cli mcp {{status|enable [bind] [port]|disable|set [bind] [port]|start|stop|restart|logs [lines]}}\n  cli webui {{status|verify|install-local <download-url> [name]}}\n  cli backup {{export [password]|restore [password|-] <base64>}}\n  cli api {{ui [current|mihomo|sing-box|all]|groups|conns|stats|close-all}}\n  cli app {{list|mode <blacklist|whitelist>|add <package> [proxy|bypass]|remove <package>|apply}}\n  cli hotspot {{status|set <proxy|direct>|reload}}\n  cli vpn {{status|set <on|off>|reload}}\n  cli diagnose"
    );
}

#[allow(dead_code)]
fn safe_module_path(app: &App, rel: &str) -> Result<PathBuf, String> {
    let rel = rel.trim_start_matches('/');
    let path = Path::new(rel);
    for component in path.components() {
        match component {
            Component::Normal(_) => {}
            _ => return Err("invalid path".to_string()),
        }
    }
    Ok(app.moddir.join(path))
}

#[allow(dead_code)]
fn read_stdin() -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    io::stdin().read_to_end(&mut bytes)?;
    Ok(bytes)
}
