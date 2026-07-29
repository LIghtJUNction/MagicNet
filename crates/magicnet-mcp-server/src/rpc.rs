use serde_json::{json, Value};
use std::process::Command;

use crate::base64::encode_base64;
use crate::files::{file_list, file_read};
use crate::logs::{debug_snapshot, log_list, log_read};
use crate::tools::TOOLS_JSON;
use crate::Server;

pub(crate) fn handle_jsonrpc(payload: &str, server: &Server) -> String {
    let request: Value = match serde_json::from_str(payload) {
        Ok(value) => value,
        Err(err) => return rpc_error(&Value::Null, -32700, &format!("parse error: {err}")),
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    match method {
        "initialize" => rpc_result(
            &id,
            json!({"protocolVersion":"2025-03-26","serverInfo":{"name":"magicnet","version":"1.0.0"},"capabilities":{"tools":{}}}),
        ),
        "tools/list" => rpc_result(
            &id,
            serde_json::from_str(TOOLS_JSON).unwrap_or_else(|_| json!({"tools": []})),
        ),
        "tools/call" => {
            let tool = request
                .pointer("/params/name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let args = request.pointer("/params/arguments").unwrap_or(&Value::Null);
            let result = call_tool(tool, args, server);
            rpc_result(&id, text_content(&result))
        }
        "notifications/initialized" => rpc_result(&id, json!({})),
        _ => rpc_error(&id, -32601, "method not found"),
    }
}

fn call_tool(tool: &str, args: &Value, server: &Server) -> String {
    match tool {
        "magicnet_status" => run_cli(server, &["service", "status"]),
        "magicnet_cli" => cli_args(server, args),
        "magicnet_service_control" => service_control(server, args),
        "magicnet_core_select" => run_cli_owned(
            server,
            vec![
                "core".into(),
                "select".into(),
                arg(args, "core").unwrap_or_else(|| "sing-box".to_string()),
            ],
        ),
        "magicnet_config_apply" => run_cli(server, &["config", "apply"]),
        "magicnet_config_get" => run_cli_owned(
            server,
            vec![
                "config-editor".into(),
                "get".into(),
                arg(args, "target").unwrap_or_else(|| "sing-box".to_string()),
            ],
        ),
        "magicnet_config_validate" => config_validate(server, args),
        "magicnet_config_sync_template" => run_cli_owned(
            server,
            vec![
                "config-editor".into(),
                "sync-template".into(),
                arg(args, "target").unwrap_or_else(|| "sing-box".to_string()),
            ],
        ),
        "magicnet_config_save_base64" => run_cli_owned(
            server,
            vec![
                "config-editor".into(),
                "save".into(),
                arg(args, "target").unwrap_or_else(|| "sing-box".to_string()),
                arg(args, "content_base64").unwrap_or_default(),
            ],
        ),
        "magicnet_transparent_set" => run_cli_owned(
            server,
            vec![
                "transparent".into(),
                "set".into(),
                arg(args, "mode").unwrap_or_else(|| "tun".to_string()),
            ],
        ),
        "magicnet_transparent_apply" => run_cli(server, &["transparent", "apply"]),
        "magicnet_health" => run_cli(server, &["health"]),
        "magicnet_block_list" => run_cli(server, &["block", "list"]),
        "magicnet_block_set_enabled" => run_cli(
            server,
            &[
                "block",
                if arg_bool(args, "enabled").unwrap_or(true) {
                    "enable"
                } else {
                    "disable"
                },
            ],
        ),
        "magicnet_block_set_community" => run_cli(
            server,
            &[
                "block",
                "community",
                if arg_bool(args, "enabled").unwrap_or(true) {
                    "on"
                } else {
                    "off"
                },
            ],
        ),
        "magicnet_block_update" => run_cli(server, &["block", "update"]),
        "magicnet_block_add_domain" => block_domain(server, args, "add-domain"),
        "magicnet_block_remove_domain" => block_domain(server, args, "remove-domain"),
        "magicnet_block_allow_rule" => block_rule(server, args, "allow-rule"),
        "magicnet_block_unallow_rule" => block_rule(server, args, "unallow-rule"),
        "magicnet_block_diff" => run_cli(server, &["block", "diff"]),
        "magicnet_block_apply" => run_cli(server, &["block", "apply"]),
        "magicnet_subscription_list" => run_cli(server, &["sub", "list"]),
        "magicnet_subscription_set" => subscription_set(server, args),
        "magicnet_subscription_set_singbox_lines" => subscription_set_singbox_lines(server, args),
        "magicnet_subscription_update" => run_cli_owned(
            server,
            vec![
                "sub".into(),
                "update".into(),
                arg(args, "target").unwrap_or_else(|| "all".to_string()),
            ],
        ),
        "magicnet_subscription_update_all" => run_cli(server, &["sub", "update-all"]),
        "magicnet_backup_export" => backup_export(server, args),
        "magicnet_backup_restore_base64" => run_cli_owned(
            server,
            vec![
                "backup".into(),
                "restore".into(),
                arg(args, "password").unwrap_or_else(|| "-".to_string()),
                arg(args, "content_base64").unwrap_or_default(),
            ],
        ),
        "magicnet_pingtest" => run_cli(server, &["pingtest"]),
        "magicnet_speedtest" => run_cli(server, &["speedtest"]),
        "magicnet_topology" => run_cli(server, &["topology"]),
        "magicnet_sysroute_snapshot" => run_cli(server, &["sysroute", "snapshot"]),
        "magicnet_ecapture_status" => run_cli(server, &["ecapture", "status"]),
        "magicnet_ecapture_help" => run_cli_owned(
            server,
            vec![
                "ecapture".into(),
                "help".into(),
                arg(args, "command").unwrap_or_else(|| "tls".to_string()),
            ],
        ),
        "magicnet_ecapture_tls" => ecapture_text(server, args, "tls"),
        "magicnet_ecapture_gotls" => ecapture_text(server, args, "gotls"),
        "magicnet_ecapture_pcap" => ecapture_pcap(server, args),
        "magicnet_support_bundle" => run_cli(server, &["support", "bundle"]),
        "magicnet_app_list" => run_cli(server, &["app", "list"]),
        "magicnet_app_packages" => run_cli_owned(
            server,
            vec![
                "app".into(),
                "packages".into(),
                arg(args, "query").unwrap_or_default(),
            ],
        ),
        "magicnet_app_mode" => run_cli_owned(
            server,
            vec![
                "app".into(),
                "mode".into(),
                arg(args, "mode").unwrap_or_else(|| "blacklist".to_string()),
            ],
        ),
        "magicnet_app_add" => app_package(server, args, "add"),
        "magicnet_app_add_many" => app_add_many(server, args),
        "magicnet_app_remove" => app_package(server, args, "remove"),
        "magicnet_app_apply" => run_cli(server, &["app", "apply"]),
        "magicnet_mcp_control" => run_cli_owned(
            server,
            vec![
                "mcp".into(),
                arg(args, "action").unwrap_or_else(|| "status".to_string()),
            ],
        ),
        "magicnet_api" => run_cli_owned(
            server,
            vec![
                "api".into(),
                arg(args, "action").unwrap_or_else(|| "groups".to_string()),
            ],
        ),
        "magicnet_webui_status" => run_cli(server, &["webui", "status"]),
        "magicnet_webui_verify" => run_cli(server, &["webui", "verify"]),
        "magicnet_webui_install_local" => run_cli_owned(
            server,
            vec![
                "webui".into(),
                "install-local".into(),
                arg(args, "url").unwrap_or_default(),
                arg(args, "sha256").unwrap_or_default(),
                arg(args, "name").unwrap_or_else(|| "custom".to_string()),
            ],
        ),
        "magicnet_log_list" => log_list(server),
        "magicnet_log_read" => log_read(
            server,
            arg(args, "source").as_deref().unwrap_or("mcp"),
            arg_usize(args, "lines").unwrap_or(200),
            arg_bool(args, "redact").unwrap_or(true),
        ),
        "magicnet_debug_snapshot" => {
            debug_snapshot(server, arg_usize(args, "lines").unwrap_or(120))
        }
        "magicnet_file_list" => file_list(server, arg(args, "path").as_deref().unwrap_or(".")),
        "magicnet_file_read" => file_read(server, arg(args, "path").as_deref().unwrap_or("")),
        _ => "unknown tool".to_string(),
    }
}

pub(crate) fn run_cli(server: &Server, args: &[&str]) -> String {
    let output = Command::new(&server.cli).args(args).output();
    match output {
        Ok(output) => {
            let mut text = String::new();
            text.push_str(&String::from_utf8_lossy(&output.stdout));
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            text.push_str(&format!("\nrc={}", output.status.code().unwrap_or(-1)));
            text
        }
        Err(err) => format!("failed to run cli: {err}"),
    }
}

fn subscription_set(server: &Server, args: &Value) -> String {
    let target = arg(args, "target").unwrap_or_else(|| "sing-box".to_string());
    let url = arg(args, "url").unwrap_or_default();
    if url.trim().is_empty() {
        return "missing url".to_string();
    }
    if !matches!(target.as_str(), "sing-box" | "singbox") {
        return "unsupported subscription target; use sing-box".to_string();
    }
    run_cli_owned(server, vec!["sub".into(), "set".into(), target, url])
}

fn subscription_set_singbox_lines(server: &Server, args: &Value) -> String {
    let content = arg(args, "content").unwrap_or_default();
    let encoded = encode_base64(content.as_bytes());
    run_cli_owned(
        server,
        vec!["sub".into(), "set-file".into(), "sing-box".into(), encoded],
    )
}

fn backup_export(server: &Server, args: &Value) -> String {
    match arg(args, "password") {
        Some(password) if !password.is_empty() => {
            run_cli_owned(server, vec!["backup".into(), "export".into(), password])
        }
        _ => run_cli(server, &["backup", "export"]),
    }
}

fn ecapture_text(server: &Server, args: &Value, command: &str) -> String {
    run_cli_owned(
        server,
        vec![
            "ecapture".into(),
            command.into(),
            bounded_duration(args).to_string(),
            arg(args, "pid").unwrap_or_else(|| "all".to_string()),
            arg(args, "uid").unwrap_or_else(|| "all".to_string()),
        ],
    )
}

fn ecapture_pcap(server: &Server, args: &Value) -> String {
    let mut values = vec![
        "ecapture".to_string(),
        "pcap".to_string(),
        bounded_duration(args).to_string(),
        arg(args, "ifname").unwrap_or_else(|| "wlan0".to_string()),
    ];
    if let Some(filter) = arg(args, "filter") {
        values.extend(filter.split_whitespace().take(32).map(ToOwned::to_owned));
    }
    run_cli_owned(server, values)
}

fn bounded_duration(args: &Value) -> usize {
    arg_usize(args, "duration_seconds")
        .unwrap_or(15)
        .clamp(1, 60)
}

fn run_cli_owned(server: &Server, args: Vec<String>) -> String {
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    run_cli(server, &refs)
}

fn cli_args(server: &Server, args: &Value) -> String {
    let Some(values) = args.get("args").and_then(Value::as_array) else {
        return "missing args array".to_string();
    };
    let mut out = Vec::new();
    for value in values.iter().take(24) {
        let Some(item) = value.as_str() else {
            return "args must be strings".to_string();
        };
        if item.contains('\0') {
            return "invalid arg".to_string();
        }
        out.push(item.to_string());
    }
    if out.is_empty() {
        return "missing args".to_string();
    }
    run_cli_owned(server, out)
}

fn service_control(server: &Server, args: &Value) -> String {
    let action = arg(args, "action").unwrap_or_else(|| "status".to_string());
    let target = arg(args, "target");
    match target {
        Some(target) if !target.is_empty() => {
            run_cli_owned(server, vec!["service".into(), action, target])
        }
        _ => run_cli_owned(server, vec!["service".into(), action]),
    }
}

fn config_validate(server: &Server, args: &Value) -> String {
    match arg(args, "target").as_deref().unwrap_or("all") {
        "all" => {
            let singbox = run_cli(server, &["config-editor", "validate", "sing-box"]);
            format!("## sing-box\n{singbox}")
        }
        target => run_cli_owned(
            server,
            vec![
                "config-editor".into(),
                "validate".into(),
                target.to_string(),
            ],
        ),
    }
}

fn block_domain(server: &Server, args: &Value, action: &str) -> String {
    run_cli_owned(
        server,
        vec![
            "block".into(),
            action.into(),
            arg(args, "suffix").unwrap_or_default(),
        ],
    )
}

fn block_rule(server: &Server, args: &Value, action: &str) -> String {
    run_cli_owned(
        server,
        vec![
            "block".into(),
            action.into(),
            arg(args, "rule").unwrap_or_default(),
        ],
    )
}

fn app_package(server: &Server, args: &Value, action: &str) -> String {
    let mut values = vec![
        "app".to_string(),
        action.to_string(),
        arg(args, "package").unwrap_or_default(),
    ];
    if let Some(target) = arg(args, "target") {
        values.push(target);
    }
    run_cli_owned(server, values)
}

fn app_add_many(server: &Server, args: &Value) -> String {
    let target = arg(args, "target").unwrap_or_else(|| "bypass".to_string());
    let Some(packages) = args.get("packages").and_then(Value::as_array) else {
        return "missing packages array".to_string();
    };
    let mut values = vec!["app".to_string(), "add-many".to_string(), target];
    for package in packages.iter().take(200) {
        let Some(package) = package.as_str() else {
            return "packages must be strings".to_string();
        };
        values.push(package.to_string());
    }
    run_cli_owned(server, values)
}

fn arg(args: &Value, key: &str) -> Option<String> {
    args.get(key).and_then(Value::as_str).map(ToOwned::to_owned)
}

fn arg_usize(args: &Value, key: &str) -> Option<usize> {
    args.get(key)
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
}

fn arg_bool(args: &Value, key: &str) -> Option<bool> {
    args.get(key).and_then(Value::as_bool)
}

fn rpc_result(id: &Value, result: Value) -> String {
    json!({"jsonrpc":"2.0","id":id,"result":result}).to_string()
}

fn rpc_error(id: &Value, code: i32, message: &str) -> String {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}}).to_string()
}

fn text_content(text: &str) -> Value {
    json!({"content":[{"type":"text","text":text}]})
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use serde_json::{json, Value};

    use super::{handle_jsonrpc, Server};

    #[test]
    fn speedtest_tool_call_runs_only_speedtest_cli_argv() {
        let server = Server {
            moddir: PathBuf::from("/tmp"),
            cli: PathBuf::from("/bin/echo"),
            secret: String::new(),
        };
        let payload = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "magicnet_speedtest", "arguments": {}}
        })
        .to_string();
        let response: Value = serde_json::from_str(&handle_jsonrpc(&payload, &server))
            .expect("RPC response must be valid JSON");

        assert_eq!(
            response
                .pointer("/result/content/0/text")
                .and_then(Value::as_str),
            Some("speedtest\n\nrc=0")
        );
    }

    #[test]
    fn removed_generic_write_tools_are_rejected() {
        let server = Server {
            moddir: PathBuf::from("/tmp"),
            cli: PathBuf::from("/bin/echo"),
            secret: String::new(),
        };

        for tool in [
            "magicnet_file_write",
            "magicnet_file_write_base64",
            "magicnet_file_chmod",
            "magicnet_dir_make",
            "magicnet_webui_build",
            "magicnet_download_to_downloads",
        ] {
            let payload = json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": tool, "arguments": {}}
            })
            .to_string();
            let response: Value = serde_json::from_str(&handle_jsonrpc(&payload, &server))
                .expect("RPC response must be valid JSON");

            assert_eq!(
                response
                    .pointer("/result/content/0/text")
                    .and_then(Value::as_str),
                Some("unknown tool"),
                "{tool} must remain unavailable"
            );
        }
    }
}
