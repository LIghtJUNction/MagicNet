use super::*;

// These tests fork before changing descriptors/rlimits/seccomp, so the test
// runner's process, descriptor table and security policy remain untouched.
unsafe fn run_fd_cleanup_case(force_fallback: bool, keep_stdin: bool) -> i32 {
    let child = libc::fork();
    assert!(child >= 0, "fork descriptor test");
    if child == 0 {
        let source = libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC);
        if source < 0 {
            libc::_exit(10);
        }
        let high = libc::fcntl(source, libc::F_DUPFD_CLOEXEC, 256);
        if high < 256 || libc::dup2(source, 0) != 0 {
            libc::_exit(11);
        }
        let mut limit = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) != 0 {
            libc::_exit(12);
        }
        limit.rlim_cur = 64;
        if libc::setrlimit(libc::RLIMIT_NOFILE, &limit) != 0 {
            libc::_exit(13);
        }
        if force_fallback {
            // Deny just close_range with ENOSYS to exercise the production
            // old-kernel path even when CI runs a modern kernel.
            let mut filter = [
                libc::sock_filter {
                    code: 0x20,
                    jt: 0,
                    jf: 0,
                    k: 0,
                },
                libc::sock_filter {
                    code: 0x15,
                    jt: 0,
                    jf: 1,
                    k: libc::SYS_close_range as u32,
                },
                libc::sock_filter {
                    code: 0x06,
                    jt: 0,
                    jf: 0,
                    k: 0x0005_0000 | libc::ENOSYS as u32,
                },
                libc::sock_filter {
                    code: 0x06,
                    jt: 0,
                    jf: 0,
                    k: 0x7fff_0000,
                },
            ];
            let program = libc::sock_fprog {
                len: filter.len() as u16,
                filter: filter.as_mut_ptr(),
            };
            if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
                || libc::prctl(libc::PR_SET_SECCOMP, 2, &program) != 0
            {
                libc::_exit(14);
            }
        }
        let second = if keep_stdin { 0 } else { source };
        close_inherited_fds_except(source, second);
        if libc::fcntl(source, libc::F_GETFD) < 0 {
            libc::_exit(20);
        }
        if keep_stdin && libc::fcntl(0, libc::F_GETFD) < 0 {
            libc::_exit(21);
        }
        if libc::fcntl(high, libc::F_GETFD) >= 0 {
            libc::_exit(22);
        }
        libc::_exit(0);
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let mut status = 0;
        let waited = libc::waitpid(child, &mut status, libc::WNOHANG);
        if waited == child {
            return status;
        }
        if waited < 0 && io::Error::last_os_error().kind() != ErrorKind::Interrupted {
            panic!("wait descriptor test: {}", io::Error::last_os_error());
        }
        if Instant::now() >= deadline {
            libc::kill(child, libc::SIGKILL);
            libc::waitpid(child, &mut status, 0);
            panic!("descriptor cleanup exceeded deadline");
        }
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn fallback_closes_descriptors_above_lowered_soft_limit() {
    assert_eq!(unsafe { run_fd_cleanup_case(true, false) }, 0);
}

#[test]
fn fallback_preserves_descriptor_zero_and_distinct_keeper() {
    assert_eq!(unsafe { run_fd_cleanup_case(true, true) }, 0);
}

#[test]
fn fast_cleanup_preserves_identical_keeper() {
    assert_eq!(unsafe { run_fd_cleanup_case(false, false) }, 0);
}

#[test]
fn fast_cleanup_preserves_descriptor_zero() {
    assert_eq!(unsafe { run_fd_cleanup_case(false, true) }, 0);
}
