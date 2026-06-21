use super::programs::*;
use super::udp_programs::*;
use super::*;

pub(crate) fn ensure_runtime_ready(opts: &Options) -> Result<(), String> {
    if !bpffs_ready() {
        return Err("/sys/fs/bpf is not mounted as bpffs".to_string());
    }
    if !opts.cgroup.is_dir() {
        return Err(format!("cgroup path not found: {}", opts.cgroup.display()));
    }
    if !opts.dns_cgroup.is_dir() {
        return Err(format!(
            "DNS cgroup path not found: {}",
            opts.dns_cgroup.display()
        ));
    }
    Ok(())
}

pub(crate) fn bpffs_ready() -> bool {
    fs::read_to_string("/proc/mounts")
        .map(|mounts| {
            mounts.lines().any(|line| {
                line.split_whitespace().collect::<Vec<_>>().as_slice()
                    == ["/sys/fs/bpf", "/sys/fs/bpf", "bpf"]
                    || {
                        let cols: Vec<&str> = line.split_whitespace().collect();
                        cols.len() >= 3 && cols[1] == "/sys/fs/bpf" && cols[2] == "bpf"
                    }
            })
        })
        .unwrap_or(false)
}

pub(crate) fn btf_ready() -> bool {
    Path::new("/sys/kernel/btf/vmlinux").is_file()
        || fs::read_to_string("/proc/config.gz")
            .ok()
            .map(|_| false)
            .unwrap_or(false)
}

pub(crate) fn load_allow_prog(name: &str, attach_type: u32) -> Result<RawFd, String> {
    let insns = [BpfInsn::mov64_imm(BPF_REG_0, 1), BpfInsn::exit()];
    let license = CString::new("GPL").map_err(|err| err.to_string())?;
    let mut log_buf = vec![0u8; 64 * 1024];
    let mut attr = BpfAttrProgLoad {
        prog_type: BPF_PROG_TYPE_CGROUP_SOCK_ADDR,
        insn_cnt: insns.len() as u32,
        insns: insns.as_ptr() as u64,
        license: license.as_ptr() as u64,
        log_level: 1,
        log_size: log_buf.len() as u32,
        log_buf: log_buf.as_mut_ptr() as u64,
        expected_attach_type: attach_type,
        ..Default::default()
    };
    set_bpf_name(&mut attr.prog_name, name);

    let fd = bpf(BPF_PROG_LOAD, &mut attr)?;
    Ok(fd)
}

pub(crate) fn load_connect_prog(
    name: &str,
    attach_type: u32,
    cookie_map_fd: RawFd,
    bridge_port: u16,
    dns_port: u16,
    tcp6_mode: Tcp6Mode,
    dns_redirect: bool,
    ipv6: bool,
) -> Result<RawFd, String> {
    let insns = build_connect_prog(
        cookie_map_fd,
        bridge_port,
        dns_port,
        tcp6_mode,
        dns_redirect,
        ipv6,
    )?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

pub(crate) fn load_udp_dns_prog(
    name: &str,
    attach_type: u32,
    dns_port: u16,
    ipv6: bool,
    block_non_dns: bool,
) -> Result<RawFd, String> {
    let insns = build_udp_dns_prog(dns_port, ipv6, block_non_dns)?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

pub(crate) fn load_udp443_probe_prog(
    name: &str,
    attach_type: u32,
    ipv6: bool,
) -> Result<RawFd, String> {
    let insns = build_udp443_probe_prog(ipv6)?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

pub(crate) fn load_udp_cookie_probe_prog(
    name: &str,
    attach_type: u32,
    cookie_map_fd: RawFd,
    ipv6: bool,
) -> Result<RawFd, String> {
    let insns = build_udp_cookie_probe_prog(cookie_map_fd, ipv6)?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

pub(crate) fn load_udp_post_bind_probe_prog(
    name: &str,
    attach_type: u32,
    port_map_fd: RawFd,
    ipv6: bool,
) -> Result<RawFd, String> {
    let insns = build_udp_post_bind_probe_prog(port_map_fd, ipv6)?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

pub(crate) fn load_udp_token_probe_prog(
    name: &str,
    attach_type: u32,
    token_map_fd: RawFd,
    bridge_port: u16,
    ipv6: bool,
) -> Result<RawFd, String> {
    let insns = build_udp_token_probe_prog(token_map_fd, bridge_port, ipv6)?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

pub(crate) fn load_netd_dns_connect_prog(
    name: &str,
    attach_type: u32,
    dns_port: u16,
    ipv6: bool,
) -> Result<RawFd, String> {
    let insns = build_netd_dns_connect_prog(dns_port, ipv6)?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

pub(crate) fn load_sockops_prog(
    name: &str,
    cookie_map_fd: RawFd,
    peer_map_fd: RawFd,
) -> Result<RawFd, String> {
    let insns = build_sockops_prog(cookie_map_fd, peer_map_fd)?;
    load_prog(name, BPF_PROG_TYPE_SOCK_OPS, BPF_CGROUP_SOCK_OPS, &insns)
}

pub(crate) fn load_prog(
    name: &str,
    prog_type: u32,
    attach_type: u32,
    insns: &[BpfInsn],
) -> Result<RawFd, String> {
    let license = CString::new("GPL").map_err(|err| err.to_string())?;
    let mut log_buf = vec![0u8; 256 * 1024];
    let mut attr = BpfAttrProgLoad {
        prog_type,
        insn_cnt: insns.len() as u32,
        insns: insns.as_ptr() as u64,
        license: license.as_ptr() as u64,
        log_level: 1,
        log_size: log_buf.len() as u32,
        log_buf: log_buf.as_mut_ptr() as u64,
        expected_attach_type: attach_type,
        ..Default::default()
    };
    set_bpf_name(&mut attr.prog_name, name);

    match bpf(BPF_PROG_LOAD, &mut attr) {
        Ok(fd) => Ok(fd),
        Err(err) => {
            let nul = log_buf
                .iter()
                .position(|b| *b == 0)
                .unwrap_or(log_buf.len());
            let log = String::from_utf8_lossy(&log_buf[..nul]);
            Err(format!("{err}; verifier={log}"))
        }
    }
}

pub(crate) fn create_cookie_map() -> Result<RawFd, String> {
    let mut attr = BpfAttrMapCreate {
        map_type: BPF_MAP_TYPE_LRU_HASH,
        key_size: mem::size_of::<u64>() as u32,
        value_size: ORIG_SIZE as u32,
        max_entries: 65536,
        map_flags: 0,
        ..Default::default()
    };
    set_bpf_name(&mut attr.map_name, "mn_cookie_dst");
    bpf(BPF_MAP_CREATE, &mut attr)
}

pub(crate) fn create_cookie_port_map() -> Result<RawFd, String> {
    let mut attr = BpfAttrMapCreate {
        map_type: BPF_MAP_TYPE_LRU_HASH,
        key_size: mem::size_of::<u64>() as u32,
        value_size: mem::size_of::<u32>() as u32,
        max_entries: 65536,
        map_flags: 0,
        ..Default::default()
    };
    set_bpf_name(&mut attr.map_name, "mn_cookie_port");
    bpf(BPF_MAP_CREATE, &mut attr)
}

pub(crate) fn create_token_map() -> Result<RawFd, String> {
    let mut attr = BpfAttrMapCreate {
        map_type: BPF_MAP_TYPE_LRU_HASH,
        key_size: mem::size_of::<u32>() as u32,
        value_size: ORIG_SIZE as u32,
        max_entries: 65536,
        map_flags: 0,
        ..Default::default()
    };
    set_bpf_name(&mut attr.map_name, "mn_udp_token");
    bpf(BPF_MAP_CREATE, &mut attr)
}

pub(crate) fn create_peer_map() -> Result<RawFd, String> {
    let mut attr = BpfAttrMapCreate {
        map_type: BPF_MAP_TYPE_LRU_HASH,
        key_size: PEER_KEY_SIZE as u32,
        value_size: ORIG_SIZE as u32,
        max_entries: 65536,
        map_flags: 0,
        ..Default::default()
    };
    set_bpf_name(&mut attr.map_name, "mn_peer_dst");
    bpf(BPF_MAP_CREATE, &mut attr)
}

pub(crate) fn attach_prog(
    cgroup_fd: RawFd,
    prog_fd: RawFd,
    attach_type: u32,
) -> Result<(), String> {
    attach_prog_flags(cgroup_fd, prog_fd, attach_type, 0)
}

pub(crate) fn attach_prog_flags(
    cgroup_fd: RawFd,
    prog_fd: RawFd,
    attach_type: u32,
    attach_flags: u32,
) -> Result<(), String> {
    let mut attr = BpfAttrAttach {
        target_fd: cgroup_fd as u32,
        attach_bpf_fd: prog_fd as u32,
        attach_type,
        attach_flags,
        ..Default::default()
    };
    bpf(BPF_PROG_ATTACH, &mut attr).map(|fd| {
        if fd > 0 {
            close_fd(fd);
        }
    })
}

pub(crate) fn attach_any(
    cgroup_fd: RawFd,
    prog_fd: RawFd,
    attach_type: u32,
) -> Result<Option<RawFd>, String> {
    match link_create(cgroup_fd, prog_fd, attach_type) {
        Ok(link_fd) => Ok(Some(link_fd)),
        Err(link_err) => match attach_prog(cgroup_fd, prog_fd, attach_type) {
            Ok(()) => Ok(None),
            Err(attach_err) => Err(format!(
                "link_create failed ({link_err}); prog_attach failed ({attach_err})"
            )),
        },
    }
}

pub(crate) fn link_create(
    cgroup_fd: RawFd,
    prog_fd: RawFd,
    attach_type: u32,
) -> Result<RawFd, String> {
    let mut attr = BpfAttrLinkCreate {
        prog_fd: prog_fd as u32,
        target_fd: cgroup_fd as u32,
        attach_type,
        flags: 0,
    };
    bpf(BPF_LINK_CREATE, &mut attr)
}

pub(crate) fn detach_prog(
    cgroup_fd: RawFd,
    prog_fd: RawFd,
    attach_type: u32,
) -> Result<(), String> {
    let mut attr = BpfAttrAttach {
        target_fd: cgroup_fd as u32,
        attach_bpf_fd: prog_fd as u32,
        attach_type,
        ..Default::default()
    };
    bpf(BPF_PROG_DETACH, &mut attr).map(|fd| {
        if fd > 0 {
            close_fd(fd);
        }
    })
}

pub(crate) fn detach_attached(
    cgroup_fd: RawFd,
    prog_fd: RawFd,
    attach_type: u32,
    link: Option<RawFd>,
) {
    if let Some(link_fd) = link {
        close_fd(link_fd);
    } else {
        detach_prog(cgroup_fd, prog_fd, attach_type).ok();
    }
}

pub(crate) fn pin_fd(fd: RawFd, path: &Path) -> Result<(), String> {
    if path.exists() {
        fs::remove_file(path).map_err(|err| format!("remove old pin {}: {err}", path.display()))?;
    }
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("path contains NUL: {}", path.display()))?;
    let mut attr = BpfAttrObj {
        pathname: c_path.as_ptr() as u64,
        bpf_fd: fd as u32,
        ..Default::default()
    };
    bpf(BPF_OBJ_PIN, &mut attr).map(|_| ())
}

pub(crate) fn obj_get(path: &Path) -> Result<RawFd, String> {
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("path contains NUL: {}", path.display()))?;
    let mut attr = BpfAttrObj {
        pathname: c_path.as_ptr() as u64,
        ..Default::default()
    };
    bpf(BPF_OBJ_GET, &mut attr)
}

pub(crate) fn prog_id(fd: RawFd) -> Result<u32, String> {
    let mut info = BpfProgInfoHead::default();
    let mut attr = BpfAttrInfo {
        bpf_fd: fd as u32,
        info_len: mem::size_of::<BpfProgInfoHead>() as u32,
        info: &mut info as *mut BpfProgInfoHead as u64,
    };
    bpf(BPF_OBJ_GET_INFO_BY_FD, &mut attr)?;
    if info.id == 0 {
        Err("BPF program id is zero".to_string())
    } else {
        Ok(info.id)
    }
}

pub(crate) fn open_dir(path: &Path) -> Result<RawFd, String> {
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("path contains NUL: {}", path.display()))?;
    let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) };
    if fd < 0 {
        Err(last_os_error(format!("open {}", path.display())))
    } else {
        Ok(fd)
    }
}

pub(crate) fn open_lock(path: &Path) -> Result<RawFd, String> {
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("path contains NUL: {}", path.display()))?;
    let fd = unsafe {
        libc::open(
            c_path.as_ptr(),
            libc::O_RDWR | libc::O_CREAT | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        Err(last_os_error(format!("open lock {}", path.display())))
    } else {
        Ok(fd)
    }
}

pub(crate) fn flock_exclusive(fd: RawFd) -> Result<(), String> {
    let rc = unsafe { libc::flock(fd, libc::LOCK_EX) };
    if rc < 0 {
        Err(last_os_error("flock netd reflag lock".to_string()))
    } else {
        Ok(())
    }
}

pub(crate) fn bpf<T>(cmd: u32, attr: &mut T) -> Result<RawFd, String> {
    let ret = unsafe {
        libc::syscall(
            libc::SYS_bpf,
            cmd,
            attr as *mut T as *mut c_void,
            mem::size_of::<T>(),
        )
    };
    if ret < 0 {
        Err(last_os_error(format!("bpf cmd {cmd}")))
    } else {
        Ok(ret as RawFd)
    }
}

pub(crate) fn set_bpf_name(target: &mut [u8; 16], name: &str) {
    let bytes = name.as_bytes();
    let len = bytes.len().min(target.len() - 1);
    target[..len].copy_from_slice(&bytes[..len]);
}

pub(crate) fn pin_root() -> &'static Path {
    Path::new("/sys/fs/bpf/magicnet")
}

pub(crate) fn pin_path(name: &str) -> PathBuf {
    pin_root().join(name)
}

pub(crate) fn close_fd(fd: RawFd) {
    unsafe {
        libc::close(fd);
    }
}

pub(crate) fn last_os_error(context: String) -> String {
    format!("{context}: {}", std::io::Error::last_os_error())
}

pub(crate) fn yes(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}
