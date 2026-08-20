mod base64;
#[cfg(test)]
mod base64_tests;
mod chain;
mod config_editor;
mod connection_control;
mod diagnostics;
mod diagnostics_dns;
mod diagnostics_routing;
mod dns;
mod ecapture;
mod mcp;
mod network;
mod node_delay;
mod nodes;
mod ping;
mod rules;
mod selector_store;
mod service;
mod subscriptions;
mod utils;
mod warp;
mod webui_api;
mod webui_backup;
mod webui_payload;
mod wifi;

use std::env;
use std::fs;
use std::io;
use std::net::IpAddr;
use std::os::fd::RawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;
use std::time::Instant;

pub(crate) use base64::{decode_base64, encode_base64};
use chain::chain_cmd;
use config_editor::config_editor;
use diagnostics::{health, support, sysroute, topology};
use dns::dns_cmd;
use ecapture::ecapture_cmd;
use mcp::mcp;
use network::network_cmd;
use nodes::node_cmd;
use ping::{pingtest, speedtest};
use rules::{app_cmd, block_cmd, route_cmd};
use service::{
    config_cmd, core_cmd, repair, service_cmd, service_logs, service_status, supervisor_cmd,
    transparent_cmd,
};
use subscriptions::{
    setup_subscription, sub_apply_file, sub_filter, sub_get, sub_list, sub_resolve_host,
    sub_schedule, sub_set, sub_set_file, sub_status, sub_target_file, sub_update, sub_update_all,
    sub_user_agent,
};
pub(crate) use utils::{
    clean_lines, clear_node_cache, command_text_timeout, first_clean_line, read_kv,
    shell_inert_conf_value, write_kv, write_secret_file, write_text_file,
};
use warp::warp_cmd;
use webui_api::{api_cmd, hotspot_cmd, webui_cmd};
use webui_backup::backup_cmd;
use wifi::wifi_cmd;

const SHORT_TIMEOUT: Duration = Duration::from_secs(3);
const DEFAULT_COMMAND_TIMEOUT_SECS: u64 = 180;
const MAX_COMMAND_TIMEOUT_SECS: u64 = 900;

fn command_timeout_secs(value: Option<&str>) -> u64 {
    value
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|seconds| (1..=MAX_COMMAND_TIMEOUT_SECS).contains(seconds))
        .unwrap_or(DEFAULT_COMMAND_TIMEOUT_SECS)
}

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
        usage: "cli supervisor {status|start|stop|restart} [fswatch|wifi-policy|all]",
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
        command: "speedtest",
        usage: "cli speedtest",
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
        usage: "cli config-editor {get|path|validate|save|save-file|sync-template} <sing-box|all> [base64-config|webui-payload-path]",
    },
    CommandHelp {
        command: "transparent",
        usage: "cli transparent {status|set tun|apply}",
    },
    CommandHelp {
        command: "network",
        usage: "cli network {status|set <ipv4_only|prefer_ipv4|prefer_ipv6> <mtu:1280-1500> <udp-timeout:1m|3m|5m|10m|15m|30m>|apply}",
    },
    CommandHelp {
        command: "core",
        usage: "cli core {status|selected|select sing-box}",
    },
    CommandHelp {
        command: "node",
        usage: "cli node {list|current|use|test <name>|test-all [name ...]}",
    },
    CommandHelp {
        command: "chain",
        usage: "cli chain {status|enable|disable|set-upstream <tag>|set-exit <tag>|clear-upstream|clear-exit|mode <manual|auto>|select-upstream <tag>|select-exit <tag>}",
    },
    CommandHelp {
        command: "mode",
        usage: "cli mode [rule|global|direct]",
    },
    CommandHelp {
        command: "wifi",
        usage: "cli wifi {status|enable|disable|mode <blacklist|whitelist>|interval <3-300>|add-ssid <ssid>|remove-ssid <ssid>|add-bssid <mac>|remove-bssid <mac>|check}",
    },
    CommandHelp {
        command: "hotspot",
        usage: "cli hotspot {status|enable|disable|reconcile}",
    },
    CommandHelp {
        command: "route",
        usage: "cli route {list|add-domain <proxy|direct|block|warp> <domain-suffix>|remove-domain <proxy|direct|block|warp> <domain-suffix>|apply}",
    },
    CommandHelp {
        command: "dns",
        usage: "cli dns {status|set <default|cloudflare-doh|cloudflare-dot|cloudflare-udp>|test [domain]|apply}",
    },
    CommandHelp {
        command: "warp",
        usage: "cli warp {status|import-file <wireguard-conf-path>|enable|disable|global|rule|apply|test}",
    },
    CommandHelp {
        command: "sub",
        usage: "cli sub {update <sing-box|all>|update-all|status|schedule {status|set <off|12|24|48|72>}|user-agent {get|set <base64-value>|clear}|filter {list|set <base64-lines>|clear}|list|get sing-box|set sing-box <url>|set-file sing-box <base64-lines>|apply-file sing-box <base64-lines>|file [sing-box]}",
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
        usage: "cli webui {status|verify|install-local <https-download-url> <sha256> [name]|payload {create <tmp|subscription> <safe-basename>|append <tmp|subscription> <safe-basename> <base64-chunk>|remove <tmp|subscription> <safe-basename>|apply-subscription <safe-basename>|apply-subscription-source <safe-basename>}}",
    },
    CommandHelp {
        command: "backup",
        usage: "cli backup {export [password]|restore [password|-] <base64>|restore-file [password|-] <path>}",
    },
    CommandHelp {
        command: "api",
        usage: "cli api {ui [current|sing-box|all]|groups|proxies|select <group> <node>|conns|stats|close <id>|close-top [count]|close-matching <query>|close-all}",
    },
    CommandHelp {
        command: "app",
        usage: "cli app {list|packages [query]|recommendations|mode <blacklist|whitelist>|add <package> [proxy|direct|bypass]|add-many <proxy|direct|bypass> <package...>|remove <package> [proxy|direct|bypass]|apply}",
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

const MODULE_DIR: &str = "/data/adb/modules/MagicNet";
const DEFAULT_API: &str = "http://127.0.0.1:9090";

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

fn dispatch(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("help") {
        "service" if args.get(1).map(String::as_str).unwrap_or("status") == "status" => {
            service_status(app);
            Ok(())
        }
        "service" if args.get(1).map(String::as_str) == Some("logs") => service_logs(app, args),
        "service" => service_cmd(app, &args[1..]),
        "supervisor" => supervisor_cmd(app, &args[1..]),
        "pingtest" => pingtest(),
        "speedtest" => speedtest(),
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
        "network" => network_cmd(app, &args[1..]),
        "core" => core_cmd(app, &args[1..]),
        "api" => api_cmd(app, &args[1..]),
        "mode" => webui_api::clash_mode_cmd(app, &args[1..]),
        "wifi" => wifi_cmd(app, &args[1..]),
        "hotspot" => hotspot_cmd(app, &args[1..]),
        "node" => node_cmd(app, &args[1..]),
        "chain" => chain_cmd(app, &args[1..]),
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
        "sub" if args.get(1).map(String::as_str) == Some("apply-file") => sub_apply_file(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("update") => sub_update(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("update-all") => sub_update_all(app),
        "sub" if args.get(1).map(String::as_str) == Some("status") => sub_status(app),
        "sub" if args.get(1).map(String::as_str) == Some("schedule") => sub_schedule(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("user-agent") => sub_user_agent(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("filter") => sub_filter(app, args),
        "sub" if args.get(1).map(String::as_str) == Some("resolve-host") => sub_resolve_host(args),
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
        "dns" => dns_cmd(app, &args[1..]),
        "warp" => warp_cmd(app, &args[1..]),
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
            if !proc_pid_is_live(&entry.path()) {
                continue;
            }
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

/// Return only sing-box processes launched from this module's managed
/// binary/configuration. A process named `sing-box` is not sufficient proof
/// of ownership: another VPN/core can legitimately use the same name and
/// must not make MagicNet report a healthy core or be killed on stop.
pub(crate) fn singbox_pid_summary(app: &App) -> String {
    let pids = owned_singbox_pids(app);
    if pids.is_empty() {
        "stopped".to_string()
    } else {
        pids.join(",")
    }
}

fn owned_singbox_pids(app: &App) -> Vec<String> {
    let expected_binary = app.moddir.join("bin/sing-box");
    let expected_config = app.moddir.join(".config/sing-box/config.json");
    let expected_workdir = app.moddir.join(".config/sing-box");
    let expected_binary = fs::canonicalize(&expected_binary).ok();
    let mut pids = Vec::new();
    let Ok(entries) = fs::read_dir("/proc") else {
        return pids;
    };
    for entry in entries.flatten() {
        let file_name = entry.file_name();
        let Some(pid) = file_name
            .to_str()
            .filter(|value| value.bytes().all(|byte| byte.is_ascii_digit()))
        else {
            continue;
        };
        let proc_dir = entry.path();
        if !proc_pid_is_live(&proc_dir) {
            continue;
        }
        if !fs::read_to_string(proc_dir.join("comm"))
            .map(|value| value.trim() == "sing-box")
            .unwrap_or(false)
        {
            continue;
        }
        let argv = fs::read(proc_dir.join("cmdline"))
            .ok()
            .map(|bytes| {
                bytes
                    .split(|byte| *byte == 0)
                    .filter(|value| !value.is_empty())
                    .map(|value| String::from_utf8_lossy(value).into_owned())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let commandline_owned =
            singbox_commandline_owned(&argv, &expected_binary, &expected_config, &expected_workdir);
        let executable_owned = singbox_executable_owned(&proc_dir, &expected_binary);
        let argv0_fallback = executable_owned.is_none()
            && argv.first().map(String::as_str) == Some("sing-box")
            && expected_binary.is_some();
        if commandline_owned
            && (executable_owned == Some(true)
                || singbox_script_arg_owned(&argv, &expected_binary)
                || argv0_fallback)
        {
            pids.push(pid.to_string());
        }
    }
    pids
}

fn proc_pid_is_live(proc_dir: &Path) -> bool {
    fs::read_to_string(proc_dir.join("stat"))
        .map(|stat| proc_pid_stat_is_live(&stat))
        .unwrap_or(false)
}

fn proc_pid_stat_is_live(stat: &str) -> bool {
    stat.rsplit_once(") ")
        .and_then(|(_, fields)| fields.chars().next())
        .is_some_and(|state| state != 'Z')
}

fn singbox_executable_owned(proc_dir: &Path, expected_binary: &Option<PathBuf>) -> Option<bool> {
    let Some(expected_binary) = expected_binary else {
        return Some(false);
    };
    let Ok(executable) = fs::read_link(proc_dir.join("exe")) else {
        // Script-backed host fixtures expose the module script in argv while
        // /proc/exe points at the interpreter. On Android some SELinux
        // contexts also hide this link; the caller may then use the exact
        // `sing-box run -c <module-config> -D <module-workdir>` argv fallback.
        return None;
    };
    Some(
        fs::canonicalize(executable)
            .map(|path| path == *expected_binary)
            .unwrap_or(false),
    )
}

fn singbox_script_arg_owned(argv: &[String], expected_binary: &Option<PathBuf>) -> bool {
    let Some(expected_binary) = expected_binary else {
        return false;
    };
    let expected_binary = expected_binary.to_string_lossy();
    argv.iter().any(|arg| arg == expected_binary.as_ref())
}

fn singbox_commandline_owned(
    argv: &[String],
    expected_binary: &Option<PathBuf>,
    expected_config: &Path,
    expected_workdir: &Path,
) -> bool {
    let Some(run_index) = argv.iter().position(|arg| arg == "run") else {
        return false;
    };
    let expected_binary = expected_binary
        .as_ref()
        .map(|path| path.to_string_lossy().into_owned());
    let binary_arg = expected_binary.as_deref();
    let script_arg_matches = binary_arg.is_some_and(|binary| argv.iter().any(|arg| arg == binary));
    if !script_arg_matches && !argv.first().is_some_and(|arg| arg == "sing-box") {
        return false;
    }
    let mut config = None;
    let mut workdir = None;
    let mut config_count = 0;
    let mut workdir_count = 0;
    let mut index = run_index + 1;
    while index < argv.len() {
        match argv[index].as_str() {
            "-c" => {
                config_count += 1;
                config = argv.get(index + 1).map(String::as_str);
                index += 1;
            }
            "-D" => {
                workdir_count += 1;
                workdir = argv.get(index + 1).map(String::as_str);
                index += 1;
            }
            _ => {}
        }
        index += 1;
    }
    let expected_config = expected_config.to_string_lossy();
    let expected_workdir = expected_workdir.to_string_lossy();
    config_count == 1
        && workdir_count == 1
        && config == Some(expected_config.as_ref())
        && workdir == Some(expected_workdir.as_ref())
}

pub(crate) fn stop_owned_singbox(app: &App) {
    let pids = owned_singbox_pids(app);
    for pid in &pids {
        signal_pid(pid, false);
    }
    thread::sleep(Duration::from_secs(1));
    for pid in pids {
        let proc_dir = Path::new("/proc").join(&pid);
        if proc_dir.exists() && owned_singbox_pids(app).iter().any(|live| live == &pid) {
            signal_pid(&pid, true);
        }
    }
}

fn signal_pid(pid: &str, force: bool) {
    let program = if cfg!(target_os = "android") {
        "/system/bin/kill"
    } else {
        "/bin/kill"
    };
    let mut command = Command::new(program);
    if force {
        command.arg("-9");
    }
    let _ = command.arg(pid).status();
}

// These variables are implementation details of the subscription transaction.
// A privileged CLI process must not let a caller-provided environment replace
// the module-owned URL/configuration files, candidate descriptor, or test-only
// transaction controls before the shell entrypoint runs.
const UNSAFE_SUBSCRIPTION_ENV: &[&str] = &[
    "MAGICNET_SUB_CANDIDATE_URL_FILE",
    "MAGICNET_SUB_CANDIDATE_SOURCE_FILE",
    "MAGICNET_SUB_CONFIG_FILE",
    "MAGICNET_SUB_FILTER_FILE",
    "MAGICNET_SUB_SOURCE_FILE",
    "MAGICNET_SUB_URL_FILE",
    "MAGICNET_SUB_USER_AGENT_FILE",
    "MAGICNET_SUB_FAULT",
    "MAGICNET_SUB_FAULT_EXIT137",
    "MAGICNET_SUB_FAULT_TERM",
    "MAGICNET_SUB_REFRESH_OWNER_WRITE_FAIL",
    "MAGICNET_SUB_REFRESH_PROC_ROOT",
    "MAGICNET_SUB_DEFER_FSWATCH_RESTORE",
    "MAGICNET_SUB_FSWATCH_RESTORE_PENDING",
    "MAGICNET_SUB_FSWATCH_WAS_ACTIVE",
    "MAGICNET_SUB_PRESERVE_REFRESH",
];

fn clear_unsafe_subscription_environment(command: &mut Command) {
    for key in UNSAFE_SUBSCRIPTION_ENV {
        command.env_remove(key);
    }
}

fn trusted_shell() -> &'static str {
    if cfg!(target_os = "android") {
        "/system/bin/sh"
    } else {
        "/bin/sh"
    }
}

fn trusted_path() -> &'static str {
    if cfg!(target_os = "android") {
        "$MODDIR/bin:$MODDIR/system/bin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:/vendor/xbin"
    } else {
        // The fake-Magisk smoke harness supplies its command doubles through
        // this explicitly named test-only variable. Normal host invocations
        // use a fixed system path just like the Android build.
        "$MODDIR/bin:$MODDIR/system/bin:${MAGICNET_TEST_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
    }
}

pub(crate) fn run_magicnet_function(app: &App, function_name: &str) -> Result<(), String> {
    run_magicnet_function_inner(app, function_name, None)
}

/// Run the fixed subscription-update entrypoint with a private, already-open
/// candidate descriptor. The only injected environment value is derived from
/// that descriptor; callers cannot supply arbitrary command environment.
pub(crate) fn run_subscription_update_from_inherited_fd(
    app: &App,
    candidate_fd: RawFd,
) -> Result<(), String> {
    run_subscription_update_from_inherited_fd_with_kind(
        app,
        candidate_fd,
        "MAGICNET_SUB_CANDIDATE_URL_FILE",
    )
}

pub(crate) fn run_subscription_source_update_from_inherited_fd(
    app: &App,
    candidate_fd: RawFd,
) -> Result<(), String> {
    run_subscription_update_from_inherited_fd_with_kind(
        app,
        candidate_fd,
        "MAGICNET_SUB_CANDIDATE_SOURCE_FILE",
    )
}

fn run_subscription_update_from_inherited_fd_with_kind(
    app: &App,
    candidate_fd: RawFd,
    candidate_env: &'static str,
) -> Result<(), String> {
    if candidate_fd < 0 {
        return Err("invalid subscription candidate descriptor".to_string());
    }
    run_magicnet_function_inner(
        app,
        ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; magicnet_singbox_update_subscription",
        Some((candidate_env, candidate_fd)),
    )
}

fn run_magicnet_function_inner(
    app: &App,
    function_name: &str,
    subscription_candidate: Option<(&'static str, RawFd)>,
) -> Result<(), String> {
    // Keep the module path in the environment and quote it at every shell
    // use.  MODDIR can be inherited from an untrusted launcher; interpolating
    // its display form into a single-quoted script would turn a path quote
    // into root shell syntax before the command even starts.
    let script = format!(
        ". \"$MODDIR/lib/kamfw/.kamfwrc\"; export PATH=\"{}\"; import __runtime__; . \"$MODDIR/lib/magicnet.sh\"; {function_name}",
        trusted_path(),
    );
    let timeout = Duration::from_secs(command_timeout_secs(
        env::var("MAGICNET_COMMAND_TIMEOUT").ok().as_deref(),
    ));
    // Do not resolve the privileged shell through a caller-controlled PATH.
    let mut command = Command::new(trusted_shell());
    command
        .arg("-c")
        .arg(script)
        .arg(app.moddir.join("cli").to_string_lossy().to_string())
        .env("MODDIR", &app.moddir)
        .env("MODPATH", &app.moddir)
        .stdin(Stdio::null());
    clear_unsafe_subscription_environment(&mut command);
    if let Some((candidate_env, candidate_fd)) = subscription_candidate {
        command.env(candidate_env, format!("/proc/self/fd/{candidate_fd}"));
    }
    let status = match run_process_group(&mut command, timeout) {
        Ok(status) => status,
        Err(err) => {
            if function_name.contains("magicnet_singbox_update_subscription") {
                subscriptions::cleanup_stale_update_lock(app);
            }
            return Err(format!("{function_name}: {err}"));
        }
    };
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

fn run_process_group(
    command: &mut Command,
    timeout: Duration,
) -> Result<std::process::ExitStatus, String> {
    let parent_pid = unsafe { libc::getpid() };
    // SAFETY: pre_exec only invokes async-signal-safe libc operations before
    // exec.  The parent-death signal prevents an externally killed CLI from
    // leaving its privileged shell alive with subscription/config locks.  The
    // parent check closes the fork-to-prctl race: if the CLI died before the
    // child armed PR_SET_PDEATHSIG, the child aborts instead of becoming an
    // untracked session leader.
    unsafe {
        command.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) == -1 {
                Err(io::Error::last_os_error())
            } else if libc::getppid() != parent_pid {
                Err(io::Error::from_raw_os_error(libc::ECHILD))
            } else if libc::setsid() == -1 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let mut child = command
        .spawn()
        .map_err(|err| format!("spawn failed: {err}"))?;
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|err| format!("wait failed: {err}"))?
        {
            return Ok(status);
        }
        if Instant::now() >= deadline {
            let group = -(child.id() as i32);
            unsafe {
                libc::kill(group, libc::SIGTERM);
            }
            thread::sleep(Duration::from_millis(100));
            unsafe {
                libc::kill(group, libc::SIGKILL);
            }
            let _ = child.wait();
            return Err(format!("timed out after {}ms", timeout.as_millis()));
        }
        thread::sleep(Duration::from_millis(40));
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
    use super::{
        infer_moddir_from_exe, is_loopback_http_api, proc_pid_stat_is_live,
        singbox_commandline_owned,
    };
    use std::env;
    use std::fs;
    use std::path::{Path, PathBuf};
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
    fn singbox_ownership_requires_module_binary_and_exact_runtime_paths() {
        let binary = Some(PathBuf::from("/module/bin/sing-box"));
        let config = Path::new("/module/.config/sing-box/config.json");
        let workdir = Path::new("/module/.config/sing-box");
        let owned = vec![
            "/module/bin/sing-box".to_string(),
            "run".to_string(),
            "-c".to_string(),
            config.display().to_string(),
            "-D".to_string(),
            workdir.display().to_string(),
        ];
        assert!(singbox_commandline_owned(&owned, &binary, config, workdir));

        let script_owned = vec![
            "/bin/sh".to_string(),
            "/module/bin/sing-box".to_string(),
            "run".to_string(),
            "-c".to_string(),
            config.display().to_string(),
            "-D".to_string(),
            workdir.display().to_string(),
        ];
        assert!(singbox_commandline_owned(
            &script_owned,
            &binary,
            config,
            workdir
        ));

        let mut wrong_config = owned.clone();
        wrong_config[3] = "/other/config.json".to_string();
        assert!(!singbox_commandline_owned(
            &wrong_config,
            &binary,
            config,
            workdir
        ));

        let mut duplicate_workdir = owned.clone();
        duplicate_workdir.extend(["-D".to_string(), workdir.display().to_string()]);
        assert!(!singbox_commandline_owned(
            &duplicate_workdir,
            &binary,
            config,
            workdir
        ));
    }

    #[test]
    fn singbox_zombie_processes_are_not_reported_as_running() {
        assert!(proc_pid_stat_is_live("123 (sing-box) S 1 2 3 4 5 6"));
        assert!(!proc_pid_stat_is_live("123 (sing-box) Z 1 2 3 4 5 6"));
        assert!(!proc_pid_stat_is_live("malformed"));
    }
}

#[cfg(test)]
mod command_help_tests {
    use super::COMMAND_HELP;

    fn usage_for(command: &str) -> &'static str {
        COMMAND_HELP
            .iter()
            .find(|item| item.command == command)
            .map(|item| item.usage)
            .unwrap_or_else(|| panic!("missing help for {command}"))
    }

    #[test]
    fn app_help_lists_implemented_package_commands() {
        let usage = usage_for("app");
        assert!(usage.contains("packages [query]"));
        assert!(usage.contains("recommendations"));
        assert!(usage.contains("add-many <proxy|direct|bypass> <package...>"));
    }

    #[test]
    fn backup_help_lists_file_restore() {
        assert!(usage_for("backup").contains("restore-file [password|-] <path>"));
    }

    #[test]
    fn speedtest_help_has_explicit_usage() {
        assert_eq!(usage_for("speedtest"), "cli speedtest");
    }
}

#[cfg(test)]
mod process_group_tests {
    use super::{
        clear_unsafe_subscription_environment, command_timeout_secs, run_magicnet_function,
        run_process_group, trusted_shell, App, DEFAULT_COMMAND_TIMEOUT_SECS,
        MAX_COMMAND_TIMEOUT_SECS, UNSAFE_SUBSCRIPTION_ENV,
    };
    use std::fs;
    use std::process::Command;
    use std::time::Duration;

    #[test]
    fn command_timeout_is_finite_and_rejects_zero_or_overflow() {
        assert_eq!(command_timeout_secs(None), DEFAULT_COMMAND_TIMEOUT_SECS);
        assert_eq!(command_timeout_secs(Some("1")), 1);
        assert_eq!(command_timeout_secs(Some("900")), MAX_COMMAND_TIMEOUT_SECS);
        for value in ["", "0", "-1", "901", "18446744073709551616", "junk"] {
            assert_eq!(
                command_timeout_secs(Some(value)),
                DEFAULT_COMMAND_TIMEOUT_SECS,
                "unexpected timeout parse for {value:?}"
            );
        }
    }

    #[test]
    fn timeout_reaps_command_and_kills_grandchild() {
        let pid_file =
            std::env::temp_dir().join(format!("magicnet-grandchild-{}", std::process::id()));
        let script = format!("sleep 30 & echo $! > '{}'; wait", pid_file.display());
        let mut command = Command::new("sh");
        command.args(["-c", &script]);
        assert!(run_process_group(&mut command, Duration::from_millis(100)).is_err());
        let pid = fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse::<i32>()
            .unwrap();
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        let _ = fs::remove_file(pid_file);
    }

    #[test]
    fn timeout_immediately_cleans_dead_update_owner() {
        let root =
            std::env::temp_dir().join(format!("magicnet-timeout-lock-{}", std::process::id()));
        let lock = root.join(".state/sing-box/subscription-update.lock");
        fs::create_dir_all(&lock).unwrap();
        let script = format!(
            "start=$(awk '{{print $22}}' /proc/$$/stat); echo \"$$:$start:test\" > '{}/owner'; sleep 30 & wait",
            lock.display()
        );
        let mut command = Command::new("sh");
        command.args(["-c", &script]);
        assert!(run_process_group(&mut command, Duration::from_millis(100)).is_err());
        let app = App {
            moddir: root.clone(),
            api: String::new(),
            log_dir: root.join(".log"),
        };
        crate::subscriptions::cleanup_stale_update_lock(&app);
        assert!(!lock.exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn function_runner_does_not_interpolate_shell_sensitive_module_paths() {
        let root =
            std::env::temp_dir().join(format!("magicnet-function-quote-{}-'", std::process::id()));
        fs::create_dir_all(root.join("lib/kamfw")).unwrap();
        fs::write(root.join("lib/kamfw/.kamfwrc"), "import() { :; }\n").unwrap();
        fs::write(root.join("lib/magicnet.sh"), "").unwrap();
        let app = App {
            moddir: root.clone(),
            api: String::new(),
            log_dir: root.join(".log"),
        };

        run_magicnet_function(&app, "printf '%s' safe > \"$MODDIR/function-result\"")
            .expect("shell-sensitive module path must remain data");
        assert_eq!(
            fs::read_to_string(root.join("function-result")).unwrap(),
            "safe"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn function_runner_does_not_inherit_subscription_file_overrides() {
        let mut command = Command::new("sh");
        command.args(["-c", "env"]);
        for key in UNSAFE_SUBSCRIPTION_ENV {
            command.env(key, "attacker-controlled");
        }
        clear_unsafe_subscription_environment(&mut command);
        let output = command.output().expect("environment probe must run");
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).unwrap();
        for key in UNSAFE_SUBSCRIPTION_ENV {
            assert!(
                !stdout
                    .lines()
                    .any(|line| line.starts_with(&format!("{key}="))),
                "unsafe subscription variable leaked: {key}"
            );
        }
    }

    #[test]
    fn function_runner_uses_an_absolute_shell_path() {
        assert!(trusted_shell().starts_with('/'));
    }
}
