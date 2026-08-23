use serde_json::{json, Value};
use std::io::{self, Read};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

use crate::files::{file_list, file_read};
use crate::logs::{debug_snapshot, log_list, log_read};
use crate::tools::TOOLS_JSON;
use crate::Server;
use base64::{engine::general_purpose::STANDARD, Engine as _};

const CLI_TIMEOUT: Duration = Duration::from_secs(300);
const MAX_CLI_STREAM_BYTES: usize = 1024 * 1024;
type CliStreamResult = io::Result<(Vec<u8>, bool)>;
type CliStreamReceiver = Receiver<CliStreamResult>;

pub(crate) fn handle_jsonrpc(payload: &str, server: &Server) -> String {
    let request: Value = match serde_json::from_str(payload) {
        Ok(value) => value,
        Err(err) => return rpc_error(&Value::Null, -32700, &format!("parse error: {err}")),
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    if !request.is_object() || request.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return rpc_error(&id, -32600, "invalid request");
    }
    let Some(method) = request.get("method").and_then(Value::as_str) else {
        return rpc_error(&id, -32600, "invalid request");
    };
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
        _ => "unknown tool\nrc=-1".to_string(),
    }
}

pub(crate) fn run_cli(server: &Server, args: &[&str]) -> String {
    run_cli_with_timeout(server, args, CLI_TIMEOUT)
}

fn run_cli_with_timeout(server: &Server, args: &[&str], timeout: Duration) -> String {
    let mut command = Command::new(&server.cli);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        });
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => return format!("failed to run cli: {err}\nrc=-1"),
    };
    let stdout = child.stdout.take().map(spawn_cli_reader);
    let stderr = child.stderr.take().map(spawn_cli_reader);
    let started = Instant::now();
    let (status, timed_out, wait_error) = loop {
        match child.try_wait() {
            Ok(Some(status)) => break (Some(status), false, None),
            Ok(None) if started.elapsed() < timeout => thread::sleep(Duration::from_millis(25)),
            Ok(None) => break (terminate_cli_group(&mut child), true, None),
            Err(err) => {
                let _ = terminate_cli_group(&mut child);
                break (None, false, Some(err));
            }
        }
    };

    let mut text = String::new();
    append_cli_stream(&mut text, "stdout", stdout);
    append_cli_stream(&mut text, "stderr", stderr);
    if timed_out {
        text.push_str("\ncli timed out");
    }
    if let Some(error) = wait_error {
        text.push_str(&format!("\nwait for cli failed: {error}"));
    }
    let code = if timed_out {
        124
    } else {
        status.and_then(|value| value.code()).unwrap_or(-1)
    };
    text.push_str(&format!("\nrc={code}"));
    text
}

fn terminate_cli_group(child: &mut Child) -> Option<ExitStatus> {
    let group = -(child.id() as libc::pid_t);
    unsafe {
        libc::kill(group, libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_millis(250);
    while Instant::now() < deadline {
        if let Ok(Some(status)) = child.try_wait() {
            unsafe {
                libc::kill(group, libc::SIGKILL);
            }
            return Some(status);
        }
        thread::sleep(Duration::from_millis(20));
    }
    unsafe {
        libc::kill(group, libc::SIGKILL);
    }
    child.wait().ok()
}

fn drain_cli_stream(mut pipe: impl Read) -> CliStreamResult {
    let mut retained = Vec::new();
    let mut buffer = [0_u8; 8192];
    let mut truncated = false;
    loop {
        let read = pipe.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        let available = MAX_CLI_STREAM_BYTES.saturating_sub(retained.len());
        let keep = read.min(available);
        retained.extend_from_slice(&buffer[..keep]);
        truncated |= keep < read;
    }
    Ok((retained, truncated))
}

fn spawn_cli_reader(pipe: impl Read + Send + 'static) -> CliStreamReceiver {
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let _ = sender.send(drain_cli_stream(pipe));
    });
    receiver
}

fn append_cli_stream(text: &mut String, name: &str, reader: Option<CliStreamReceiver>) {
    match reader.and_then(|reader| reader.recv_timeout(Duration::from_secs(2)).ok()) {
        Some(Ok((bytes, truncated))) => {
            text.push_str(&String::from_utf8_lossy(&bytes));
            if truncated {
                text.push_str(&format!("\n[{name} truncated]"));
            }
        }
        Some(Err(err)) => text.push_str(&format!("\n[{name} read failed: {err}]")),
        None => text.push_str(&format!("\n[{name} unavailable]")),
    }
}

fn subscription_set(server: &Server, args: &Value) -> String {
    let target = arg(args, "target").unwrap_or_else(|| "sing-box".to_string());
    let url = arg(args, "url").unwrap_or_default();
    if url.trim().is_empty() {
        return "missing url\nrc=-1".to_string();
    }
    if !matches!(target.as_str(), "sing-box" | "singbox") {
        return "unsupported subscription target; use sing-box\nrc=-1".to_string();
    }
    run_cli_owned(server, vec!["sub".into(), "set".into(), target, url])
}

fn subscription_set_singbox_lines(server: &Server, args: &Value) -> String {
    let content = arg(args, "content").unwrap_or_default();
    let encoded = STANDARD.encode(content.as_bytes());
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
        return "missing args array\nrc=-1".to_string();
    };
    if values.len() > 24 {
        return "too many args\nrc=-1".to_string();
    }
    let mut out = Vec::new();
    for value in values {
        let Some(item) = value.as_str() else {
            return "args must be strings\nrc=-1".to_string();
        };
        if item.contains('\0') {
            return "invalid arg\nrc=-1".to_string();
        }
        out.push(item.to_string());
    }
    if out.is_empty() {
        return "missing args\nrc=-1".to_string();
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
        return "missing packages array\nrc=-1".to_string();
    };
    if packages.len() > 200 {
        return "too many packages\nrc=-1".to_string();
    }
    let mut values = vec!["app".to_string(), "add-many".to_string(), target];
    for package in packages {
        let Some(package) = package.as_str() else {
            return "packages must be strings\nrc=-1".to_string();
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
    let is_error = text
        .lines()
        .last()
        .and_then(|line| line.strip_prefix("rc="))
        .and_then(|value| value.parse::<i32>().ok())
        .is_some_and(|code| code != 0);
    if is_error {
        json!({"content":[{"type":"text","text":text}],"isError":true})
    } else {
        json!({"content":[{"type":"text","text":text}]})
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use serde_json::{json, Value};

    use super::{handle_jsonrpc, run_cli_with_timeout, Server};

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
        assert_eq!(response.pointer("/result/isError"), None);
    }

    #[test]
    fn nonzero_cli_exit_is_an_mcp_tool_error() {
        let server = Server {
            moddir: PathBuf::from("/tmp"),
            cli: PathBuf::from("/bin/false"),
            secret: String::new(),
        };
        let payload = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "magicnet_status", "arguments": {}}
        })
        .to_string();
        let response: Value = serde_json::from_str(&handle_jsonrpc(&payload, &server))
            .expect("RPC response must be valid JSON");

        assert_eq!(
            response.pointer("/result/isError").and_then(Value::as_bool),
            Some(true)
        );
        assert_eq!(
            response
                .pointer("/result/content/0/text")
                .and_then(Value::as_str),
            Some("\nrc=1")
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
                Some("unknown tool\nrc=-1"),
                "{tool} must remain unavailable"
            );
            assert_eq!(
                response.pointer("/result/isError").and_then(Value::as_bool),
                Some(true),
                "{tool} must report an MCP tool error"
            );
        }
    }

    #[test]
    fn cli_timeout_terminates_background_children() {
        let directory = std::env::temp_dir().join(format!(
            "magicnet-mcp-process-group-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&directory).unwrap();
        let pid_file = directory.join("child.pid");
        let script = format!(
            "sh -c 'trap \"\" TERM; printf \"%s\\\\n\" \"$$\" > \"{}\"; while :; do sleep 1; done' & wait",
            pid_file.display()
        );
        let server = Server {
            moddir: directory.clone(),
            cli: PathBuf::from("/bin/sh"),
            secret: String::new(),
        };
        let output = run_cli_with_timeout(&server, &["-c", &script], Duration::from_millis(300));
        assert!(output.ends_with("rc=124"), "{output}");
        let pid = fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse::<libc::pid_t>()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && unsafe { libc::kill(pid, 0) } == 0 {
            std::thread::sleep(Duration::from_millis(20));
        }
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        if alive {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
        assert!(!alive, "background child survived MCP CLI timeout: {pid}");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn invalid_jsonrpc_envelope_is_rejected_before_dispatch() {
        let server = Server {
            moddir: PathBuf::from("/tmp"),
            cli: PathBuf::from("/bin/echo"),
            secret: String::new(),
        };
        let response: Value = serde_json::from_str(&handle_jsonrpc(
            r#"{"id":1,"method":"tools/list"}"#,
            &server,
        ))
        .unwrap();
        assert_eq!(
            response.pointer("/error/code").and_then(Value::as_i64),
            Some(-32600)
        );
    }
}
