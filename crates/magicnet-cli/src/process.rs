use crate::{subscriptions, App};
use std::env;
use std::fs;
use std::io;
use std::os::fd::RawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub(crate) const SHORT_TIMEOUT: Duration = Duration::from_secs(3);
const DEFAULT_COMMAND_TIMEOUT_SECS: u64 = 180;
const MAX_COMMAND_TIMEOUT_SECS: u64 = 900;

fn command_timeout_secs(value: Option<&str>) -> u64 {
    value
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|seconds| (1..=MAX_COMMAND_TIMEOUT_SECS).contains(seconds))
        .unwrap_or(DEFAULT_COMMAND_TIMEOUT_SECS)
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

    // Most cores exit immediately after SIGTERM.  Poll instead of charging
    // every manual stop the full one-second grace period.
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut live = owned_singbox_pids(app);
    while live.iter().any(|pid| pids.contains(pid)) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(25));
        live = owned_singbox_pids(app);
    }
    for pid in pids {
        if live.contains(&pid) {
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
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) == -1 {
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

#[cfg(any(target_os = "android", target_os = "linux"))]
unsafe fn watchdog_worker_is_live(pid: libc::pid_t) -> bool {
    if pid <= 0 {
        return false;
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

    let stat_fd = libc::open(
        path.as_ptr().cast::<libc::c_char>(),
        libc::O_RDONLY | libc::O_CLOEXEC,
    );
    if stat_fd == -1 {
        return false;
    }
    let mut stat = [0_u8; 512];
    let stat_len = libc::read(
        stat_fd,
        stat.as_mut_ptr().cast::<libc::c_void>(),
        stat.len(),
    );
    libc::close(stat_fd);
    if stat_len < 4 {
        return false;
    }

    let mut index = stat_len as usize - 3;
    loop {
        if stat[index] == b')' && stat[index + 1] == b' ' {
            return !matches!(stat[index + 2], b'Z' | b'X' | b'x');
        }
        if index == 0 {
            return false;
        }
        index -= 1;
    }
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
            // then exits via _exit. The worker publishes its process-group ID
            // before exec. After that, EOF on the control pipe means the CLI
            // died without disarming us. Let the TERM rollback finish (up to
            // the same bounded command timeout), then reap any descendants
            // still left in the independent process group.
            unsafe {
                libc::close(control[1]);
                libc::close(worker_pid_pipe[1]);
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

                let mut marker = 0_u8;
                let read_result = libc::read(
                    control[0],
                    (&mut marker as *mut u8).cast::<libc::c_void>(),
                    1,
                );
                if read_result == 0 {
                    let poll_interval = libc::timespec {
                        tv_sec: 0,
                        tv_nsec: 100_000_000,
                    };
                    let max_polls = timeout.as_millis().saturating_add(99) / 100;
                    let mut polls = 0_u128;
                    while polls < max_polls && watchdog_worker_is_live(worker_pid) {
                        libc::nanosleep(&poll_interval, std::ptr::null_mut());
                        polls += 1;
                    }
                    libc::kill(-worker_pid, libc::SIGKILL);
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
            libc::kill(self.pid, libc::SIGTERM);
            loop {
                if libc::waitpid(self.pid, std::ptr::null_mut(), 0) != -1
                    || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted
                {
                    break;
                }
            }
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
    use super::{proc_pid_stat_is_live, singbox_commandline_owned};
    use std::path::{Path, PathBuf};

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
mod process_group_tests {
    use super::{
        clear_unsafe_subscription_environment, command_timeout_secs, run_magicnet_function,
        run_process_group, trusted_shell, App, DEFAULT_COMMAND_TIMEOUT_SECS,
        MAX_COMMAND_TIMEOUT_SECS, UNSAFE_SUBSCRIPTION_ENV,
    };
    use std::fs;
    use std::process::Command;
    use std::time::Duration;

    #[cfg(any(target_os = "android", target_os = "linux"))]
    #[test]
    fn watchdog_treats_a_zombie_worker_as_finished() {
        let mut child = Command::new("sh").args(["-c", "exit 0"]).spawn().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while unsafe { super::watchdog_worker_is_live(child.id() as libc::pid_t) }
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!unsafe { super::watchdog_worker_is_live(child.id() as libc::pid_t) });
        let _ = child.wait();
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
