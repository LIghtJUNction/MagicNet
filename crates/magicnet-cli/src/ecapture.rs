use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::{command_text_timeout, App, SHORT_TIMEOUT};

const DEFAULT_CAPTURE_SECONDS: u64 = 15;
const MAX_CAPTURE_SECONDS: u64 = 300;

pub(crate) fn ecapture_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => status(app),
        "version" => version(app),
        "help" => help(app, args.get(1).map(String::as_str)),
        "tls" => text_capture(app, "tls", &args[1..]),
        "gotls" => text_capture(app, "gotls", &args[1..]),
        "nspr" => text_capture(app, "nspr", &args[1..]),
        "pcap" => pcap_capture(app, &args[1..]),
        _ => Err(usage()),
    }
}

fn status(app: &App) -> Result<(), String> {
    let bin = bin_path(app);
    println!("eCapture status");
    println!("binary={}", bin.display());
    println!("installed={}", if bin.is_file() { "yes" } else { "no" });
    println!(
        "executable={}",
        if is_executable(&bin) { "yes" } else { "no" }
    );
    println!("logs={}", app.log_dir.display());
    println!(
        "kernel={}",
        command_text_timeout("uname", &["-a"], SHORT_TIMEOUT)
    );
    println!(
        "bpffs={}",
        if Path::new("/sys/fs/bpf").is_dir() {
            "present"
        } else {
            "missing"
        }
    );
    if is_executable(&bin) {
        print_command_output(run_with_timeout(
            &bin,
            &["--version"],
            Duration::from_secs(2),
        ));
    }
    Ok(())
}

fn version(app: &App) -> Result<(), String> {
    let bin = require_bin(app)?;
    let outcome = run_with_timeout(&bin, &["--version"], Duration::from_secs(3));
    print_command_output(outcome);
    Ok(())
}

fn help(app: &App, command: Option<&str>) -> Result<(), String> {
    let bin = require_bin(app)?;
    let outcome = match command {
        Some(command) if matches!(command, "tls" | "gotls" | "nspr") => {
            run_with_timeout(&bin, &[command, "--help"], Duration::from_secs(3))
        }
        Some("pcap") => run_with_timeout(&bin, &["tls", "--help"], Duration::from_secs(3)),
        _ => run_with_timeout(&bin, &["--help"], Duration::from_secs(3)),
    };
    print_command_output(outcome);
    Ok(())
}

fn text_capture(app: &App, command: &str, args: &[String]) -> Result<(), String> {
    let bin = require_bin(app)?;
    let seconds = parse_seconds(args.first().map(String::as_str))?;
    let pid = numeric_or_all(args.get(1).map(String::as_str), "pid")?;
    let uid = numeric_or_all(args.get(2).map(String::as_str), "uid")?;
    fs::create_dir_all(&app.log_dir)
        .map_err(|err| format!("mkdir {}: {err}", app.log_dir.display()))?;
    let log = app.log_dir.join(format!("ecapture-{command}.log"));
    let events = app.log_dir.join(format!("ecapture-{command}-events.log"));
    let log_arg = log.to_string_lossy().to_string();
    let event_arg = events.to_string_lossy().to_string();
    let pid_arg = format!("--pid={pid}");
    let uid_arg = format!("--uid={uid}");
    let capture_args = [
        command,
        "-l",
        &log_arg,
        "--eventaddr",
        &event_arg,
        "--tsize=4096",
        &pid_arg,
        &uid_arg,
    ];
    println!("running ecapture {command} for {seconds}s (pid={pid}, uid={uid})");
    let outcome = run_with_timeout(&bin, &capture_args, Duration::from_secs(seconds));
    print_command_output(outcome.clone());
    println!("log={}", log.display());
    println!("events={}", events.display());
    finish_capture(outcome)
}

fn pcap_capture(app: &App, args: &[String]) -> Result<(), String> {
    let bin = require_bin(app)?;
    let parsed = parse_pcap_args(args)?;
    fs::create_dir_all(&app.log_dir)
        .map_err(|err| format!("mkdir {}: {err}", app.log_dir.display()))?;
    let pcap = app.log_dir.join("ecapture.pcapng");
    let log = app.log_dir.join("ecapture-pcap.log");
    let pcap_arg = pcap.to_string_lossy().to_string();
    let log_arg = log.to_string_lossy().to_string();
    let ifname = parsed.ifname;
    let mut capture_args = vec![
        "tls".to_string(),
        "-m".to_string(),
        "pcap".to_string(),
        "-i".to_string(),
        ifname.clone(),
        "-w".to_string(),
        pcap_arg,
        "-l".to_string(),
        log_arg,
    ];
    capture_args.extend(parsed.filter.into_iter().take(32));
    let refs: Vec<&str> = capture_args.iter().map(String::as_str).collect();
    println!(
        "running ecapture pcap for {}s (ifname={})",
        parsed.seconds, ifname
    );
    let outcome = run_with_timeout(&bin, &refs, Duration::from_secs(parsed.seconds));
    print_command_output(outcome.clone());
    println!("pcap={}", pcap.display());
    println!("log={}", log.display());
    finish_capture(outcome)
}

#[derive(Debug)]
struct PcapArgs {
    seconds: u64,
    ifname: String,
    filter: Vec<String>,
}

fn parse_pcap_args(args: &[String]) -> Result<PcapArgs, String> {
    let usage = "Usage: cli ecapture pcap [seconds] <ifname> [pcap-filter ...]".to_string();
    let Some(first) = args
        .first()
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
    else {
        return Err(usage);
    };
    if let Ok(seconds) = first.parse::<u64>() {
        let ifname = args
            .get(1)
            .map(String::as_str)
            .filter(|value| !value.trim().is_empty())
            .ok_or(usage)?;
        return Ok(PcapArgs {
            seconds: seconds.clamp(1, MAX_CAPTURE_SECONDS),
            ifname: ifname.to_string(),
            filter: args.iter().skip(2).cloned().collect(),
        });
    }
    Ok(PcapArgs {
        seconds: DEFAULT_CAPTURE_SECONDS,
        ifname: first.to_string(),
        filter: args.iter().skip(1).cloned().collect(),
    })
}

fn finish_capture(outcome: RunOutcome) -> Result<(), String> {
    if outcome.timed_out {
        println!("capture stopped after timeout");
        return Ok(());
    }
    match outcome.code {
        Some(0) => Ok(()),
        Some(code) => Err(format!("ecapture exited with status {code}")),
        None => Err("ecapture terminated by signal".to_string()),
    }
}

fn parse_seconds(value: Option<&str>) -> Result<u64, String> {
    let Some(value) = value.filter(|value| !value.trim().is_empty()) else {
        return Ok(DEFAULT_CAPTURE_SECONDS);
    };
    let seconds = value
        .parse::<u64>()
        .map_err(|_| format!("invalid duration seconds: {value}"))?;
    Ok(seconds.clamp(1, MAX_CAPTURE_SECONDS))
}

fn numeric_or_all(value: Option<&str>, name: &str) -> Result<String, String> {
    let value = value.unwrap_or("0").trim();
    if value.is_empty() || value == "all" {
        return Ok("0".to_string());
    }
    value
        .parse::<u32>()
        .map(|number| number.to_string())
        .map_err(|_| format!("invalid {name}: {value}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn pcap_defaults_duration_when_first_arg_is_interface() {
        let parsed = parse_pcap_args(&strings(&["wlan0", "tcp", "port", "443"])).unwrap();
        assert_eq!(parsed.seconds, DEFAULT_CAPTURE_SECONDS);
        assert_eq!(parsed.ifname, "wlan0");
        assert_eq!(parsed.filter, strings(&["tcp", "port", "443"]));
    }

    #[test]
    fn pcap_accepts_explicit_duration_before_interface() {
        let parsed = parse_pcap_args(&strings(&["30", "wlan0", "tcp"])).unwrap();
        assert_eq!(parsed.seconds, 30);
        assert_eq!(parsed.ifname, "wlan0");
        assert_eq!(parsed.filter, strings(&["tcp"]));
    }

    #[test]
    fn pcap_requires_interface_after_explicit_duration() {
        let err = parse_pcap_args(&strings(&["30"])).unwrap_err();
        assert!(err.contains("Usage: cli ecapture pcap"));
    }
}

fn bin_path(app: &App) -> PathBuf {
    app.moddir.join("bin/ecapture")
}

fn require_bin(app: &App) -> Result<PathBuf, String> {
    let bin = bin_path(app);
    if is_executable(&bin) {
        Ok(bin)
    } else {
        Err(format!(
            "ecapture binary is missing or not executable: {}",
            bin.display()
        ))
    }
}

fn is_executable(path: &Path) -> bool {
    path.is_file()
        && fs::metadata(path)
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
}

#[derive(Clone)]
struct RunOutcome {
    stdout: String,
    stderr: String,
    code: Option<i32>,
    timed_out: bool,
}

fn run_with_timeout(program: &Path, args: &[&str], timeout: Duration) -> RunOutcome {
    let mut child = match Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(err) => {
            return RunOutcome {
                stdout: String::new(),
                stderr: format!("failed to run {}: {err}", program.display()),
                code: Some(127),
                timed_out: false,
            }
        }
    };
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(100)),
            Ok(None) => {
                timed_out = true;
                let _ = child.kill();
                break;
            }
            Err(err) => {
                return RunOutcome {
                    stdout: String::new(),
                    stderr: format!("wait failed: {err}"),
                    code: Some(1),
                    timed_out: false,
                }
            }
        }
    }
    match child.wait_with_output() {
        Ok(output) => RunOutcome {
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            code: output.status.code(),
            timed_out,
        },
        Err(err) => RunOutcome {
            stdout: String::new(),
            stderr: format!("read failed: {err}"),
            code: Some(1),
            timed_out,
        },
    }
}

fn print_command_output(outcome: RunOutcome) {
    let stdout = outcome.stdout.trim();
    let stderr = outcome.stderr.trim();
    if !stdout.is_empty() {
        println!("{stdout}");
    }
    if !stderr.is_empty() {
        eprintln!("{stderr}");
    }
}

fn usage() -> String {
    "Usage: cli ecapture {status|version|help [tls|gotls|nspr|pcap]|tls [seconds] [pid|all] [uid|all]|gotls [seconds] [pid|all] [uid|all]|nspr [seconds] [pid|all] [uid|all]|pcap [seconds] <ifname> [pcap-filter ...]}".to_string()
}

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
