use crate::{
    cmdline_has_script, read_proc_argv, read_proc_text_bounded, run_bounded_command, subscriptions,
    App, MAX_PROC_COMM_BYTES, MAX_PROC_STAT_BYTES,
};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::fd::RawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub(crate) const SHORT_TIMEOUT: Duration = Duration::from_secs(3);
const DEFAULT_COMMAND_TIMEOUT_SECS: u64 = 180;
const MAX_COMMAND_TIMEOUT_SECS: u64 = 900;
const PROC_SCAN_TIMEOUT: Duration = Duration::from_millis(750);
const PROC_SCAN_MAX_CANDIDATES: usize = 4096;

fn command_timeout_secs(value: Option<&str>) -> u64 {
    value
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|seconds| (1..=MAX_COMMAND_TIMEOUT_SECS).contains(seconds))
        .unwrap_or(DEFAULT_COMMAND_TIMEOUT_SECS)
}
pub(crate) fn named_process_candidates(name: &str) -> Result<Vec<String>, String> {
    let pidof = if Path::new("/system/bin/getprop").is_file() {
        ["/system/bin/pidof", "/system/xbin/pidof"]
            .into_iter()
            .find(|path| Path::new(path).is_file())
            .ok_or_else(|| "trusted Android pidof is unavailable".to_string())?
    } else {
        // Host package smoke supplies a fixture pidof through PATH. Android
        // never reaches this branch, so production process discovery cannot
        // be redirected by inherited environment variables.
        "pidof"
    };
    let mut command = Command::new(pidof);
    command.arg(name);
    let output = run_bounded_command(command, Duration::from_millis(750), 16 * 1024)?;
    if output.timed_out {
        return Err(format!("pid lookup timed out for {name}"));
    }
    if output.truncated {
        return Err(format!("pid lookup output was truncated for {name}"));
    }
    match output
        .status
        .as_ref()
        .and_then(std::process::ExitStatus::code)
    {
        Some(0) => {}
        Some(1) => return Ok(Vec::new()),
        Some(code) => return Err(format!("pid lookup failed for {name} with status {code}")),
        None => return Err(format!("pid lookup was terminated for {name}")),
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|_| format!("pid lookup returned non-UTF-8 output for {name}"))?;
    parse_named_process_output(name, &text)
}

fn parse_named_process_output(name: &str, text: &str) -> Result<Vec<String>, String> {
    if text.ends_with("\n[output truncated]") {
        return Err(format!("pid lookup output was truncated for {name}"));
    }
    let mut pids = Vec::new();
    for pid in text.split_whitespace() {
        if pid == "0" || !pid.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(format!("pid lookup returned malformed output for {name}"));
        }
        pids.push(pid.to_owned());
    }
    if pids.is_empty() {
        return Err(format!("pid lookup returned an empty success for {name}"));
    }
    pids.sort_unstable();
    pids.dedup();
    Ok(pids)
}

const PROC_PIDS_HEADER: &str = "MAGICNET_PROC_PIDS_V1";
const PROC_PIDS_FOOTER: &str = "MAGICNET_PROC_PIDS_END";

fn write_named_process_candidates<W: Write>(writer: &mut W, pids: &[String]) -> io::Result<()> {
    writeln!(writer, "{PROC_PIDS_HEADER}")?;
    for pid in pids {
        writeln!(writer, "{pid}")?;
    }
    writeln!(writer, "{PROC_PIDS_FOOTER} {}", pids.len())?;
    writer.flush()
}

pub(crate) fn proc_named_pids_command(args: &[String]) -> Result<(), String> {
    if args.len() != 1
        || args[0].is_empty()
        || args[0].len() > 64
        || !args[0]
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err("internal proc name usage error".to_string());
    }
    crate::utils::arm_parent_death_signal()?;
    let pids = named_process_candidates(&args[0])?;
    let stdout = io::stdout();
    write_named_process_candidates(&mut stdout.lock(), &pids)
        .map_err(|err| format!("write framed pid lookup: {err}"))
}

pub(crate) fn proc_script_pids_command(args: &[String]) -> Result<(), String> {
    if args.len() != 2 {
        return Err("internal proc script scan usage error".to_string());
    }
    let proc_root = Path::new(&args[0]);
    let expected_script = Path::new(&args[1]);
    if !proc_root.is_absolute()
        || !expected_script.is_absolute()
        || proc_root
            .components()
            .chain(expected_script.components())
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err("invalid proc scan path".to_string());
    }
    crate::utils::arm_parent_death_signal()?;
    let deadline = Instant::now() + PROC_SCAN_TIMEOUT;
    let entries = fs::read_dir(proc_root)
        .map_err(|err| format!("read proc scan root {}: {err}", proc_root.display()))?;
    let mut candidates = Vec::new();
    let mut inspected = 0_usize;
    for entry in entries {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("proc script scan deadline exceeded".to_string());
        }
        let entry = entry.map_err(|err| format!("read proc scan entry: {err}"))?;
        let name = entry.file_name();
        let Some(pid) = name
            .to_str()
            .filter(|pid| !pid.is_empty() && pid.bytes().all(|byte| byte.is_ascii_digit()))
        else {
            continue;
        };
        inspected += 1;
        if inspected > PROC_SCAN_MAX_CANDIDATES {
            return Err(format!(
                "proc script scan exceeded {PROC_SCAN_MAX_CANDIDATES} candidates"
            ));
        }
        let proc_dir = proc_root.join(pid);
        match crate::utils::read_proc_argv_with_timeout(&proc_dir.join("cmdline"), remaining) {
            Ok(argv) if cmdline_has_script(&argv, &args[1]) => candidates.push(pid.to_string()),
            Ok(_) => {}
            Err(_) if !proc_dir.exists() => {}
            Err(err) => {
                return Err(format!("indeterminate proc script candidate {pid}: {err}"));
            }
        }
    }
    if Instant::now() >= deadline {
        return Err("proc script scan deadline exceeded".to_string());
    }
    candidates.sort_unstable();
    candidates.dedup();
    let stdout = io::stdout();
    write_named_process_candidates(&mut stdout.lock(), &candidates)
        .map_err(|err| format!("write framed proc script scan: {err}"))
}

pub(crate) fn pid_summary(name: &str) -> String {
    let candidates = match named_process_candidates(name) {
        Ok(candidates) => candidates,
        Err(_) => return "unknown".to_string(),
    };
    let mut pids = Vec::new();
    for pid in candidates {
        let proc_dir = Path::new("/proc").join(&pid);
        match proc_pid_is_live(&proc_dir) {
            Ok(true) => {}
            Ok(false) => continue,
            Err(_) => return "unknown".to_string(),
        }
        match read_live_proc_text(&proc_dir, "comm", MAX_PROC_COMM_BYTES) {
            Ok(Some(value)) if value.trim() == name => pids.push(pid),
            Ok(_) => {}
            Err(_) => return "unknown".to_string(),
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
    match owned_singbox_pids(app) {
        Ok(pids) if pids.is_empty() => "stopped".to_string(),
        Ok(pids) => pids.join(","),
        Err(_) => "unknown".to_string(),
    }
}

pub(crate) fn owned_singbox_pids(app: &App) -> Result<Vec<String>, String> {
    let candidates = named_process_candidates("sing-box")?;
    if candidates.is_empty() {
        return Ok(Vec::new());
    }
    let expected_binary_path = app.moddir.join("bin/sing-box");
    let expected_config = app.moddir.join(".config/sing-box/config.json");
    let expected_workdir = app.moddir.join(".config/sing-box");
    let expected_binary = fs::canonicalize(&expected_binary_path).map_err(|err| {
        format!(
            "cannot bind sing-box ownership to {}: {err}",
            expected_binary_path.display()
        )
    })?;
    let mut pids = Vec::new();
    for pid in candidates {
        let proc_dir = Path::new("/proc").join(&pid);
        match proc_pid_is_live(&proc_dir)? {
            true => {}
            false => continue,
        }
        let Some(comm) = read_live_proc_text(&proc_dir, "comm", MAX_PROC_COMM_BYTES)? else {
            continue;
        };
        if comm.trim() != "sing-box" {
            continue;
        }
        let argv = match read_proc_argv(&proc_dir.join("cmdline")) {
            Ok(argv) => argv,
            Err(_) if !proc_dir.exists() => continue,
            Err(err) => return Err(format!("read sing-box candidate {pid} cmdline: {err}")),
        };
        if !singbox_commandline_owned(&argv, &expected_binary, &expected_config, &expected_workdir)
        {
            continue;
        }
        match singbox_executable_owned(&proc_dir, &expected_binary) {
            Some(true) => pids.push(pid),
            Some(false) if singbox_script_arg_owned(&argv, &expected_binary) => pids.push(pid),
            Some(false) => {}
            None if singbox_script_arg_owned(&argv, &expected_binary) => pids.push(pid),
            None => {
                return Err(format!(
                    "cannot verify executable identity for live sing-box candidate {pid}"
                ));
            }
        }
    }
    Ok(pids)
}

fn read_live_proc_text(
    proc_dir: &Path,
    file_name: &str,
    max_bytes: usize,
) -> Result<Option<String>, String> {
    match read_proc_text_bounded(&proc_dir.join(file_name), max_bytes) {
        Ok(value) => Ok(Some(value)),
        Err(_) if !proc_dir.exists() => Ok(None),
        Err(err) => Err(err),
    }
}

fn proc_pid_is_live(proc_dir: &Path) -> Result<bool, String> {
    let Some(stat) = read_live_proc_text(proc_dir, "stat", MAX_PROC_STAT_BYTES)? else {
        return Ok(false);
    };
    Ok(proc_pid_stat_is_live(&stat))
}

fn proc_pid_stat_is_live(stat: &str) -> bool {
    stat.rsplit_once(") ")
        .and_then(|(_, fields)| fields.chars().next())
        .is_some_and(|state| state != 'Z')
}

fn singbox_executable_owned(proc_dir: &Path, expected_binary: &Path) -> Option<bool> {
    let Ok(executable) = fs::read_link(proc_dir.join("exe")) else {
        // Script-backed host fixtures expose the module script in argv while
        // /proc/exe points at the interpreter. On Android some SELinux
        // contexts also hide this link; the caller may then use the exact
        // `sing-box run -c <module-config> -D <module-workdir>` argv fallback.
        return None;
    };
    Some(
        fs::canonicalize(executable)
            .map(|path| path == expected_binary)
            .unwrap_or(false),
    )
}

fn singbox_script_arg_owned(argv: &[String], expected_binary: &Path) -> bool {
    let expected_binary = expected_binary.to_string_lossy();
    argv.iter().any(|arg| arg == expected_binary.as_ref())
}

fn singbox_commandline_owned(
    argv: &[String],
    expected_binary: &Path,
    expected_config: &Path,
    expected_workdir: &Path,
) -> bool {
    let expected_binary = expected_binary.to_string_lossy();
    let run_index = if argv
        .first()
        .is_some_and(|arg| arg == expected_binary.as_ref() || arg == "sing-box")
    {
        1
    } else if argv.len() >= 2
        && matches!(
            argv[0].rsplit('/').next(),
            Some("sh" | "ash" | "dash" | "bash" | "ksh" | "mksh")
        )
        && argv[1] == expected_binary.as_ref()
    {
        2
    } else {
        return false;
    };
    if argv.get(run_index).map(String::as_str) != Some("run") {
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
            _ => return false,
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

pub(crate) fn stop_owned_singbox(app: &App, initial_pids: Vec<String>) -> Result<(), String> {
    for pid in &initial_pids {
        signal_pid(pid, false);
    }

    // Most cores exit immediately after SIGTERM. Poll instead of charging
    // every manual stop the full grace period. Any lookup error remains
    // indeterminate and must block runtime cleanup and a replacement start.
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut live = owned_singbox_pids(app)?;
    while !live.is_empty() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(25));
        live = owned_singbox_pids(app)?;
    }
    for pid in &live {
        signal_pid(pid, true);
    }
    if !live.is_empty() {
        let kill_deadline = Instant::now() + Duration::from_secs(1);
        loop {
            live = owned_singbox_pids(app)?;
            if live.is_empty() {
                break;
            }
            if Instant::now() >= kill_deadline {
                return Err(format!(
                    "managed sing-box did not stop after SIGKILL: {}",
                    live.join(",")
                ));
            }
            thread::sleep(Duration::from_millis(25));
        }
    }
    Ok(())
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

// Privileged shell entrypoints must not inherit caller-controlled library,
// proc, or dynamic-linker paths. Host-side fixture tests may still opt in
// through MAGICNET_LIB_DIR when the CLI is not the Android production build.
const UNSAFE_INHERITED_ENV: &[&str] = &[
    "MAGICNET_LIB_DIR",
    "MAGICNET_PROC_ROOT",
    "MAGICNET_PROC_QUERY_DIR",
    "MAGICNET_SINGBOX_PROC_ROOT",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "LD_AUDIT",
];

fn clear_unsafe_privileged_environment(command: &mut Command) {
    for key in UNSAFE_SUBSCRIPTION_ENV
        .iter()
        .chain(UNSAFE_INHERITED_ENV.iter())
    {
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
    clear_unsafe_privileged_environment(&mut command);
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
    let mut watchdog = ParentDeathWatchdog::arm(timeout)?;
    #[cfg(any(target_os = "android", target_os = "linux"))]
    let watchdog_worker_fd = watchdog.worker_pid_fd();
    #[cfg(any(target_os = "android", target_os = "linux"))]
    let parent_pid = unsafe { libc::getpid() };
    // SAFETY: pre_exec only invokes async-signal-safe libc operations before
    // exec.  The parent-death signal prevents an externally killed CLI from
    // leaving its privileged shell alive with subscription/config locks.  The
    // parent check closes the fork-to-prctl race: if the CLI died before the
    // child armed PR_SET_PDEATHSIG, the child aborts instead of becoming an
    // untracked session leader. The child publishes its process-group ID to a
    // watchdog that was armed before spawn, closing the post-spawn gap too.
    unsafe {
        command.pre_exec(move || {
            #[cfg(any(target_os = "android", target_os = "linux"))]
            {
                // Freeze the session leader on abrupt CLI death. The bound
                // watchdog signals the whole group and resumes the leader so
                // rollback traps run without letting descendants escape.
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGSTOP) == -1 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != parent_pid {
                    return Err(io::Error::from_raw_os_error(libc::ECHILD));
                }
            }
            if libc::setsid() == -1 {
                Err(io::Error::last_os_error())
            } else {
                #[cfg(any(target_os = "android", target_os = "linux"))]
                {
                    let worker_pid = libc::getpid();
                    let written = libc::write(
                        watchdog_worker_fd,
                        (&worker_pid as *const libc::pid_t).cast::<libc::c_void>(),
                        std::mem::size_of::<libc::pid_t>(),
                    );
                    libc::close(watchdog_worker_fd);
                    if written != std::mem::size_of::<libc::pid_t>() as isize {
                        return Err(io::Error::last_os_error());
                    }
                }
                Ok(())
            }
        });
    }
    let mut child = command
        .spawn()
        .map_err(|err| format!("spawn failed: {err}"))?;
    watchdog.worker_spawned();
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|err| format!("wait failed: {err}"))?
        {
            return Ok(status);
        }
        if Instant::now() >= deadline {
            if !terminate_timed_out_child(
                &mut child,
                Duration::from_millis(100),
                Duration::from_millis(100),
            ) {
                defer_child_reap(child);
            }
            return Err(format!("timed out after {}ms", timeout.as_millis()));
        }
        thread::sleep(Duration::from_millis(40));
    }
}

trait TimedChildWait {
    fn signal_group(&mut self, signal: libc::c_int);
    fn try_reap(&mut self) -> Result<bool, io::Error>;
}

impl TimedChildWait for std::process::Child {
    fn signal_group(&mut self, signal: libc::c_int) {
        unsafe {
            libc::kill(-(self.id() as libc::pid_t), signal);
        }
    }

    fn try_reap(&mut self) -> Result<bool, io::Error> {
        self.try_wait().map(|status| status.is_some())
    }
}

fn terminate_timed_out_child<W: TimedChildWait>(
    child: &mut W,
    term_grace: Duration,
    kill_grace: Duration,
) -> bool {
    child.signal_group(libc::SIGTERM);
    let term_deadline = Instant::now() + term_grace;
    loop {
        match child.try_reap() {
            Ok(true) => {
                child.signal_group(libc::SIGKILL);
                return true;
            }
            Err(_) => return true,
            Ok(false) if Instant::now() >= term_deadline => break,
            Ok(false) => thread::sleep(Duration::from_millis(10)),
        }
    }
    child.signal_group(libc::SIGKILL);
    let kill_deadline = Instant::now() + kill_grace;
    loop {
        match child.try_reap() {
            Ok(true) | Err(_) => return true,
            Ok(false) if Instant::now() >= kill_deadline => return false,
            Ok(false) => thread::sleep(Duration::from_millis(10)),
        }
    }
}

fn defer_child_reap(mut child: std::process::Child) {
    let _ = thread::Builder::new()
        .name("magicnet-process-reaper".to_string())
        .spawn(move || loop {
            match child.try_wait() {
                Ok(Some(_)) | Err(_) => break,
                Ok(None) => thread::sleep(Duration::from_millis(250)),
            }
        });
}

#[cfg(any(target_os = "android", target_os = "linux"))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct WatchdogWorkerIdentity {
    starttime: u64,
    live: bool,
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn watchdog_worker_identity(pid: libc::pid_t) -> Option<WatchdogWorkerIdentity> {
    if pid <= 0 {
        return None;
    }

    let mut path = [0_u8; 64];
    let prefix = b"/proc/";
    path[..prefix.len()].copy_from_slice(prefix);
    let mut path_len = prefix.len();
    let mut digits = [0_u8; 20];
    let mut digit_len = 0_usize;
    let mut remaining = pid as u64;
    loop {
        digits[digit_len] = b'0' + (remaining % 10) as u8;
        digit_len += 1;
        remaining /= 10;
        if remaining == 0 {
            break;
        }
    }
    while digit_len > 0 {
        digit_len -= 1;
        path[path_len] = digits[digit_len];
        path_len += 1;
    }
    let suffix = b"/stat\0";
    path[path_len..path_len + suffix.len()].copy_from_slice(suffix);

    let stat_fd = unsafe {
        libc::open(
            path.as_ptr().cast::<libc::c_char>(),
            libc::O_RDONLY | libc::O_CLOEXEC,
        )
    };
    if stat_fd == -1 {
        return None;
    }
    let mut stat = [0_u8; 512];
    let stat_len = unsafe {
        libc::read(
            stat_fd,
            stat.as_mut_ptr().cast::<libc::c_void>(),
            stat.len(),
        )
    };
    unsafe { libc::close(stat_fd) };
    if stat_len < 4 {
        return None;
    }
    let stat = &stat[..stat_len as usize];
    let close = stat.windows(2).rposition(|pair| pair == b") ")?;
    let fields = &stat[close + 2..];
    let state = *fields.first()?;
    let mut field_index = 0_usize;
    let mut index = 0_usize;
    let mut starttime = None;
    while index < fields.len() {
        while index < fields.len() && fields[index].is_ascii_whitespace() {
            index += 1;
        }
        let start = index;
        while index < fields.len() && !fields[index].is_ascii_whitespace() {
            index += 1;
        }
        if start == index {
            break;
        }
        if field_index == 19 {
            let mut value = 0_u64;
            for byte in &fields[start..index] {
                if !byte.is_ascii_digit() {
                    return None;
                }
                value = value.checked_mul(10)?.checked_add((byte - b'0') as u64)?;
            }
            starttime = Some(value);
            break;
        }
        field_index += 1;
    }
    Some(WatchdogWorkerIdentity {
        starttime: starttime?,
        live: !matches!(state, b'Z' | b'X' | b'x'),
    })
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn watchdog_worker_is_live(pid: libc::pid_t) -> bool {
    watchdog_worker_identity(pid).is_some_and(|identity| identity.live)
}

#[cfg(any(target_os = "android", target_os = "linux"))]
unsafe fn watchdog_close_inherited_fds(keep_a: libc::c_int, keep_b: libc::c_int) {
    let (low, high) = if keep_a <= keep_b {
        (keep_a, keep_b)
    } else {
        (keep_b, keep_a)
    };
    let close_range = |first: libc::c_uint, last: libc::c_uint| {
        if first > last {
            0
        } else {
            libc::syscall(libc::SYS_close_range, first, last, 0) as libc::c_int
        }
    };
    let closed = close_range(0, low.saturating_sub(1) as libc::c_uint) == 0
        && close_range(
            (low + 1) as libc::c_uint,
            high.saturating_sub(1) as libc::c_uint,
        ) == 0
        && close_range((high + 1) as libc::c_uint, libc::c_uint::MAX) == 0;
    if closed {
        return;
    }

    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    let max_fd = if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0 {
        limit.rlim_cur.min(libc::c_int::MAX as libc::rlim_t) as libc::c_int
    } else {
        65_536
    };
    for fd in 0..max_fd {
        if fd != keep_a && fd != keep_b {
            libc::close(fd);
        }
    }
}

#[cfg(any(target_os = "android", target_os = "linux"))]
unsafe fn watchdog_pidfd_open(pid: libc::pid_t) -> libc::c_int {
    libc::syscall(libc::SYS_pidfd_open, pid, 0) as libc::c_int
}

#[cfg(any(target_os = "android", target_os = "linux"))]
unsafe fn watchdog_pidfd_signal(pidfd: libc::c_int, signal: libc::c_int) -> bool {
    libc::syscall(
        libc::SYS_pidfd_send_signal,
        pidfd,
        signal,
        std::ptr::null::<libc::siginfo_t>(),
        0,
    ) == 0
}

#[cfg(any(target_os = "android", target_os = "linux"))]
unsafe fn watchdog_signal_bound_group(
    pid: libc::pid_t,
    pidfd: libc::c_int,
    expected_starttime: Option<u64>,
    signal: libc::c_int,
) -> bool {
    if pidfd >= 0 {
        // Pin the original leader while the process-group API still has to
        // address a numeric PGID. A recycled PID can never receive the signal.
        if !watchdog_pidfd_signal(pidfd, libc::SIGSTOP) {
            return false;
        }
        libc::kill(-pid, signal);
        if signal == libc::SIGKILL {
            watchdog_pidfd_signal(pidfd, libc::SIGKILL);
        } else {
            watchdog_pidfd_signal(pidfd, libc::SIGCONT);
        }
        return true;
    }

    let Some(expected_starttime) = expected_starttime else {
        return false;
    };
    if watchdog_worker_identity(pid)
        .is_none_or(|identity| !identity.live || identity.starttime != expected_starttime)
    {
        return false;
    }
    libc::kill(pid, libc::SIGSTOP);
    if watchdog_worker_identity(pid)
        .is_none_or(|identity| !identity.live || identity.starttime != expected_starttime)
    {
        if watchdog_worker_identity(pid)
            .is_some_and(|identity| identity.starttime == expected_starttime)
        {
            libc::kill(pid, libc::SIGCONT);
        }
        return false;
    }
    libc::kill(-pid, signal);
    if signal != libc::SIGKILL {
        libc::kill(pid, libc::SIGCONT);
    }
    true
}

#[cfg(any(target_os = "android", target_os = "linux"))]
unsafe fn watchdog_resume_bound_worker(
    pid: libc::pid_t,
    pidfd: libc::c_int,
    expected_starttime: Option<u64>,
) {
    if pidfd >= 0 {
        watchdog_pidfd_signal(pidfd, libc::SIGCONT);
    } else if expected_starttime.is_some_and(|expected| {
        watchdog_worker_identity(pid).is_some_and(|identity| identity.starttime == expected)
    }) {
        libc::kill(pid, libc::SIGCONT);
    }
}

#[cfg(any(target_os = "android", target_os = "linux"))]
unsafe fn watchdog_kill_bound_group(
    pid: libc::pid_t,
    pidfd: libc::c_int,
    expected_starttime: Option<u64>,
) -> bool {
    watchdog_signal_bound_group(pid, pidfd, expected_starttime, libc::SIGKILL)
}

#[cfg(any(target_os = "android", target_os = "linux"))]
struct ParentDeathWatchdog {
    pid: libc::pid_t,
    control_fd: libc::c_int,
    worker_pid_fd: libc::c_int,
}

#[cfg(any(target_os = "android", target_os = "linux"))]
impl ParentDeathWatchdog {
    fn arm(timeout: Duration) -> Result<Self, String> {
        let mut control = [-1; 2];
        if unsafe { libc::pipe2(control.as_mut_ptr(), libc::O_CLOEXEC) } == -1 {
            return Err(format!(
                "parent-death watchdog pipe failed: {}",
                io::Error::last_os_error()
            ));
        }
        let mut worker_pid_pipe = [-1; 2];
        if unsafe { libc::pipe2(worker_pid_pipe.as_mut_ptr(), libc::O_CLOEXEC) } == -1 {
            unsafe {
                libc::close(control[0]);
                libc::close(control[1]);
            }
            return Err(format!(
                "parent-death watchdog PID pipe failed: {}",
                io::Error::last_os_error()
            ));
        }

        let watchdog_pid = unsafe { libc::fork() };
        if watchdog_pid == -1 {
            unsafe {
                libc::close(control[0]);
                libc::close(control[1]);
                libc::close(worker_pid_pipe[0]);
                libc::close(worker_pid_pipe[1]);
            }
            return Err(format!(
                "parent-death watchdog fork failed: {}",
                io::Error::last_os_error()
            ));
        }
        if watchdog_pid == 0 {
            // SAFETY: this post-fork child uses stack values and libc calls,
            // then exits via _exit. Close every inherited descriptor except
            // the two control reads immediately: otherwise a killed CLI can
            // leave stdout/stderr consumers waiting for EOF on this watchdog.
            unsafe {
                watchdog_close_inherited_fds(control[0], worker_pid_pipe[0]);
                let mut worker_pid: libc::pid_t = 0;
                let worker_pid_size = std::mem::size_of::<libc::pid_t>();
                let mut worker_pid_read = 0_usize;
                while worker_pid_read < worker_pid_size {
                    let read_result = libc::read(
                        worker_pid_pipe[0],
                        ((&mut worker_pid as *mut libc::pid_t).cast::<u8>())
                            .add(worker_pid_read)
                            .cast::<libc::c_void>(),
                        worker_pid_size - worker_pid_read,
                    );
                    if read_result <= 0 {
                        libc::close(worker_pid_pipe[0]);
                        libc::close(control[0]);
                        libc::_exit(0);
                    }
                    worker_pid_read += read_result as usize;
                }
                libc::close(worker_pid_pipe[0]);
                let worker_identity = watchdog_worker_identity(worker_pid);
                let worker_pidfd = watchdog_pidfd_open(worker_pid);

                let mut marker = 0_u8;
                let read_result = libc::read(
                    control[0],
                    (&mut marker as *mut u8).cast::<libc::c_void>(),
                    1,
                );
                if read_result == 0 {
                    // PR_SET_PDEATHSIG froze the leader. TERM the entire
                    // identity-bound group, then resume the leader so its
                    // rollback trap can complete during the grace window.
                    watchdog_signal_bound_group(
                        worker_pid,
                        worker_pidfd,
                        worker_identity.map(|identity| identity.starttime),
                        libc::SIGTERM,
                    );
                    let poll_interval = libc::timespec {
                        tv_sec: 0,
                        tv_nsec: 100_000_000,
                    };
                    let max_polls = timeout.as_millis().saturating_add(99) / 100;
                    let mut polls = 0_u128;
                    while polls < max_polls && watchdog_worker_is_live(worker_pid) {
                        // PR_SET_PDEATHSIG can be delivered just after the
                        // first SIGCONT; reassert resume through the bound
                        // identity until TERM rollback starts or it exits.
                        watchdog_resume_bound_worker(
                            worker_pid,
                            worker_pidfd,
                            worker_identity.map(|identity| identity.starttime),
                        );
                        libc::nanosleep(&poll_interval, std::ptr::null_mut());
                        polls += 1;
                    }
                    if watchdog_worker_is_live(worker_pid) {
                        watchdog_kill_bound_group(
                            worker_pid,
                            worker_pidfd,
                            worker_identity.map(|identity| identity.starttime),
                        );
                    }
                }
                if worker_pidfd >= 0 {
                    libc::close(worker_pidfd);
                }
                libc::close(control[0]);
                libc::_exit(0);
            }
        }

        unsafe {
            libc::close(control[0]);
            libc::close(worker_pid_pipe[0]);
        }
        Ok(Self {
            pid: watchdog_pid,
            control_fd: control[1],
            worker_pid_fd: worker_pid_pipe[1],
        })
    }

    fn worker_pid_fd(&self) -> libc::c_int {
        self.worker_pid_fd
    }

    fn worker_spawned(&mut self) {
        unsafe {
            libc::close(self.worker_pid_fd);
        }
        self.worker_pid_fd = -1;
    }
}

#[cfg(any(target_os = "android", target_os = "linux"))]
impl Drop for ParentDeathWatchdog {
    fn drop(&mut self) {
        // A normal CLI path disarms the watcher before closing the pipe. If
        // the CLI is killed, Drop cannot run and pipe EOF triggers cleanup.
        unsafe {
            crate::utils::kill_and_reap(self.pid);
            libc::close(self.control_fd);
            if self.worker_pid_fd != -1 {
                libc::close(self.worker_pid_fd);
            }
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "linux")))]
struct ParentDeathWatchdog;

#[cfg(not(any(target_os = "android", target_os = "linux")))]
impl ParentDeathWatchdog {
    fn arm(_timeout: Duration) -> Result<Self, String> {
        Ok(Self)
    }

    fn worker_spawned(&mut self) {}
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

#[cfg(test)]
mod path_tests {
    use super::{
        parse_named_process_output, proc_pid_stat_is_live, singbox_commandline_owned,
        write_named_process_candidates,
    };
    use std::path::{Path, PathBuf};

    #[test]
    fn singbox_ownership_requires_module_binary_and_exact_runtime_paths() {
        let binary = PathBuf::from("/module/bin/sing-box");
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

        let mut prefix_decoy = vec![
            "/tmp/decoy".to_string(),
            "-c".to_string(),
            "sleep 30; :".to_string(),
            "ignored".to_string(),
        ];
        prefix_decoy.extend(owned);
        assert!(!singbox_commandline_owned(
            &prefix_decoy,
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

    #[test]
    fn named_pid_output_is_count_framed() {
        let mut output = Vec::new();
        write_named_process_candidates(&mut output, &["17".into(), "2048".into()]).unwrap();
        assert_eq!(
            String::from_utf8(output).unwrap(),
            "MAGICNET_PROC_PIDS_V1\n17\n2048\nMAGICNET_PROC_PIDS_END 2\n"
        );

        let mut empty = Vec::new();
        write_named_process_candidates(&mut empty, &[]).unwrap();
        assert_eq!(
            String::from_utf8(empty).unwrap(),
            "MAGICNET_PROC_PIDS_V1\nMAGICNET_PROC_PIDS_END 0\n"
        );
    }

    #[test]
    fn named_pid_parser_rejects_empty_malformed_and_truncated_success() {
        assert_eq!(
            parse_named_process_output("sing-box", "42 7 42\n").unwrap(),
            vec!["42", "7"]
        );
        assert!(parse_named_process_output("sing-box", "").is_err());
        assert!(parse_named_process_output("sing-box", "42 invalid\n").is_err());
        assert!(parse_named_process_output("sing-box", "42\n[output truncated]").is_err());
    }
}

#[cfg(test)]
mod process_group_tests {
    use super::{
        clear_unsafe_privileged_environment, command_timeout_secs, run_magicnet_function,
        run_process_group, terminate_timed_out_child, trusted_shell, App, TimedChildWait,
        DEFAULT_COMMAND_TIMEOUT_SECS, MAX_COMMAND_TIMEOUT_SECS, UNSAFE_INHERITED_ENV,
        UNSAFE_SUBSCRIPTION_ENV,
    };
    use std::fs;
    use std::process::Command;
    use std::time::Duration;

    #[cfg(any(target_os = "android", target_os = "linux"))]
    #[test]
    fn watchdog_treats_a_zombie_worker_as_finished() -> Result<(), Box<dyn std::error::Error>> {
        let mut child = Command::new("sh").args(["-c", "exit 0"]).spawn()?;
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while super::watchdog_worker_is_live(child.id() as libc::pid_t)
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!super::watchdog_worker_is_live(child.id() as libc::pid_t));
        let _ = child.wait();
        Ok(())
    }

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

    struct NeverReap {
        signals: Vec<libc::c_int>,
    }

    impl TimedChildWait for NeverReap {
        fn signal_group(&mut self, signal: libc::c_int) {
            self.signals.push(signal);
        }

        fn try_reap(&mut self) -> Result<bool, std::io::Error> {
            Ok(false)
        }
    }

    #[test]
    fn timeout_cleanup_has_a_fixed_grace_when_sigkill_cannot_reap() {
        let mut child = NeverReap {
            signals: Vec::new(),
        };
        let started = std::time::Instant::now();
        assert!(!terminate_timed_out_child(
            &mut child,
            Duration::from_millis(30),
            Duration::from_millis(30),
        ));
        assert!(started.elapsed() < Duration::from_millis(250));
        assert_eq!(child.signals, vec![libc::SIGTERM, libc::SIGKILL]);
    }

    #[cfg(any(target_os = "android", target_os = "linux"))]
    #[test]
    fn watchdog_fallback_refuses_a_reused_pid_identity() -> Result<(), Box<dyn std::error::Error>> {
        let mut child = Command::new("sleep").arg("30").spawn()?;
        let pid = child.id() as libc::pid_t;
        let identity = super::watchdog_worker_identity(pid).ok_or("missing child identity")?;
        let killed = unsafe {
            super::watchdog_kill_bound_group(pid, -1, Some(identity.starttime.saturating_add(1)))
        };
        assert!(!killed);
        assert_eq!(unsafe { libc::kill(pid, 0) }, 0);
        child.kill()?;
        child.wait()?;
        Ok(())
    }

    #[test]
    fn timeout_reaps_command_and_kills_grandchild() -> Result<(), Box<dyn std::error::Error>> {
        let pid_file =
            std::env::temp_dir().join(format!("magicnet-grandchild-{}", std::process::id()));
        let script = format!("sleep 30 & echo $! > '{}'; wait", pid_file.display());
        let mut command = Command::new("sh");
        command.args(["-c", &script]);
        assert!(run_process_group(&mut command, Duration::from_millis(100)).is_err());
        let pid = fs::read_to_string(&pid_file)?.trim().parse::<i32>()?;
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        let _ = fs::remove_file(pid_file);
        Ok(())
    }

    #[test]
    fn timeout_immediately_cleans_dead_update_owner() -> Result<(), Box<dyn std::error::Error>> {
        let root =
            std::env::temp_dir().join(format!("magicnet-timeout-lock-{}", std::process::id()));
        let lock = root.join(".state/sing-box/subscription-update.lock");
        fs::create_dir_all(&lock)?;
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
        Ok(())
    }

    #[test]
    fn function_runner_does_not_interpolate_shell_sensitive_module_paths(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let root =
            std::env::temp_dir().join(format!("magicnet-function-quote-{}-'", std::process::id()));
        fs::create_dir_all(root.join("lib/kamfw"))?;
        fs::write(root.join("lib/kamfw/.kamfwrc"), "import() { :; }\n")?;
        fs::write(root.join("lib/magicnet.sh"), "")?;
        let app = App {
            moddir: root.clone(),
            api: String::new(),
            log_dir: root.join(".log"),
        };

        run_magicnet_function(&app, "printf '%s' safe > \"$MODDIR/function-result\"")
            .map_err(std::io::Error::other)?;
        assert_eq!(fs::read_to_string(root.join("function-result"))?, "safe");
        let _ = fs::remove_dir_all(root);
        Ok(())
    }

    #[test]
    fn function_runner_does_not_inherit_subscription_file_overrides(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut command = Command::new("sh");
        command.args(["-c", "env"]);
        for key in UNSAFE_SUBSCRIPTION_ENV
            .iter()
            .chain(UNSAFE_INHERITED_ENV.iter())
        {
            command.env(key, "attacker-controlled");
        }
        clear_unsafe_privileged_environment(&mut command);
        let output = command.output()?;
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout)?;
        for key in UNSAFE_SUBSCRIPTION_ENV
            .iter()
            .chain(UNSAFE_INHERITED_ENV.iter())
        {
            assert!(
                !stdout
                    .lines()
                    .any(|line| line.starts_with(&format!("{key}="))),
                "unsafe privileged variable leaked: {key}"
            );
        }
        Ok(())
    }

    #[test]
    fn function_runner_uses_an_absolute_shell_path() {
        assert!(trusted_shell().starts_with('/'));
    }
}
