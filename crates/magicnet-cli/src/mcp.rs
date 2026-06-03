use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use crate::{read_kv, App};

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
            }
            Ok(())
        }
        "enable" => {
            let (_, bind, port) = load(app);
            write_conf(app, "1", &bind, &port)?;
            start(app)
        }
        "disable" => {
            let (_, bind, port) = load(app);
            write_conf(app, "0", &bind, &port)?;
            stop(app)
        }
        "start" => start(app),
        "stop" => stop(app),
        "restart" => {
            let _ = stop(app);
            start(app)
        }
        _ => Err("Usage: cli mcp {status|enable|disable|start|stop|restart}".to_string()),
    }
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
        conf.get("MAGICNET_MCP_ENABLED").cloned().unwrap_or_else(|| "0".to_string()),
        conf.get("MAGICNET_MCP_BIND").cloned().unwrap_or_else(|| "127.0.0.1".to_string()),
        conf.get("MAGICNET_MCP_PORT").cloned().unwrap_or_else(|| "8765".to_string()),
    )
}

fn write_conf(app: &App, enabled: &str, bind: &str, port: &str) -> Result<(), String> {
    let path = conf_path(app);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    fs::write(
        path,
        format!("MAGICNET_MCP_ENABLED={enabled}\nMAGICNET_MCP_BIND={bind}\nMAGICNET_MCP_PORT={port}\n"),
    )
    .map_err(|err| format!("write mcp.conf: {err}"))
}

fn start(app: &App) -> Result<(), String> {
    let (_, bind, port) = load(app);
    if let Some(pid) = live_pid(pid_path(app)) {
        println!("[info] MCP server already running: {pid}");
        return mcp(app, &[String::from("status")]);
    }
    let target = app.moddir.join(".local/bin/magicnet-mcp-server");
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
    let log_err = log.try_clone().map_err(|err| format!("clone mcp log: {err}"))?;
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
    Path::new("/proc").join(pid.to_string()).exists().then_some(pid)
}
