use std::env;
use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use crate::{read_kv, App};

const DEFAULT_BIND: &str = "127.0.0.1";
const DEFAULT_PORT: &str = "8766";

pub(crate) fn mcp(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            let (enabled, bind, port) = load(app);
            println!("enabled={enabled}");
            println!("bind={bind}");
            println!("port={port}");
            if let Some(pid) = live_pid(pid_path(app)) {
                println!("pid={pid}");
                println!("url=http://{bind}:{port}/mcp");
            } else {
                println!("pid=stopped");
                if let Some(owner) = port_owner(&bind, &port) {
                    println!("port_owner={owner}");
                }
            }
            Ok(())
        }
        "enable" => {
            let (_, current_bind, current_port) = load(app);
            let bind = args.get(1).map(String::as_str).unwrap_or(&current_bind);
            let port = args.get(2).map(String::as_str).unwrap_or(&current_port);
            validate_port(port)?;
            write_conf(app, "1", &bind, &port)?;
            start(app)
        }
        "disable" => {
            let (_, bind, port) = load(app);
            write_conf(app, "0", &bind, &port)?;
            stop(app)
        }
        "set" => {
            let (enabled, current_bind, current_port) = load(app);
            let bind = args.get(1).map(String::as_str).unwrap_or(&current_bind);
            let port = args.get(2).map(String::as_str).unwrap_or(&current_port);
            validate_port(port)?;
            write_conf(app, &enabled, bind, port)?;
            println!("[info] MCP endpoint set: http://{bind}:{port}/mcp");
            Ok(())
        }
        "start" => start(app),
        "stop" => stop(app),
        "restart" => {
            let _ = stop(app);
            start(app)
        }
        "logs" => {
            let lines = args
                .get(1)
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(120);
            print_log_tail(app, "mcp-server.log", lines)
        }
        _ => Err("Usage: cli mcp {status|enable [bind] [port]|disable|set [bind] [port]|start|stop|restart|logs [lines]}".to_string()),
    }
}

pub(crate) fn status(app: &App) -> (String, String, String, String) {
    let (enabled, bind, port) = load(app);
    let pid = live_pid(pid_path(app))
        .map(|value| value.to_string())
        .unwrap_or_else(|| "stopped".to_string());
    (enabled, bind, port, pid)
}

fn conf_path(app: &App) -> PathBuf {
    app.moddir.join(".config/magicnet/mcp.conf")
}

fn pid_path(app: &App) -> PathBuf {
    env::var("KAM_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| app.moddir.clone())
        .join(".state/magicnet-mcp.pid")
}

fn load(app: &App) -> (String, String, String) {
    let conf = read_kv(conf_path(app));
    (
        conf.get("MAGICNET_MCP_ENABLED")
            .cloned()
            .unwrap_or_else(|| "0".to_string()),
        conf.get("MAGICNET_MCP_BIND")
            .cloned()
            .unwrap_or_else(|| DEFAULT_BIND.to_string()),
        conf.get("MAGICNET_MCP_PORT")
            .cloned()
            .unwrap_or_else(|| DEFAULT_PORT.to_string()),
    )
}

fn write_conf(app: &App, enabled: &str, bind: &str, port: &str) -> Result<(), String> {
    let path = conf_path(app);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    fs::write(
        path,
        format!(
            "MAGICNET_MCP_ENABLED={enabled}\nMAGICNET_MCP_BIND={bind}\nMAGICNET_MCP_PORT={port}\n"
        ),
    )
    .map_err(|err| format!("write mcp.conf: {err}"))
}

fn start(app: &App) -> Result<(), String> {
    let (_, bind, port) = load(app);
    if let Some(pid) = live_pid(pid_path(app)) {
        println!("[info] MCP server already running: {pid}");
        return mcp(app, &[String::from("status")]);
    }
    if let Err(err) = TcpListener::bind(format!("{bind}:{port}")) {
        let owner = port_owner(&bind, &port).unwrap_or_else(|| "unknown owner".to_string());
        return Err(format!(
            "MCP port unavailable: {bind}:{port}: {err}; {owner}"
        ));
    }
    let target = app.moddir.join("bin/magicnet-mcp-server");
    if !target.exists() {
        return Err(format!("MCP server missing: {}", target.display()));
    }
    fs::create_dir_all(app.log_dir.clone()).map_err(|err| format!("mkdir log dir: {err}"))?;
    if let Some(parent) = pid_path(app).parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir state dir: {err}"))?;
    }
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(app.log_dir.join("mcp-server.log"))
        .map_err(|err| format!("open mcp log: {err}"))?;
    let log_err = log
        .try_clone()
        .map_err(|err| format!("clone mcp log: {err}"))?;
    let child = Command::new(&target)
        .env("MODDIR", &app.moddir)
        .env("MAGICNET_MCP_BIND", &bind)
        .env("MAGICNET_MCP_PORT", &port)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
        .map_err(|err| format!("start MCP server: {err}"))?;
    let pid = child.id();
    fs::write(pid_path(app), format!("{pid}\n")).map_err(|err| format!("write pid: {err}"))?;
    thread::sleep(Duration::from_millis(350));
    if Path::new("/proc").join(pid.to_string()).exists() {
        println!("[info] MCP server started: http://{bind}:{port}/mcp");
        Ok(())
    } else {
        Err(format!(
            "MCP server failed to start; see {}",
            app.log_dir.join("mcp-server.log").display()
        ))
    }
}

fn stop(app: &App) -> Result<(), String> {
    if let Some(pid) = live_pid(pid_path(app)) {
        let _ = Command::new("kill").arg(pid.to_string()).status();
        thread::sleep(Duration::from_millis(250));
        if Path::new("/proc").join(pid.to_string()).exists() {
            let _ = Command::new("kill").arg("-9").arg(pid.to_string()).status();
        }
    }
    let _ = fs::remove_file(pid_path(app));
    println!("[info] MCP server stopped");
    Ok(())
}

fn live_pid(pid_file: PathBuf) -> Option<i32> {
    let text = fs::read_to_string(pid_file).ok()?;
    let pid = text.trim().parse::<i32>().ok()?;
    let proc_dir = Path::new("/proc").join(pid.to_string());
    if !proc_dir.exists() {
        return None;
    }
    let cmdline = fs::read(proc_dir.join("cmdline")).unwrap_or_default();
    let cmdline = String::from_utf8_lossy(&cmdline).replace('\0', " ");
    if cmdline.contains("magicnet-mcp-server") {
        return Some(pid);
    }
    let exe = fs::read_link(proc_dir.join("exe"))
        .ok()
        .map(|path| path.display().to_string())
        .unwrap_or_default();
    exe.contains("magicnet-mcp-server").then_some(pid)
}

fn validate_port(port: &str) -> Result<(), String> {
    match port.parse::<u16>() {
        Ok(0) | Err(_) => Err(format!("invalid MCP port: {port}")),
        Ok(_) => Ok(()),
    }
}

fn port_owner(bind: &str, port: &str) -> Option<String> {
    let output = Command::new("ss").arg("-lntp").output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let needle = format!(":{port}");
    text.lines()
        .find(|line| {
            line.contains(&needle)
                && (line.contains(bind) || bind == "0.0.0.0" || line.contains("0.0.0.0"))
        })
        .map(|line| line.trim().to_string())
}

fn print_log_tail(app: &App, file_name: &str, lines: usize) -> Result<(), String> {
    let file = app.log_dir.join(file_name);
    let text = fs::read_to_string(&file)
        .map_err(|err| format!("log not found {}: {err}", file.display()))?;
    let lines = lines.clamp(1, 1000);
    let all = text.lines().collect::<Vec<_>>();
    let start = all.len().saturating_sub(lines);
    for line in &all[start..] {
        println!("{line}");
    }
    Ok(())
}
