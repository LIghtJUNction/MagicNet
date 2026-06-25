mod base64;
#[cfg(test)]
mod base64_tests;
mod config_editor;
mod diagnostics;
mod diagnostics_dns;
mod ecapture;
mod mcp;
mod nodes;
mod ping;
mod rules;
mod service;
mod subscriptions;
mod utils;
mod webui_api;
mod webui_backup;

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

pub(crate) use base64::{decode_base64, encode_base64};
use config_editor::config_editor;
use diagnostics::{health, support, sysroute, topology};
use ecapture::ecapture_cmd;
use mcp::mcp;
use nodes::node_list;
use ping::pingtest;
use rules::{app_cmd, block_cmd, route_cmd};
use service::{
    config_cmd, core_cmd, repair, service_cmd, service_logs, service_status, supervisor_cmd,
    transparent_cmd,
};
use subscriptions::{
    setup_subscription, sub_get, sub_list, sub_set, sub_set_file, sub_target_file, sub_update,
    sub_update_all,
};
pub(crate) use utils::{
    clean_lines, clear_node_cache, command_text_timeout, first_clean_line, read_kv, write_kv,
    write_text_file,
};
use webui_api::{api_cmd, webui_cmd};
use webui_backup::backup_cmd;

const SHORT_TIMEOUT: Duration = Duration::from_secs(3);

struct CommandHelp {
    command: &'static str,
    usage: &'static str,
}

const COMMAND_HELP: &[CommandHelp] = &[
    CommandHelp {
        command: "service",
        usage: "cli service {status|start|ensure|stop|restart [current|sing-box]|toggle sing-box|logs [sing-box] [lines]}",
    },
    CommandHelp {
        command: "supervisor",
        usage: "cli supervisor {status|start|stop|restart} [fswatch|all]",
    },
    CommandHelp {
        command: "health",
        usage: "cli health",
    },
    CommandHelp {
        command: "pingtest",
        usage: "cli pingtest",
    },
    CommandHelp {
        command: "topology",
        usage: "cli topology",
    },
    CommandHelp {
        command: "ecapture",
        usage: "cli ecapture {status|version|help [tls|gotls|nspr|pcap]|tls [seconds] [pid|all] [uid|all]|gotls [seconds] [pid|all] [uid|all]|nspr [seconds] [pid|all] [uid|all]|pcap [seconds] <ifname> [pcap-filter ...]}",
    },
    CommandHelp {
        command: "sysroute",
        usage: "cli sysroute {list|snapshot|add-rule <priority> <table>|del-rule <priority>|add-route <table> <dest|default> <dev> [via]|del-route <table> <dest|default>}",
    },
    CommandHelp {
        command: "repair",
        usage: "cli repair",
    },
    CommandHelp {
        command: "support",
        usage: "cli support bundle",
    },
    CommandHelp {
        command: "setup",
        usage: "cli setup <subscription-url>",
    },
    CommandHelp {
        command: "config",
        usage: "cli config apply",
    },
    CommandHelp {
        command: "config-editor",
        usage: "cli config-editor {get|path|validate|save|save-file|sync-template} <sing-box|all> [base64-config|tmp-path]",
    },
    CommandHelp {
        command: "transparent",
        usage: "cli transparent {status|set <proxy|external-tun|hybrid|tun>|apply}",
    },
    CommandHelp {
        command: "core",
        usage: "cli core {status|selected|select sing-box}",
    },
    CommandHelp {
        command: "node",
        usage: "cli node {list|current|use <name>}",
    },
    CommandHelp {
        command: "mode",
        usage: "cli mode [rule|global|direct]",
    },
    CommandHelp {
        command: "route",
        usage: "cli route {list|add-domain <proxy|direct|block> <domain-suffix>|remove-domain <proxy|direct|block> <domain-suffix>|apply}",
    },
    CommandHelp {
        command: "sub",
        usage: "cli sub {update <sing-box|all>|update-all|list|get sing-box|set sing-box <url>|set-file sing-box <base64-lines>|file [sing-box]}",
    },
    CommandHelp {
        command: "block",
        usage: "cli block {list|enable|disable|community <on|off>|url <http-url>|update|add-domain <suffix>|remove-domain <suffix>|allow-rule <rule>|unallow-rule <rule>|diff|apply}",
    },
    CommandHelp {
        command: "mcp",
        usage: "cli mcp {status|enable [bind] [port]|disable|set [bind] [port]|secret|rotate-secret|start|stop|restart|logs [lines]}",
    },
    CommandHelp {
        command: "webui",
        usage: "cli webui {status|verify|install-local <download-url> [name]}",
    },
    CommandHelp {
        command: "backup",
        usage: "cli backup {export [password]|restore [password|-] <base64>}",
    },
    CommandHelp {
        command: "api",
        usage: "cli api {ui [current|sing-box|all]|groups|conns|stats|close-all}",
    },
    CommandHelp {
        command: "app",
        usage: "cli app {list|mode <blacklist|whitelist>|add <package> [proxy|bypass]|remove <package>|apply}",
    },
    CommandHelp {
        command: "diagnose",
        usage: "cli diagnose",
    },
];

#[derive(Clone)]
pub(crate) struct App {
    pub(crate) moddir: PathBuf,
    api: String,
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
        Self {
            log_dir: moddir.join(".log"),
            moddir,
            api,
        }
    }

    #[cfg(test)]
    pub(crate) fn for_test(moddir: PathBuf) -> Self {
        let api = "http://127.0.0.1:9090".to_string();
        Self {
            log_dir: moddir.join(".log"),
            moddir,
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
        if candidate.join("module.prop").is_file() && candidate.join("lib/kamfw/.kamfwrc").is_file()
        {
            return Some(candidate.to_path_buf());
        }
    }
    None
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
        "pingtest" => {
            pingtest();
            Ok(())
        }
        "health" => health(app),
        "diagnose" => run_magicnet_function(app, "magicnet_action_diagnose"),
        "repair" => repair(app),
        "topology" => topology(app),
        "ecapture" => ecapture_cmd(app, &args[1..]),
        "sysroute" => sysroute(args),
        "support" => support(app, &args[1..]),
        "setup" => setup_subscription(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "config" => config_cmd(app, &args[1..]),
        "transparent" => transparent_cmd(app, &args[1..]),
        "core" => core_cmd(app, &args[1..]),
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
            "unknown command: {}\nKnown commands: {}\nRun `cli help` for usage.",
            args.join(" "),
            COMMAND_HELP
                .iter()
                .map(|item| item.command)
                .collect::<Vec<_>>()
                .join(", ")
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
        .status()
        .map_err(|err| format!("failed to run {function_name}: {err}"))?;
    if status.success() {
        Ok(())
    } else {
        if should_report_startup_error(function_name) {
            if let Some(err) = startup_error(app) {
                return Err(err);
            }
        }
        Err(format!(
            "{function_name} failed with status {}",
            status.code().unwrap_or(1)
        ))
    }
}

fn should_report_startup_error(function_name: &str) -> bool {
    function_name.contains("magicnet_start_kernel")
        || function_name.contains("magicnet_ensure_kernel")
}

fn startup_error(app: &App) -> Option<String> {
    let text = fs::read_to_string(app.moddir.join(".state/startup-error")).ok()?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

fn help() {
    println!("MagicNet CLI\n\nUsage:");
    for item in COMMAND_HELP {
        println!("  {}", item.usage);
    }
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
