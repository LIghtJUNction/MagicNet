use crate::chain::chain_cmd;
use crate::config_editor::config_editor;
use crate::diagnostics::{health, support, sysroute, topology};
use crate::dns::dns_cmd;
use crate::ecapture::ecapture_cmd;
use crate::mcp::mcp;
use crate::network::network_cmd;
use crate::nodes::node_cmd;
use crate::ping::{pingtest, speedtest};
use crate::rules::{app_cmd, block_cmd, route_cmd};
use crate::service::{
    config_cmd, core_cmd, repair, service_cmd, service_logs, service_status, supervisor_cmd,
    transparent_cmd,
};
use crate::subscriptions::{
    setup_subscription, sub_apply_file, sub_filter, sub_get, sub_list, sub_resolve_host,
    sub_schedule, sub_set, sub_set_file, sub_status, sub_target_file, sub_update, sub_update_all,
    sub_user_agent,
};
use crate::warp::warp_cmd;
use crate::webui_api::{api_cmd, hotspot_cmd, webui_cmd};
use crate::webui_backup::backup_cmd;
use crate::wifi::wifi_cmd;
use crate::{run_magicnet_function, App};

type CommandHandler = fn(&App, &[String]) -> Result<(), String>;

struct CommandSpec {
    name: &'static str,
    syntax: &'static str,
    handler: CommandHandler,
}

impl CommandSpec {
    fn usage(&self) -> String {
        match self.syntax {
            "" => format!("cli {}", self.name),
            syntax => format!("cli {} {syntax}", self.name),
        }
    }
}

macro_rules! commands {
    ($($name:literal => $handler:expr, $syntax:literal;)*) => {
        &[$(CommandSpec { name: $name, syntax: $syntax, handler: $handler },)*]
    };
}

const COMMANDS: &[CommandSpec] = commands! {
    "service" => service_command, "{status|start|ensure|stop|restart [current|sing-box]|toggle sing-box|logs [webui|sing-box|mcp|fswatch|supervisors|filename] [lines]}";
    "supervisor" => supervisor_cmd, "{status|start|stop|restart} [fswatch|wifi-policy|all]";
    "state" => state_command, "reconcile";
    "health" => |app, _| health(app), "";
    "pingtest" => |_, _| pingtest(), "";
    "speedtest" => |_, _| speedtest(), "";
    "topology" => |app, _| topology(app), "";
    "ecapture" => ecapture_cmd, "{status|version|help [tls|gotls|nspr|pcap]|tls [seconds] [pid|all] [uid|all]|gotls [seconds] [pid|all] [uid|all]|nspr [seconds] [pid|all] [uid|all]|pcap [seconds] <ifname> [pcap-filter ...]}";
    "sysroute" => |_, args| sysroute(&prefixed_args("sysroute", args)), "{list|snapshot|add-rule <priority> <table>|del-rule <priority>|add-route <table> <dest|default> <dev> [via]|del-route <table> <dest|default>}";
    "repair" => |app, _| repair(app), "";
    "support" => support, "bundle";
    "setup" => |app, args| setup_subscription(app, args.first().map_or("", String::as_str)), "<subscription-url>";
    "config" => config_cmd, "apply";
    "config-editor" => config_editor, "{get|path|validate|save|save-file|sync-template} <sing-box|all> [base64-config|webui-payload-path] | repo {get|get-json|set|set-file|reset} [base64-json|webui-payload-path]";
    "transparent" => transparent_cmd, "{status|set tun|set ebpf|apply}";
    "network" => network_cmd, "{status|set <ipv4_only|prefer_ipv4|prefer_ipv6> <mtu:1280-1500> <udp-timeout:1m|3m|5m|10m|15m|30m>|apply}";
    "core" => core_cmd, "{status|selected|select sing-box}";
    "node" => node_cmd, "{list|current|use|test <name>|test-all [name ...]}";
    "chain" => chain_cmd, "{status|enable|disable|set-upstream <tag>|set-exit <tag>|clear-upstream|clear-exit|mode <manual|auto>|select-upstream <tag>|select-exit <tag>}";
    "mode" => crate::webui_api::clash_mode_cmd, "[rule|global|direct]";
    "wifi" => wifi_cmd, "{status|enable|disable|mode <blacklist|whitelist>|interval <3-300>|add-ssid <ssid>|remove-ssid <ssid>|add-bssid <mac>|remove-bssid <mac>|check}";
    "hotspot" => hotspot_cmd, "{status|enable|disable|reconcile}";
    "route" => route_cmd, "{list|add-domain <proxy|direct|block|warp> <domain-suffix>|remove-domain <proxy|direct|block|warp> <domain-suffix>|apply}";
    "dns" => dns_cmd, "{status|set <default|cloudflare-doh|cloudflare-dot|cloudflare-udp>|test [domain]|apply}";
    "warp" => warp_cmd, "{status|import-file <wireguard-conf-path>|enable|disable|global|rule|apply|test}";
    "sub" => subscription_command, "{update <sing-box|all>|update-all|status|schedule {status|set <off|12|24|48|72>}|user-agent {get|set <base64-value>|clear}|filter {list|set <base64-lines>|clear}|list|get sing-box|set sing-box <url>|set-file sing-box <base64-lines>|apply-file sing-box <base64-lines>|file [sing-box]}";
    "block" => block_cmd, "{list|enable|disable|community <on|off>|url <http-url>|update|add-domain <suffix>|remove-domain <suffix>|allow-rule <rule>|unallow-rule <rule>|diff|apply}";
    "mcp" => mcp, "{status|enable [bind] [port]|disable|set [bind] [port]|secret|rotate-secret|start|stop|restart|logs [lines]}";
    "webui" => webui_cmd, "{status|verify|install-local <https-download-url> <sha256> [name]|payload {create <tmp|subscription> <safe-basename>|append <tmp|subscription> <safe-basename> <base64-chunk>|remove <tmp|subscription> <safe-basename>|apply-subscription <safe-basename>|apply-subscription-source <safe-basename>}}";
    "backup" => backup_cmd, "{export [password]|restore [password|-] <base64>|restore-file [password|-] <path>}";
    "api" => api_cmd, "{ui [current|sing-box|all]|groups|proxies|select <group> <node>|conns|stats|close <id>|close-top [count]|close-matching <query>|close-all}";
    "app" => app_cmd, "{list|packages [query]|recommendations|mode <blacklist|whitelist>|add <package> [proxy|direct|bypass]|add-many <proxy|direct|bypass> <package...>|remove <package> [proxy|direct|bypass]|apply}; proxy=sing-box proxy outbound, direct=sing-box direct outbound, bypass=outside MagicNet";
    "diagnose" => |app, _| run_magicnet_function(app, "magicnet_action_diagnose"), "";
};

pub(crate) fn dispatch(app: &App, args: &[String]) -> Result<(), String> {
    let name = args.first().map_or("help", String::as_str);
    if matches!(name, "help" | "-h" | "--help") {
        print_help();
        return Ok(());
    }

    let command = COMMANDS
        .iter()
        .find(|command| command.name == name)
        .ok_or_else(|| unknown_command(args))?;
    (command.handler)(app, &args[1..])
}

fn unknown_command(args: &[String]) -> String {
    format!(
        "unknown command: {}\nKnown commands: {}\nRun `cli help` for usage.",
        args.join(" "),
        COMMANDS
            .iter()
            .map(|command| command.name)
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn print_help() {
    println!("MagicNet CLI\n\nUsage:");
    for command in COMMANDS {
        println!("  {}", command.usage());
    }
}

fn prefixed_args(command: &str, args: &[String]) -> Vec<String> {
    std::iter::once(command.to_string())
        .chain(args.iter().cloned())
        .collect()
}

fn state_command(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map_or("reconcile", String::as_str) {
        "reconcile" if args.len() <= 1 => crate::state::reconcile(app),
        _ => Err("Usage: cli state reconcile".to_string()),
    }
}

fn sync_service_lifecycle(app: &App) -> Result<(), String> {
    run_magicnet_function(app, "magicnet_lifecycle_sync")
}

fn service_command(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map_or("status", String::as_str) {
        "status" => {
            service_status(app);
            Ok(())
        }
        "logs" => service_logs(app, &prefixed_args("service", args)),
        _ => {
            service_cmd(app, args)?;
            sync_service_lifecycle(app)
        }
    }
}

fn subscription_command(app: &App, args: &[String]) -> Result<(), String> {
    let full_args = prefixed_args("sub", args);
    match args.first().map(String::as_str) {
        Some("list") => {
            sub_list(app);
            Ok(())
        }
        Some("get") => {
            sub_get(app, args.get(1).map_or("sing-box", String::as_str));
            Ok(())
        }
        Some("set") => sub_set(app, &full_args),
        Some("set-file") => sub_set_file(app, &full_args),
        Some("apply-file") => sub_apply_file(app, &full_args),
        Some("update") => sub_update(app, &full_args),
        Some("update-all") => sub_update_all(app),
        Some("status") => sub_status(app),
        Some("schedule") => sub_schedule(app, &full_args),
        Some("user-agent") => sub_user_agent(app, &full_args),
        Some("filter") => sub_filter(app, &full_args),
        Some("resolve-host") => sub_resolve_host(&full_args),
        Some("file" | "copy-path") => {
            println!(
                "{}",
                sub_target_file(app, args.get(1).map_or("sing-box", String::as_str)).display()
            );
            Ok(())
        }
        _ => Err(
            "usage: cli sub {list|get|set|set-file|apply-file|update|update-all|status|schedule|user-agent|filter|resolve-host|file}"
                .to_string(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::{unknown_command, COMMANDS};
    use std::collections::HashSet;

    fn usage_for(command: &str) -> String {
        COMMANDS
            .iter()
            .find(|item| item.name == command)
            .map(|item| item.usage())
            .unwrap_or_else(|| panic!("missing help for {command}"))
    }

    #[test]
    fn command_names_are_unique_and_usage_is_derived_from_the_registry_key() {
        let mut names = HashSet::new();
        for command in COMMANDS {
            assert!(
                names.insert(command.name),
                "duplicate command {}",
                command.name
            );
            assert!(
                command
                    .usage()
                    .starts_with(&format!("cli {}", command.name)),
                "usage does not match command {}",
                command.name
            );
            assert!(!command.syntax.starts_with("cli "));
        }
    }

    #[test]
    fn unknown_command_lists_every_registered_command() {
        let error = unknown_command(&["missing".to_string()]);
        for command in COMMANDS {
            assert!(error.contains(command.name));
        }
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
