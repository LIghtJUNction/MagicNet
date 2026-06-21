use super::loader::*;
use super::*;

pub(crate) fn query(opts: &Options) -> Result<(), String> {
    let cgroup_fd = open_dir(&opts.cgroup)?;
    for (name, attach_type) in [
        ("connect4", BPF_CGROUP_INET4_CONNECT),
        ("connect6", BPF_CGROUP_INET6_CONNECT),
        ("udp4_dns", BPF_CGROUP_UDP4_SENDMSG),
        ("udp6_dns", BPF_CGROUP_UDP6_SENDMSG),
    ] {
        print_query(cgroup_fd, name, attach_type, 0)?;
        print_query(cgroup_fd, name, attach_type, BPF_F_QUERY_EFFECTIVE)?;
    }
    close_fd(cgroup_fd);
    Ok(())
}

pub(crate) fn set_netd_flags(opts: &Options, attach_flags: u32, label: &str) -> Result<(), String> {
    fs::create_dir_all(&opts.state_dir)
        .map_err(|err| format!("create state dir {}: {err}", opts.state_dir.display()))?;
    let lock_fd = open_lock(&opts.state_dir.join("netd-reflag.lock"))?;
    flock_exclusive(lock_fd)?;

    let netd = open_netd_programs()?;
    let (cgroup_fd, cgroup_path) = open_netd_attach_cgroup(opts, &netd, attach_flags)?;
    let result: Result<(), String> = (|| {
        for program in &netd {
            validate_netd_state(cgroup_fd, program, attach_flags)?;
        }
        reflag_netd_programs(cgroup_fd, &netd, attach_flags)?;
        for program in &netd {
            verify_netd_state(cgroup_fd, program, attach_flags)?;
        }
        Ok(())
    })();
    close_fd(cgroup_fd);
    close_fd(lock_fd);
    result?;
    println!("netd_cgroup={}", cgroup_path.display());
    println!("{label}=ok");
    Ok(())
}

fn open_netd_attach_cgroup(
    opts: &Options,
    netd: &[NetdProgram],
    target_flags: u32,
) -> Result<(RawFd, PathBuf), String> {
    let mut last_error = None;
    for path in netd_attach_cgroup_candidates(&opts.cgroup) {
        let Ok(fd) = open_dir(&path) else {
            continue;
        };
        let valid = netd
            .iter()
            .try_for_each(|program| validate_netd_state(fd, program, target_flags));
        match valid {
            Ok(()) => return Ok((fd, path)),
            Err(err) => {
                close_fd(fd);
                last_error = Some(err);
            }
        }
    }
    Err(last_error.unwrap_or_else(|| {
        format!(
            "netd cgroup attach point not found from {}",
            opts.cgroup.display()
        )
    }))
}

fn netd_attach_cgroup_candidates(cgroup: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut current = cgroup.to_path_buf();
    loop {
        push_unique_path(&mut out, current.clone());
        if current == Path::new("/sys/fs/cgroup") {
            break;
        }
        if !current.pop() {
            break;
        }
        if !current.starts_with("/sys/fs/cgroup") {
            break;
        }
    }
    push_unique_path(&mut out, PathBuf::from("/sys/fs/cgroup"));
    out
}

fn push_unique_path(out: &mut Vec<PathBuf>, path: PathBuf) {
    if !out.iter().any(|existing| existing == &path) {
        out.push(path);
    }
}

fn open_netd_programs() -> Result<Vec<NetdProgram>, String> {
    let required = [BPF_CGROUP_INET4_CONNECT, BPF_CGROUP_INET6_CONNECT];
    let optional = [BPF_CGROUP_UDP4_SENDMSG, BPF_CGROUP_UDP6_SENDMSG];
    let mut programs = Vec::with_capacity(required.len() + optional.len());
    for attach_type in required {
        programs.push(open_netd_program(attach_type)?);
    }
    for attach_type in optional {
        if let Some(path) = netd_program_path(attach_type) {
            if path.exists() {
                programs.push(NetdProgram::open(attach_type, path)?);
            }
        }
    }
    Ok(programs)
}

pub(crate) fn open_netd_program(attach_type: u32) -> Result<NetdProgram, String> {
    let path = netd_program_path(attach_type)
        .ok_or_else(|| format!("unknown netd attach type: {attach_type}"))?;
    NetdProgram::open(attach_type, path)
}

pub(crate) fn find_netd_cgroup_path() -> Option<PathBuf> {
    let proc = fs::read_dir("/proc").ok()?;
    for entry in proc.flatten() {
        let pid = entry.file_name();
        let pid = pid.to_string_lossy();
        if pid.as_bytes().iter().any(|byte| !byte.is_ascii_digit()) {
            continue;
        }
        let dir = entry.path();
        if !is_netd_process(&dir) {
            continue;
        }
        if let Some(path) = read_cgroup_path(&dir.join("cgroup")) {
            return Some(path);
        }
    }
    None
}

fn is_netd_process(dir: &Path) -> bool {
    fs::read_to_string(dir.join("comm"))
        .map(|comm| comm.trim() == "netd")
        .unwrap_or(false)
        || fs::read(dir.join("cmdline"))
            .ok()
            .and_then(|cmdline| {
                cmdline
                    .split(|byte| *byte == 0)
                    .find(|arg| !arg.is_empty())
                    .map(|arg| String::from_utf8_lossy(arg).into_owned())
            })
            .and_then(|arg0| {
                Path::new(&arg0)
                    .file_name()
                    .map(|name| name.to_string_lossy() == "netd")
            })
            .unwrap_or(false)
}

fn read_cgroup_path(path: &Path) -> Option<PathBuf> {
    let content = fs::read_to_string(path).ok()?;
    for line in content.lines() {
        let Some(cgroup) = line.strip_prefix("0::") else {
            continue;
        };
        let mut out = PathBuf::from("/sys/fs/cgroup");
        if cgroup != "/" {
            out.push(cgroup.trim_start_matches('/'));
        }
        return Some(out);
    }
    None
}

fn netd_program_path(attach_type: u32) -> Option<&'static Path> {
    match attach_type {
        BPF_CGROUP_INET4_CONNECT => Some(Path::new(
            "/sys/fs/bpf/netd_shared/prog_netd_connect4_inet4_connect",
        )),
        BPF_CGROUP_INET6_CONNECT => Some(Path::new(
            "/sys/fs/bpf/netd_shared/prog_netd_connect6_inet6_connect",
        )),
        BPF_CGROUP_UDP4_SENDMSG => Some(Path::new(
            "/sys/fs/bpf/netd_shared/prog_netd_sendmsg4_udp4_sendmsg",
        )),
        BPF_CGROUP_UDP6_SENDMSG => Some(Path::new(
            "/sys/fs/bpf/netd_shared/prog_netd_sendmsg6_udp6_sendmsg",
        )),
        _ => None,
    }
}

pub(crate) struct NetdProgram {
    pub(crate) attach_type: u32,
    pub(crate) path: PathBuf,
    pub(crate) fd: RawFd,
    pub(crate) id: u32,
}

impl NetdProgram {
    fn open(attach_type: u32, path: &Path) -> Result<Self, String> {
        let fd = obj_get(path)?;
        let id = match prog_id(fd) {
            Ok(id) => id,
            Err(err) => {
                close_fd(fd);
                return Err(err);
            }
        };
        Ok(Self {
            attach_type,
            path: path.to_path_buf(),
            fd,
            id,
        })
    }
}

impl Drop for NetdProgram {
    fn drop(&mut self) {
        close_fd(self.fd);
    }
}

fn validate_netd_state(
    cgroup_fd: RawFd,
    netd: &NetdProgram,
    target_flags: u32,
) -> Result<(), String> {
    let current = query_attached(cgroup_fd, netd.attach_type, 0)?;
    if current.prog_ids != [netd.id] {
        return Err(format!(
            "refusing to reflag {}: direct cgroup program list is {:?}, expected only netd prog {}",
            netd.path.display(),
            current.prog_ids,
            netd.id
        ));
    }
    if current.attach_flags == target_flags {
        return Ok(());
    }
    if current.attach_flags != 0 && current.attach_flags != BPF_F_ALLOW_MULTI {
        return Err(format!(
            "refusing to reflag {}: unsupported existing attach_flags={}",
            netd.path.display(),
            current.attach_flags
        ));
    }
    Ok(())
}

fn verify_netd_state(
    cgroup_fd: RawFd,
    netd: &NetdProgram,
    target_flags: u32,
) -> Result<(), String> {
    let current = query_attached(cgroup_fd, netd.attach_type, 0)?;
    if current.attach_flags != target_flags || current.prog_ids != [netd.id] {
        return Err(format!(
            "netd reflag verification failed for {}: flags={}, progs={:?}, expected flags={}, progs=[{}]",
            netd.path.display(),
            current.attach_flags,
            current.prog_ids,
            target_flags,
            netd.id
        ));
    }
    Ok(())
}

fn reflag_netd_programs(
    cgroup_fd: RawFd,
    programs: &[NetdProgram],
    attach_flags: u32,
) -> Result<(), String> {
    for program in programs {
        if let Err(err) = reflag_netd_one(cgroup_fd, program, attach_flags) {
            for rollback in programs {
                attach_prog_flags(cgroup_fd, rollback.fd, rollback.attach_type, 0).ok();
            }
            return Err(err);
        }
    }
    Ok(())
}

fn reflag_netd_one(cgroup_fd: RawFd, netd: &NetdProgram, attach_flags: u32) -> Result<(), String> {
    let current = query_attached(cgroup_fd, netd.attach_type, 0)?;
    if current.attach_flags == attach_flags {
        return Ok(());
    }

    // Keep this detach/attach gap intentionally tiny: both FDs are already open,
    // state was validated, and no logging or filesystem work is done here.
    detach_prog(cgroup_fd, netd.fd, netd.attach_type)?;
    if let Err(err) = attach_prog_flags(cgroup_fd, netd.fd, netd.attach_type, attach_flags) {
        let rollback = attach_prog_flags(cgroup_fd, netd.fd, netd.attach_type, 0);
        return Err(format!(
            "set flags for {} failed ({err}); rollback={}",
            netd.path.display(),
            if rollback.is_ok() { "ok" } else { "failed" }
        ));
    }
    Ok(())
}

fn print_query(
    cgroup_fd: RawFd,
    name: &str,
    attach_type: u32,
    query_flags: u32,
) -> Result<(), String> {
    let attached = query_attached(cgroup_fd, attach_type, query_flags)?;
    let scope = if query_flags == BPF_F_QUERY_EFFECTIVE {
        "effective"
    } else {
        "direct"
    };
    println!(
        "{name}.{scope}: count={}, attach_flags={}",
        attached.prog_ids.len(),
        attached.attach_flags
    );
    for (index, prog_id) in attached.prog_ids.iter().enumerate() {
        println!("{name}.{scope}[{index}]: prog_id={}", prog_id);
    }
    Ok(())
}

pub(crate) struct AttachedPrograms {
    pub(crate) attach_flags: u32,
    pub(crate) prog_ids: Vec<u32>,
}

pub(crate) fn query_attached(
    cgroup_fd: RawFd,
    attach_type: u32,
    query_flags: u32,
) -> Result<AttachedPrograms, String> {
    let mut prog_ids = [0u32; 64];
    let mut attr = BpfAttrProgQuery {
        target_fd: cgroup_fd as u32,
        attach_type,
        query_flags,
        prog_ids: prog_ids.as_mut_ptr() as u64,
        prog_cnt: prog_ids.len() as u32,
        ..Default::default()
    };
    bpf(BPF_PROG_QUERY, &mut attr)?;
    let count = (attr.prog_cnt as usize).min(prog_ids.len());
    Ok(AttachedPrograms {
        attach_flags: attr.attach_flags,
        prog_ids: prog_ids[..count].to_vec(),
    })
}

pub(crate) fn restore_netd_if_missing(cgroup_fd: RawFd, attach_type: u32) -> Result<(), String> {
    let netd = open_netd_program(attach_type)?;
    let current = query_attached(cgroup_fd, attach_type, 0)?;
    if current.prog_ids.contains(&netd.id) {
        return Ok(());
    }
    attach_prog_flags(cgroup_fd, netd.fd, attach_type, 0)
}
