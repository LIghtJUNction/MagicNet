use std::os::fd::RawFd;

// A fork-only worker must not retain the parent's pipes, executable writers,
// or locks. Do not use allocating directory iterators in a multithreaded fork.
//
// Safety: only call in a fork child with a private descriptor table. Both
// keepers must be nonnegative; no other descriptor may be used afterwards.
pub(crate) unsafe fn close_inherited_fds_except(keep_a: RawFd, keep_b: RawFd) {
    let (low, high) = if keep_a <= keep_b {
        (keep_a as u32, keep_b as u32)
    } else {
        (keep_b as u32, keep_a as u32)
    };
    let close_range = |first: u32, last: u32| {
        first > last || libc::syscall(libc::SYS_close_range, first, last, 0) == 0
    };
    if (low == 0 || close_range(0, low - 1))
        && (low == high || close_range(low + 1, high - 1))
        && close_range(high + 1, u32::MAX)
    {
        return;
    }

    // Older kernels (or seccomp profiles) may not support close_range. Scan
    // actual descriptors rather than issuing RLIMIT_NOFILE close syscalls
    // for every proc read. This also finds handles above a lowered soft limit.
    if close_from_proc(keep_a, keep_b) {
        return;
    }

    // Last resort when procfs itself is unavailable. Use the hard limit:
    // lowering the soft limit does not invalidate already-open descriptors.
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    let max_fd = if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0 {
        limit.rlim_max.min(libc::c_int::MAX as libc::rlim_t) as RawFd
    } else {
        65_536
    };
    for fd in 0..max_fd {
        if fd != keep_a && fd != keep_b {
            libc::close(fd);
        }
    }
}

unsafe fn close_from_proc(keep_a: RawFd, keep_b: RawFd) -> bool {
    let directory = libc::open(
        c"/proc/self/fd".as_ptr(),
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
    );
    if directory < 0 {
        return false;
    }
    // Linux getdents64 has a 19-byte fixed header followed by a NUL-terminated
    // name. Decode byte fields explicitly; records need not be Rust-aligned.
    let mut buffer = [0_u8; 4096];
    let complete = loop {
        let read = libc::syscall(
            libc::SYS_getdents64,
            directory,
            buffer.as_mut_ptr(),
            buffer.len(),
        );
        if read == 0 {
            break true;
        }
        if read < 0 {
            if super::child_errno() == libc::EINTR {
                continue;
            }
            break false;
        }
        let mut remaining = &buffer[..read as usize];
        let mut valid = true;
        while !remaining.is_empty() {
            let Some((name, rest)) = next_name(remaining) else {
                valid = false;
                break;
            };
            if let Some(fd) = descriptor_number(name) {
                if fd != directory && fd != keep_a && fd != keep_b {
                    libc::close(fd);
                }
            }
            remaining = rest;
        }
        if !valid {
            break false;
        }
    };
    libc::close(directory);
    complete
}

fn next_name(bytes: &[u8]) -> Option<(&[u8], &[u8])> {
    const NAME_OFFSET: usize = 19;
    if bytes.len() <= NAME_OFFSET {
        return None;
    }
    let length = u16::from_ne_bytes([bytes[16], bytes[17]]) as usize;
    if length <= NAME_OFFSET || length > bytes.len() {
        return None;
    }
    let name = &bytes[NAME_OFFSET..length];
    let end = name.iter().position(|byte| *byte == 0)?;
    Some((&name[..end], &bytes[length..]))
}

fn descriptor_number(name: &[u8]) -> Option<RawFd> {
    if name.is_empty() {
        return None;
    }
    name.iter().try_fold(0_i32, |fd, byte| {
        if !byte.is_ascii_digit() {
            return None;
        }
        fd.checked_mul(10)?.checked_add((byte - b'0') as i32)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_names_are_strict_and_checked() {
        assert_eq!(descriptor_number(b"0"), Some(0));
        assert_eq!(descriptor_number(b"2147483647"), Some(i32::MAX));
        for invalid in [b"".as_slice(), b".", b"..", b"-1", b"3x", b"2147483648"] {
            assert_eq!(descriptor_number(invalid), None);
        }
    }

    #[test]
    fn directory_records_advance_and_reject_truncation() {
        let mut record = [0_u8; 24];
        record[16..18].copy_from_slice(&24_u16.to_ne_bytes());
        record[19..22].copy_from_slice(b"256");
        let joined = [record, record].concat();
        let (name, rest) = next_name(&joined).unwrap();
        assert_eq!(name, b"256");
        assert_eq!(rest.len(), 24);
        assert_eq!(next_name(rest).unwrap().1.len(), 0);
        for size in 0..24 {
            assert!(next_name(&record[..size]).is_none());
        }
        for bad_length in [0_u16, 19, 25] {
            record[16..18].copy_from_slice(&bad_length.to_ne_bytes());
            assert!(next_name(&record).is_none());
        }
        record[16..18].copy_from_slice(&24_u16.to_ne_bytes());
        record[19..].fill(b'1');
        assert!(next_name(&record).is_none());
    }
}
