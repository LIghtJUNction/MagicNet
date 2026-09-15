from pathlib import Path
import re
import subprocess
import sys

BASE = 'eeebef566c9ea968d5bf2da42709c603ad1e80d1'
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == BASE
utils = Path('crates/magicnet-cli/src/utils.rs')
process = Path('crates/magicnet-cli/src/process.rs')
tests = Path('crates/magicnet-cli/tests/internal/resource_limits.rs')


def once(text, old, new):
    assert text.count(old) == 1, (text.count(old), old[:160])
    return text.replace(old, new, 1)


if sys.argv[1] == 'regressions':
    tests.write_text(tests.read_text().rstrip() + r'''

#[test]
fn command_retains_leader_until_pipe_cleanup() {
    let output = run_bounded_command(
        shell("leader=$$; (sleep 0.1; if [ -r /proc/$leader/stat ]; then printf retained; else printf reaped; fi) & exit 7"),
        Duration::from_secs(5),
        128,
    )
    .unwrap();
    assert!(!output.timed_out);
    assert_eq!(output.status.unwrap().code(), Some(7));
    assert_eq!(output.stdout, b"retained");
}
''' + '\n')
    process.write_text(process.read_text().rstrip() + r'''

#[cfg(test)]
mod resource_review_tests {
    use super::*;

    // The deferred reaper owns these children. They terminate independently
    // after two seconds even if a regression fails the assertion below.
    #[test]
    #[allow(clippy::zombie_processes)]
    fn lifecycle_deferred_children_use_one_reaper() {
        const NAME: &str = "process::resource_review_tests::lifecycle_deferred_children_use_one_reaper";
        if std::env::var("MAGICNET_LIFECYCLE_RESOURCE_CHILD").as_deref() != Ok(NAME) {
            let mut command = Command::new(std::env::current_exe().unwrap());
            command.args(["--exact", NAME, "--nocapture"])
                .env("MAGICNET_LIFECYCLE_RESOURCE_CHILD", NAME);
            let result = run_bounded_command(command, Duration::from_secs(10), 8192).unwrap();
            assert!(!result.timed_out);
            assert!(result.status.unwrap().success(), "{}{}",
                String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
            return;
        }
        let before = fs::read_dir("/proc/self/task").unwrap().count();
        let mut pids = Vec::new();
        for _ in 0..8 {
            let child = Command::new("sleep").arg("2").spawn().unwrap();
            pids.push(child.id() as libc::pid_t);
            super::defer_child_reap(child);
        }
        let after = fs::read_dir("/proc/self/task").unwrap().count();
        let deadline = Instant::now() + Duration::from_secs(5);
        while pids.iter().any(|pid| Path::new(&format!("/proc/{pid}")).exists()) {
            assert!(Instant::now() < deadline, "deferred children were not reaped");
            thread::sleep(Duration::from_millis(10));
        }
        assert!(after <= before + 1, "deferred cleanup created {} threads", after - before);
    }
}
''' + '\n')
    sys.exit(0)

assert sys.argv[1] == 'fix'
u = utils.read_text()
u = once(u, 'use std::os::unix::process::CommandExt;',
         'use std::os::unix::process::{CommandExt, ExitStatusExt};')
u = once(u, 'struct ChildProbeBudget;', 'pub(crate) struct ChildProbeBudget;')
u = once(u, 'fn reserve_child_probe() -> Result<ChildProbeBudget, String> {',
         'pub(crate) fn reserve_child_probe() -> Result<ChildProbeBudget, String> {')
u = once(u, 'fn defer_reap(pid: libc::pid_t) {', 'pub(crate) fn defer_reap(pid: libc::pid_t) {')
u = once(u, 'pub(crate) fn kill_and_reap(pid: libc::pid_t) {\n',
         'pub(crate) fn kill_and_reap(pid: libc::pid_t) {\n    if pid <= 0 {\n        return;\n    }\n')
peek = r'''
/// Observe a direct child without releasing its PID. Group cleanup must keep
/// this ownership until the final signal; Child::try_wait reaps on Unix and
/// permits the numeric process-group ID to be reused.
pub(crate) fn peek_child_status(pid: libc::pid_t) -> io::Result<Option<ExitStatus>> {
    if pid <= 0 {
        return Err(io::Error::new(ErrorKind::InvalidInput, "invalid child PID"));
    }
    // SAFETY: zero is a valid initial siginfo_t. waitid fills the SIGCHLD
    // fields on an exit, or leaves si_pid zero when WNOHANG finds no exit.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    let result = unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            &mut info,
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { info.si_pid() } == 0 {
        return Ok(None);
    }
    let status = unsafe { info.si_status() };
    let raw = match info.si_code {
        libc::CLD_EXITED => status << 8,
        libc::CLD_KILLED => status,
        libc::CLD_DUMPED => status | 0x80,
        _ => return Err(io::Error::new(ErrorKind::InvalidData, "unexpected child wait status")),
    };
    Ok(Some(ExitStatus::from_raw(raw)))
}
'''
u = once(u, 'fn child_exit_code(status: i32) -> Option<i32> {',
         peek.lstrip() + '\nfn child_exit_code(status: i32) -> Option<i32> {')
# Do not signal a worker whose exit has already been collected, even if an
# unrelated inherited pipe delays EOF or a later read/poll fails.
a = u.index('    let mut output = Vec::with_capacity(max_bytes.min(4096));')
b = u.index('\npub(crate) fn read_proc_text_bounded', a)
segment = u[a:b]
assert segment.count('kill_and_reap(worker_pid);') == 5
segment = segment.replace('kill_and_reap(worker_pid);',
    'if worker_status.is_none() {\n                        kill_and_reap(worker_pid);\n                    }')
u = u[:a] + segment + u[b:]
# Captured-command polling observes status; it must not release the leader
# while pipe-holding descendants can still require process-group signals.
a = u.index('pub(crate) fn run_bounded_command(')
b = u.index('\ntrait CommandGroupWait', a)
segment = u[a:b]
segment = once(segment, 'match child.try_wait() {', 'match peek_child_status(child.id() as libc::pid_t) {')
segment = once(segment, '        if status.is_some() && stdout.closed() && stderr.closed() {\n            break;\n        }', r'''        if status.is_some() && stdout.closed() && stderr.closed() {
            // No more group signals can follow this final reap.
            match child.try_wait() {
                Ok(Some(exit)) => { status = Some(exit); break; }
                Ok(None) => {}
                Err(err) if err.kind() == ErrorKind::Interrupted => {}
                Err(err) => {
                    if err.raw_os_error() != Some(libc::ECHILD) {
                        let _ = terminate_command_group(&mut child);
                    }
                    return Err(format!("reap command: {err}"));
                }
            }
        }''')
u = u[:a] + segment + u[b:]
u = once(u, '    fn try_wait(&mut self) -> Result<Option<ExitStatus>, io::Error>;\n',
    '    // Implementations observe status without reaping until group signalling finishes.\n    fn try_wait(&mut self) -> Result<Option<ExitStatus>, io::Error>;\n')
u = once(u, '        Child::try_wait(self)\n',
    '        peek_child_status(self.id() as libc::pid_t)\n')
old = '''fn terminate_command_group(child: &mut Child) -> Option<ExitStatus> {
    let pid = child.pid();
    let status =
        terminate_command_group_with(child, Duration::from_millis(250), PROCESS_REAP_GRACE);
    if status.is_none() {
        defer_reap(pid);
    }
    status
}'''
new = '''fn terminate_command_group(child: &mut Child) -> Option<ExitStatus> {
    let pid = child.pid();
    // A caller that has already reaped the leader no longer owns this group
    // number. Never turn its cached Child::try_wait result into a signal.
    if peek_child_status(pid).is_err_and(|err| err.raw_os_error() == Some(libc::ECHILD)) {
        return None;
    }
    let observed =
        terminate_command_group_with(child, Duration::from_millis(250), PROCESS_REAP_GRACE);
    match Child::try_wait(child) {
        Ok(Some(status)) => Some(status),
        Err(err) if err.raw_os_error() == Some(libc::ECHILD) => observed,
        _ => {
            defer_reap(pid);
            observed
        }
    }
}'''
u = once(u, old, new)
# Both interrupted and not-yet-exited observations consume the same grace.
a = u.index('fn terminate_command_group_with<')
b = u.index('\nfn terminate_command_group(child:', a)
segment = u[a:b]
segment = segment.replace('            Err(_) => return None,\n            Ok(None) if Instant::now() >= term_deadline => break,\n            Ok(None) => thread::sleep(PROCESS_REAP_POLL),',
    '            Err(err) if err.kind() != ErrorKind::Interrupted => return None,\n            _ if Instant::now() >= term_deadline => break,\n            _ => thread::sleep(PROCESS_REAP_POLL),')
segment = segment.replace('            Err(_) => return None,\n            Ok(None) if Instant::now() >= reap_deadline => return None,\n            Ok(None) => thread::sleep(PROCESS_REAP_POLL),',
    '            Err(err) if err.kind() != ErrorKind::Interrupted => return None,\n            _ if Instant::now() >= reap_deadline => return None,\n            _ => thread::sleep(PROCESS_REAP_POLL),')
assert '            Err(_) => return None,' not in segment
u = u[:a] + segment + u[b:]
utils.write_text(u)

p = process.read_text()
p = once(p, '''    let mut watchdog = ParentDeathWatchdog::arm(timeout)?;''', '''    if timeout.is_zero() {
        return Err("command deadline expired before spawn".to_string());
    }
    // Reserve for both children before either fork/spawn. Deferred children
    // remain in the shared budget after these active permits are released.
    let _child_budget = crate::utils::reserve_child_probe()?;
    let _watchdog_budget = crate::utils::reserve_child_probe()?;
    let mut watchdog = ParentDeathWatchdog::arm(timeout)?;''')
p = once(p, '''            if !terminate_timed_out_child(
                &mut child,
                Duration::from_millis(100),
                Duration::from_millis(100),
            ) {
                defer_child_reap(child);
            }''', '''            terminate_timed_out_child(
                &mut child,
                Duration::from_millis(100),
                Duration::from_millis(100),
            );
            // All group signals precede the final reap. A D-state child is
            // transferred to the same reaper as captured commands/proc reads.
            match child.try_wait() {
                Ok(Some(_)) => {}
                Err(err) if err.raw_os_error() == Some(libc::ECHILD) => {}
                _ => defer_child_reap(child),
            }''')
p = once(p, '        self.try_wait().map(|status| status.is_some())',
         '        crate::utils::peek_child_status(self.id() as libc::pid_t)\n            .map(|status| status.is_some())')
# A signal storm must not skip the final SIGKILL or create an unbounded wait.
p = once(p, '            Err(_) => return true,\n            Ok(false) if Instant::now() >= term_deadline => break,\n            Ok(false) => thread::sleep(Duration::from_millis(10)),',
    '            Err(err) if err.kind() != io::ErrorKind::Interrupted => return true,\n            _ if Instant::now() >= term_deadline => break,\n            _ => thread::sleep(Duration::from_millis(10)),')
p = once(p, '            Ok(true) | Err(_) => return true,\n            Ok(false) if Instant::now() >= kill_deadline => return false,\n            Ok(false) => thread::sleep(Duration::from_millis(10)),',
    '            Ok(true) => return true,\n            Err(err) if err.kind() != io::ErrorKind::Interrupted => return true,\n            _ if Instant::now() >= kill_deadline => return false,\n            _ => thread::sleep(Duration::from_millis(10)),')
# This trait only observes exit now; its caller performs the final reap.
p = re.sub(r'\btry_reap\b', 'exit_ready', p)
old = '''fn defer_child_reap(mut child: std::process::Child) {
    let _ = thread::Builder::new()
        .name("magicnet-process-reaper".to_string())
        .spawn(move || loop {
            match child.try_wait() {
                Ok(Some(_)) | Err(_) => break,
                Ok(None) => thread::sleep(Duration::from_millis(250)),
            }
        });
}'''
new = '''fn defer_child_reap(child: std::process::Child) {
    // Child has no automatic reaping Drop. Explicitly transfer its wait
    // ownership; never create one persistent thread per lifecycle failure.
    crate::utils::defer_reap(child.id() as libc::pid_t);
}'''
p = once(p, old, new)
# Put admission regression next to the private lifecycle runner; run it in a
# fresh test process so other tests cannot consume or release its permits.
p += r'''

#[cfg(test)]
mod admission_review_tests {
    use super::*;

    #[test]
    fn lifecycle_admission_is_bounded_before_watchdog_fork() {
        const NAME: &str = "process::admission_review_tests::lifecycle_admission_is_bounded_before_watchdog_fork";
        if std::env::var("MAGICNET_LIFECYCLE_ADMISSION_CHILD").as_deref() != Ok(NAME) {
            let mut command = Command::new(std::env::current_exe().unwrap());
            command.args(["--exact", NAME, "--nocapture"])
                .env("MAGICNET_LIFECYCLE_ADMISSION_CHILD", NAME);
            let result = run_bounded_command(command, Duration::from_secs(10), 8192).unwrap();
            assert!(!result.timed_out);
            assert!(result.status.unwrap().success(), "{}{}",
                String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
            return;
        }
        let mut command = Command::new("sh");
        command.args(["-c", "exit 0"]);
        assert!(run_process_group(&mut command, Duration::ZERO).unwrap_err().contains("before spawn"));
        let mut permits = Vec::new();
        while let Ok(permit) = crate::utils::reserve_child_probe() { permits.push(permit); }
        assert!(!permits.is_empty());
        let fds = fs::read_dir("/proc/self/fd").unwrap().count();
        let error = run_process_group(&mut command, Duration::from_secs(1)).unwrap_err();
        assert!(error.contains("budget exhausted"));
        // One free slot is insufficient: the runner needs a worker and a watchdog.
        permits.pop();
        assert!(run_process_group(&mut command, Duration::from_secs(1)).unwrap_err().contains("budget exhausted"));
        assert_eq!(fs::read_dir("/proc/self/fd").unwrap().count(), fds);
        drop(permits);
        assert!(run_process_group(&mut command, Duration::from_secs(1)).unwrap().success());
    }
}
'''
process.write_text(p)

tests.write_text(tests.read_text().rstrip() + r'''

#[test]
fn peek_child_status_does_not_reap_or_steal_exit_status() {
    let mut child = shell("exit 7").spawn().unwrap();
    let pid = child.id() as libc::pid_t;
    let deadline = Instant::now() + Duration::from_secs(3);
    while super::peek_child_status(pid).unwrap().is_none() {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(super::peek_child_status(pid).unwrap().unwrap().code(), Some(7));
    assert_eq!(child.wait().unwrap().code(), Some(7));
    assert_eq!(super::peek_child_status(pid).unwrap_err().raw_os_error(), Some(libc::ECHILD));
    assert!(super::terminate_command_group(&mut child).is_none());
    assert_eq!(child.try_wait().unwrap().unwrap().code(), Some(7));
    for invalid in [0, -1] {
        assert_eq!(super::peek_child_status(invalid).unwrap_err().kind(), io::ErrorKind::InvalidInput);
    }
}

#[test]
fn command_group_retains_leader_through_final_signal() {
    use super::CommandGroupWait;
    use std::os::unix::process::CommandExt;

    struct CheckedGroup { child: std::process::Child, signals: Vec<libc::c_int> }
    impl CommandGroupWait for CheckedGroup {
        fn signal_group(&mut self, signal: libc::c_int) {
            assert!(super::peek_child_status(self.child.id() as libc::pid_t).is_ok(),
                "leader was reaped before the final group signal");
            self.signals.push(signal);
            self.child.signal_group(signal);
        }
        fn try_wait(&mut self) -> io::Result<Option<std::process::ExitStatus>> {
            <std::process::Child as CommandGroupWait>::try_wait(&mut self.child)
        }
        fn pid(&self) -> libc::pid_t { self.child.id() as libc::pid_t }
    }
    let mut command = shell("exit 9");
    command.process_group(0);
    let mut group = CheckedGroup { child: command.spawn().unwrap(), signals: Vec::new() };
    let deadline = Instant::now() + Duration::from_secs(3);
    while super::peek_child_status(group.pid()).unwrap().is_none() {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(10));
    }
    let observed = super::terminate_command_group_with(&mut group, Duration::from_millis(50), Duration::from_millis(50));
    assert_eq!(observed.unwrap().code(), Some(9));
    assert_eq!(group.signals, vec![libc::SIGTERM, libc::SIGKILL]);
    assert_eq!(group.child.wait().unwrap().code(), Some(9));
}

#[test]
fn peek_child_status_preserves_signal_exit() {
    let mut child = shell("exec sleep 30").spawn().unwrap();
    let pid = child.id() as libc::pid_t;
    child.kill().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while super::peek_child_status(pid).unwrap().is_none() {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(10));
    }
    let observed = super::peek_child_status(pid).unwrap().unwrap();
    assert_eq!(observed, child.wait().unwrap());
}

#[test]
fn interrupted_group_cleanup_still_kills_within_deadline() {
    struct Interrupted { signals: Vec<libc::c_int> }
    impl super::CommandGroupWait for Interrupted {
        fn signal_group(&mut self, signal: libc::c_int) { self.signals.push(signal); }
        fn try_wait(&mut self) -> io::Result<Option<std::process::ExitStatus>> {
            Err(io::Error::from(io::ErrorKind::Interrupted))
        }
        fn pid(&self) -> libc::pid_t { 42 }
    }
    let mut child = Interrupted { signals: Vec::new() };
    let started = Instant::now();
    assert!(super::terminate_command_group_with(
        &mut child, Duration::from_millis(20), Duration::from_millis(20)
    ).is_none());
    assert!(started.elapsed() < Duration::from_secs(1));
    assert_eq!(child.signals, vec![libc::SIGTERM, libc::SIGKILL]);
}
''' + '\n')
print('Applied PR #286 review fixes to utils.rs, process.rs and resource_limits.rs')
