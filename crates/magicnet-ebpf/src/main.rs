use std::collections::HashMap;
use std::env;
use std::ffi::{c_void, CString};
use std::fs;
use std::io::{Read, Write};
use std::mem;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::os::fd::RawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const BPF_MAP_CREATE: u32 = 0;
const BPF_MAP_LOOKUP_ELEM: u32 = 1;
const BPF_PROG_LOAD: u32 = 5;
const BPF_OBJ_PIN: u32 = 6;
const BPF_OBJ_GET: u32 = 7;
const BPF_PROG_ATTACH: u32 = 8;
const BPF_PROG_DETACH: u32 = 9;
const BPF_OBJ_GET_INFO_BY_FD: u32 = 15;
const BPF_PROG_QUERY: u32 = 16;
const BPF_LINK_CREATE: u32 = 28;

const BPF_MAP_TYPE_LRU_HASH: u32 = 9;
const BPF_PROG_TYPE_SOCK_OPS: u32 = 13;
const BPF_PROG_TYPE_CGROUP_SOCK_ADDR: u32 = 18;
const BPF_CGROUP_SOCK_OPS: u32 = 3;
const BPF_CGROUP_INET4_CONNECT: u32 = 10;
const BPF_CGROUP_INET6_CONNECT: u32 = 11;
const BPF_CGROUP_UDP4_SENDMSG: u32 = 14;
const BPF_CGROUP_UDP6_SENDMSG: u32 = 15;
const BPF_F_QUERY_EFFECTIVE: u32 = 1;
const BPF_F_ALLOW_MULTI: u32 = 1 << 1;

const BPF_LD: u8 = 0x00;
const BPF_LDX: u8 = 0x01;
const BPF_ST: u8 = 0x02;
const BPF_STX: u8 = 0x03;
const BPF_W: u8 = 0x00;
const BPF_DW: u8 = 0x18;
const BPF_IMM: u8 = 0x00;
const BPF_MEM: u8 = 0x60;
const BPF_ALU64: u8 = 0x07;
const BPF_ADD: u8 = 0x00;
const BPF_AND: u8 = 0x50;
const BPF_MOV: u8 = 0xb0;
const BPF_K: u8 = 0x00;
const BPF_X: u8 = 0x08;
const BPF_JMP: u8 = 0x05;
const BPF_JA: u8 = 0x00;
const BPF_JEQ: u8 = 0x10;
const BPF_JNE: u8 = 0x50;
const BPF_CALL: u8 = 0x80;
const BPF_EXIT: u8 = 0x90;

const BPF_REG_0: u8 = 0;
const BPF_REG_1: u8 = 1;
const BPF_REG_2: u8 = 2;
const BPF_REG_3: u8 = 3;
const BPF_REG_4: u8 = 4;
const BPF_REG_6: u8 = 6;
const BPF_REG_7: u8 = 7;
const BPF_REG_10: u8 = 10;
const BPF_PSEUDO_MAP_FD: u8 = 1;
const BPF_ANY: u64 = 0;
const BPF_FUNC_MAP_LOOKUP_ELEM: i32 = 1;
const BPF_FUNC_MAP_UPDATE_ELEM: i32 = 2;
const BPF_FUNC_MAP_DELETE_ELEM: i32 = 3;
const BPF_FUNC_GET_SOCKET_COOKIE: i32 = 46;

const PROG4_PIN: &str = "connect4_allow";
const PROG6_PIN: &str = "connect6_allow";
const UDP4_DNS_PIN: &str = "udp4_dns";
const UDP6_DNS_PIN: &str = "udp6_dns";
const SOCKOPS_PIN: &str = "sockops_index";
const COOKIE_MAP_PIN: &str = "cookie_original_dst";
const PEER_MAP_PIN: &str = "peer_original_dst";
const LINK4_PIN: &str = "connect4_link";
const LINK6_PIN: &str = "connect6_link";
const UDP4_DNS_LINK_PIN: &str = "udp4_dns_link";
const UDP6_DNS_LINK_PIN: &str = "udp6_dns_link";
const SOCKOPS_LINK_PIN: &str = "sockops_link";
const STATE_FILE: &str = "magicnet-ebpf.state";

const AF_INET: u32 = 2;
const AF_INET6: u32 = 10;
const IPPROTO_TCP: u32 = 6;
const SOCK_STREAM: u32 = 1;
const SOCK_OPS_ACTIVE_ESTABLISHED_CB: u32 = 4;

const SOCK_ADDR_USER_IP4: i16 = 4;
const SOCK_ADDR_USER_IP6: i16 = 8;
const SOCK_ADDR_USER_PORT: i16 = 24;
const SOCK_ADDR_TYPE: i16 = 32;
const SOCK_ADDR_PROTOCOL: i16 = 36;

const SOCK_OPS_OP: i16 = 0;
const SOCK_OPS_FAMILY: i16 = 20;
const SOCK_OPS_LOCAL_IP4: i16 = 28;
const SOCK_OPS_LOCAL_IP6: i16 = 48;
const SOCK_OPS_LOCAL_PORT: i16 = 68;

const ORIG_SIZE: usize = 24;
const PEER_KEY_SIZE: usize = 24;

#[repr(C)]
#[derive(Clone, Copy)]
struct BpfInsn {
    code: u8,
    dst_src: u8,
    off: i16,
    imm: i32,
}

impl BpfInsn {
    fn raw(code: u8, dst: u8, src: u8, off: i16, imm: i32) -> Self {
        Self {
            code,
            dst_src: (dst & 0x0f) | ((src & 0x0f) << 4),
            off,
            imm,
        }
    }

    fn mov64_imm(dst: u8, imm: i32) -> Self {
        Self::raw(BPF_ALU64 | BPF_MOV | BPF_K, dst, 0, 0, imm)
    }

    fn mov64_reg(dst: u8, src: u8) -> Self {
        Self::raw(BPF_ALU64 | BPF_MOV | BPF_X, dst, src, 0, 0)
    }

    fn add64_imm(dst: u8, imm: i32) -> Self {
        Self::raw(BPF_ALU64 | BPF_ADD | BPF_K, dst, 0, 0, imm)
    }

    fn and64_imm(dst: u8, imm: i32) -> Self {
        Self::raw(BPF_ALU64 | BPF_AND | BPF_K, dst, 0, 0, imm)
    }

    fn load_mem(dst: u8, src: u8, off: i16) -> Self {
        Self::raw(BPF_LDX | BPF_W | BPF_MEM, dst, src, off, 0)
    }

    fn store_mem(dst: u8, src: u8, off: i16) -> Self {
        Self::raw(BPF_STX | BPF_W | BPF_MEM, dst, src, off, 0)
    }

    fn store_mem_dw(dst: u8, src: u8, off: i16) -> Self {
        Self::raw(BPF_STX | BPF_DW | BPF_MEM, dst, src, off, 0)
    }

    fn store_imm(dst: u8, off: i16, imm: i32) -> Self {
        Self::raw(BPF_ST | BPF_W | BPF_MEM, dst, 0, off, imm)
    }

    fn call(helper: i32) -> Self {
        Self::raw(BPF_JMP | BPF_CALL, 0, 0, 0, helper)
    }

    fn jump_imm(op: u8, dst: u8, imm: i32, off: i16) -> Self {
        Self::raw(BPF_JMP | op | BPF_K, dst, 0, off, imm)
    }

    fn ja(off: i16) -> Self {
        Self::raw(BPF_JMP | BPF_JA, 0, 0, off, 0)
    }

    fn load_map_fd(dst: u8, fd: RawFd) -> [Self; 2] {
        [
            Self::raw(BPF_LD | BPF_DW | BPF_IMM, dst, BPF_PSEUDO_MAP_FD, 0, fd),
            Self::raw(0, 0, 0, 0, 0),
        ]
    }

    fn exit() -> Self {
        Self::raw(BPF_JMP | BPF_EXIT, 0, 0, 0, 0)
    }
}

#[repr(C)]
#[derive(Default)]
struct BpfAttrMapCreate {
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    map_flags: u32,
    inner_map_fd: u32,
    numa_node: u32,
    map_name: [u8; 16],
}

#[repr(C)]
#[derive(Default)]
struct BpfAttrProgLoad {
    prog_type: u32,
    insn_cnt: u32,
    insns: u64,
    license: u64,
    log_level: u32,
    log_size: u32,
    log_buf: u64,
    kern_version: u32,
    prog_flags: u32,
    prog_name: [u8; 16],
    prog_ifindex: u32,
    expected_attach_type: u32,
}

#[repr(C)]
#[derive(Default)]
struct BpfAttrObj {
    pathname: u64,
    bpf_fd: u32,
    file_flags: u32,
}

#[repr(C)]
#[derive(Default)]
struct BpfAttrAttach {
    target_fd: u32,
    attach_bpf_fd: u32,
    attach_type: u32,
    attach_flags: u32,
    replace_bpf_fd: u32,
}

#[repr(C)]
#[derive(Default)]
struct BpfAttrLinkCreate {
    prog_fd: u32,
    target_fd: u32,
    attach_type: u32,
    flags: u32,
}

#[repr(C)]
#[derive(Default)]
struct BpfAttrProgQuery {
    target_fd: u32,
    attach_type: u32,
    query_flags: u32,
    attach_flags: u32,
    prog_ids: u64,
    prog_cnt: u32,
    reserved: u32,
}

#[repr(C)]
#[derive(Default)]
struct BpfAttrInfo {
    bpf_fd: u32,
    info_len: u32,
    info: u64,
}

#[repr(C)]
#[derive(Default)]
struct BpfAttrMapElem {
    map_fd: u32,
    key: u64,
    value: u64,
    flags: u64,
}

#[repr(C)]
#[derive(Default)]
struct BpfProgInfoHead {
    prog_type: u32,
    id: u32,
    tag: [u8; 8],
}

#[derive(Default)]
struct ProgramBuilder {
    insns: Vec<BpfInsn>,
    labels: HashMap<&'static str, usize>,
    jumps: Vec<(usize, &'static str)>,
}

impl ProgramBuilder {
    fn push(&mut self, insn: BpfInsn) {
        self.insns.push(insn);
    }

    fn extend(&mut self, insns: impl IntoIterator<Item = BpfInsn>) {
        self.insns.extend(insns);
    }

    fn label(&mut self, name: &'static str) {
        self.labels.insert(name, self.insns.len());
    }

    fn jeq_imm(&mut self, dst: u8, imm: i32, label: &'static str) {
        self.push_jump(BpfInsn::jump_imm(BPF_JEQ, dst, imm, 0), label);
    }

    fn jne_imm(&mut self, dst: u8, imm: i32, label: &'static str) {
        self.push_jump(BpfInsn::jump_imm(BPF_JNE, dst, imm, 0), label);
    }

    fn ja(&mut self, label: &'static str) {
        self.push_jump(BpfInsn::ja(0), label);
    }

    fn push_jump(&mut self, insn: BpfInsn, label: &'static str) {
        let index = self.insns.len();
        self.insns.push(insn);
        self.jumps.push((index, label));
    }

    fn finish(mut self) -> Result<Vec<BpfInsn>, String> {
        for (index, label) in &self.jumps {
            let target = *self
                .labels
                .get(label)
                .ok_or_else(|| format!("unknown BPF label: {label}"))?;
            let off = target as isize - *index as isize - 1;
            if off < i16::MIN as isize || off > i16::MAX as isize {
                return Err(format!("BPF jump to {label} is out of range"));
            }
            self.insns[*index].off = off as i16;
        }
        Ok(self.insns)
    }
}

#[derive(Debug)]
struct Options {
    state_dir: PathBuf,
    cgroup: PathBuf,
    mixed_port: u16,
    dns_port: u16,
    probe_only: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            state_dir: PathBuf::from("/data/adb/modules/MagicNet/.state/ebpf"),
            cgroup: PathBuf::from("/sys/fs/cgroup"),
            mixed_port: 7890,
            dns_port: 1053,
            probe_only: false,
        }
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("[magicnet-ebpf] {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "help".to_string());
    let opts = parse_options(args.collect())?;

    match command.as_str() {
        "status" => status(&opts),
        "query" => query(&opts),
        "promote-netd" => set_netd_flags(&opts, BPF_F_ALLOW_MULTI, "promote-netd"),
        "demote-netd" => set_netd_flags(&opts, 0, "demote-netd"),
        "supports-redirect" => supports_redirect(),
        "probe" => probe(&opts),
        "attach" => attach(&opts),
        "detach" => detach(&opts),
        "help" | "-h" | "--help" => {
            print_help();
            Ok(())
        }
        _ => Err("Usage: magicnet-ebpf {status|probe|attach|detach} [options]".to_string()),
    }
}

fn parse_options(args: Vec<String>) -> Result<Options, String> {
    let mut opts = Options::default();
    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--state" => {
                opts.state_dir = PathBuf::from(
                    iter.next()
                        .ok_or_else(|| "--state requires a directory".to_string())?,
                );
            }
            "--cgroup" => {
                opts.cgroup = PathBuf::from(
                    iter.next()
                        .ok_or_else(|| "--cgroup requires a path".to_string())?,
                );
            }
            "--mixed-port" => {
                let value = iter
                    .next()
                    .ok_or_else(|| "--mixed-port requires a port".to_string())?;
                opts.mixed_port = value
                    .parse::<u16>()
                    .map_err(|_| format!("invalid mixed port: {value}"))?;
            }
            "--dns-port" => {
                let value = iter
                    .next()
                    .ok_or_else(|| "--dns-port requires a port".to_string())?;
                opts.dns_port = value
                    .parse::<u16>()
                    .map_err(|_| format!("invalid DNS port: {value}"))?;
            }
            "--probe-only" => opts.probe_only = true,
            other => return Err(format!("unknown option: {other}")),
        }
    }
    Ok(opts)
}

fn print_help() {
    println!(
        "magicnet-ebpf {{status|query|probe|promote-netd|demote-netd|supports-redirect|attach|detach}} [--state DIR] [--cgroup PATH] [--mixed-port PORT] [--dns-port PORT] [--probe-only]"
    );
}

fn supports_redirect() -> Result<(), String> {
    println!("redirect=tcp-bridge,dns53");
    Ok(())
}

fn status(opts: &Options) -> Result<(), String> {
    println!("bpffs={}", yes(bpffs_ready()));
    println!("btf={}", yes(btf_ready()));
    println!("cgroup={}", yes(opts.cgroup.is_dir()));
    println!(
        "pinned={}",
        yes(pin_path(PROG4_PIN).exists()
            || pin_path(PROG6_PIN).exists()
            || pin_path(UDP4_DNS_PIN).exists()
            || pin_path(UDP6_DNS_PIN).exists()
            || pin_path(SOCKOPS_PIN).exists())
    );
    println!("state={}", opts.state_dir.display());
    println!("cgroup_path={}", opts.cgroup.display());
    Ok(())
}

fn probe(opts: &Options) -> Result<(), String> {
    ensure_runtime_ready(opts)?;
    let cgroup_fd = open_dir(&opts.cgroup)?;
    let prog4 = load_allow_prog("mn_conn4_probe", BPF_CGROUP_INET4_CONNECT)?;
    let prog6 = load_allow_prog("mn_conn6_probe", BPF_CGROUP_INET6_CONNECT)?;

    if let Some(link4) = attach_any(cgroup_fd, prog4, BPF_CGROUP_INET4_CONNECT)? {
        close_fd(link4);
    } else {
        detach_prog(cgroup_fd, prog4, BPF_CGROUP_INET4_CONNECT).ok();
    }
    if let Some(link6) = attach_any(cgroup_fd, prog6, BPF_CGROUP_INET6_CONNECT)? {
        close_fd(link6);
    } else {
        detach_prog(cgroup_fd, prog6, BPF_CGROUP_INET6_CONNECT).ok();
    }

    close_fd(prog4);
    close_fd(prog6);
    close_fd(cgroup_fd);
    println!("probe=ok");
    Ok(())
}

fn query(opts: &Options) -> Result<(), String> {
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

fn set_netd_flags(opts: &Options, attach_flags: u32, label: &str) -> Result<(), String> {
    fs::create_dir_all(&opts.state_dir)
        .map_err(|err| format!("create state dir {}: {err}", opts.state_dir.display()))?;
    let lock_fd = open_lock(&opts.state_dir.join("netd-reflag.lock"))?;
    flock_exclusive(lock_fd)?;

    let cgroup_fd = open_dir(&opts.cgroup)?;
    let result: Result<(), String> = (|| {
        let netd = open_netd_programs()?;

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
    println!("{label}=ok");
    Ok(())
}

fn open_netd_programs() -> Result<Vec<NetdProgram>, String> {
    let required = [
        (
            BPF_CGROUP_INET4_CONNECT,
            Path::new("/sys/fs/bpf/netd_shared/prog_netd_connect4_inet4_connect"),
        ),
        (
            BPF_CGROUP_INET6_CONNECT,
            Path::new("/sys/fs/bpf/netd_shared/prog_netd_connect6_inet6_connect"),
        ),
    ];
    let optional = [
        (
            BPF_CGROUP_UDP4_SENDMSG,
            Path::new("/sys/fs/bpf/netd_shared/prog_netd_sendmsg4_udp4_sendmsg"),
        ),
        (
            BPF_CGROUP_UDP6_SENDMSG,
            Path::new("/sys/fs/bpf/netd_shared/prog_netd_sendmsg6_udp6_sendmsg"),
        ),
    ];
    let mut programs = Vec::with_capacity(required.len() + optional.len());
    for (attach_type, path) in required {
        programs.push(NetdProgram::open(attach_type, path)?);
    }
    for (attach_type, path) in optional {
        if path.exists() {
            programs.push(NetdProgram::open(attach_type, path)?);
        }
    }
    Ok(programs)
}

struct NetdProgram {
    attach_type: u32,
    path: PathBuf,
    fd: RawFd,
    id: u32,
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

struct AttachedPrograms {
    attach_flags: u32,
    prog_ids: Vec<u32>,
}

fn query_attached(
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

fn attach(opts: &Options) -> Result<(), String> {
    ensure_runtime_ready(opts)?;

    fs::create_dir_all(&opts.state_dir)
        .map_err(|err| format!("create state dir {}: {err}", opts.state_dir.display()))?;
    fs::create_dir_all(pin_root()).map_err(|err| format!("create bpffs pin dir: {err}"))?;

    let cgroup_fd = open_dir(&opts.cgroup)?;
    let cookie_map_fd = create_cookie_map()?;
    let peer_map_fd = create_peer_map()?;
    pin_fd(cookie_map_fd, &pin_path(COOKIE_MAP_PIN))?;
    pin_fd(peer_map_fd, &pin_path(PEER_MAP_PIN))?;

    if opts.probe_only {
        let prog4 = load_allow_prog("mn_conn4_allow", BPF_CGROUP_INET4_CONNECT)?;
        let prog6 = load_allow_prog("mn_conn6_allow", BPF_CGROUP_INET6_CONNECT)?;
        pin_fd(prog4, &pin_path(PROG4_PIN))?;
        pin_fd(prog6, &pin_path(PROG6_PIN))?;
        let link4 = attach_any(cgroup_fd, prog4, BPF_CGROUP_INET4_CONNECT)?;
        let link6 = attach_any(cgroup_fd, prog6, BPF_CGROUP_INET6_CONNECT)?;
        if let Some(link_fd) = link4 {
            pin_fd(link_fd, &pin_path(LINK4_PIN))?;
            close_fd(link_fd);
        }
        if let Some(link_fd) = link6 {
            pin_fd(link_fd, &pin_path(LINK6_PIN))?;
            close_fd(link_fd);
        }
        let state = format!(
            "mode=probe-only\ncgroup={}\nmixed_port={}\ndns_port={}\n",
            opts.cgroup.display(),
            opts.mixed_port,
            opts.dns_port
        );
        fs::write(opts.state_dir.join(STATE_FILE), state)
            .map_err(|err| format!("write state: {err}"))?;
        close_fd(prog4);
        close_fd(prog6);
        close_fd(peer_map_fd);
        close_fd(cookie_map_fd);
        close_fd(cgroup_fd);
        println!("attach=probe-only");
        return Ok(());
    }

    let bridge4 = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .map_err(|err| format!("bind IPv4 bridge listener: {err}"))?;
    let bridge4_port = bridge4
        .local_addr()
        .map_err(|err| format!("read IPv4 bridge listener address: {err}"))?
        .port();
    let bridge6 = TcpListener::bind((Ipv6Addr::LOCALHOST, 0))
        .map_err(|err| format!("bind IPv6 bridge listener: {err}"))?;
    let bridge6_port = bridge6
        .local_addr()
        .map_err(|err| format!("read IPv6 bridge listener address: {err}"))?
        .port();

    let prog4 = load_connect_prog(
        "mn_conn4_tcp",
        BPF_CGROUP_INET4_CONNECT,
        cookie_map_fd,
        bridge4_port,
        opts.dns_port,
        false,
    )?;
    let prog6 = load_connect_prog(
        "mn_conn6_tcp",
        BPF_CGROUP_INET6_CONNECT,
        cookie_map_fd,
        bridge6_port,
        opts.dns_port,
        true,
    )?;
    let sockops = load_sockops_prog("mn_sockops_tcp", cookie_map_fd, peer_map_fd)?;
    pin_fd(prog4, &pin_path(PROG4_PIN))?;
    pin_fd(prog6, &pin_path(PROG6_PIN))?;
    pin_fd(sockops, &pin_path(SOCKOPS_PIN))?;
    let link4 = attach_any(cgroup_fd, prog4, BPF_CGROUP_INET4_CONNECT)?;
    let link6 = attach_any(cgroup_fd, prog6, BPF_CGROUP_INET6_CONNECT)?;
    let sockops_link = attach_any(cgroup_fd, sockops, BPF_CGROUP_SOCK_OPS)?;
    let dns4_attached = try_attach_dns_prog(
        cgroup_fd,
        "mn_udp4_dns",
        BPF_CGROUP_UDP4_SENDMSG,
        UDP4_DNS_PIN,
        UDP4_DNS_LINK_PIN,
        opts.dns_port,
        false,
    );
    let dns6_attached = try_attach_dns_prog(
        cgroup_fd,
        "mn_udp6_dns",
        BPF_CGROUP_UDP6_SENDMSG,
        UDP6_DNS_PIN,
        UDP6_DNS_LINK_PIN,
        opts.dns_port,
        true,
    );
    if let Some(link_fd) = link4 {
        pin_fd(link_fd, &pin_path(LINK4_PIN))?;
    }
    if let Some(link_fd) = link6 {
        pin_fd(link_fd, &pin_path(LINK6_PIN))?;
    }
    if let Some(link_fd) = sockops_link {
        pin_fd(link_fd, &pin_path(SOCKOPS_LINK_PIN))?;
    }

    let state = format!(
        "mode=tcp-bridge\ncgroup={}\nmixed_port={}\ndns_port={}\nbridge4_port={}\nbridge6_port={}\ndns_udp4={}\ndns_udp6={}\n",
        opts.cgroup.display(),
        opts.mixed_port,
        opts.dns_port,
        bridge4_port,
        bridge6_port,
        if dns4_attached {
            "attached"
        } else {
            "unavailable"
        },
        if dns6_attached {
            "attached"
        } else {
            "unavailable"
        }
    );
    fs::write(opts.state_dir.join(STATE_FILE), state)
        .map_err(|err| format!("write state: {err}"))?;

    if let Some(link_fd) = link4 {
        close_fd(link_fd);
    }
    if let Some(link_fd) = link6 {
        close_fd(link_fd);
    }
    if let Some(link_fd) = sockops_link {
        close_fd(link_fd);
    }
    close_fd(prog4);
    close_fd(prog6);
    close_fd(sockops);
    close_fd(cgroup_fd);

    println!("attach=tcp-bridge");
    run_bridge(bridge4, bridge6, peer_map_fd, opts.mixed_port)
}

fn try_attach_dns_prog(
    cgroup_fd: RawFd,
    name: &str,
    attach_type: u32,
    prog_pin: &str,
    link_pin: &str,
    dns_port: u16,
    ipv6: bool,
) -> bool {
    let prog = match load_udp_dns_prog(name, attach_type, dns_port, ipv6) {
        Ok(fd) => fd,
        Err(err) => {
            eprintln!("[magicnet-ebpf] DNS UDP program load skipped: {err}");
            return false;
        }
    };

    let attached = match attach_any(cgroup_fd, prog, attach_type) {
        Ok(link) => {
            if let Err(err) = pin_fd(prog, &pin_path(prog_pin)) {
                eprintln!("[magicnet-ebpf] DNS UDP program pin skipped: {err}");
                if let Some(link_fd) = link {
                    close_fd(link_fd);
                } else {
                    detach_prog(cgroup_fd, prog, attach_type).ok();
                }
                close_fd(prog);
                return false;
            }
            if let Some(link_fd) = link {
                if let Err(err) = pin_fd(link_fd, &pin_path(link_pin)) {
                    eprintln!("[magicnet-ebpf] DNS UDP link pin skipped: {err}");
                    close_fd(link_fd);
                    fs::remove_file(pin_path(prog_pin)).ok();
                    close_fd(prog);
                    return false;
                }
                close_fd(link_fd);
            }
            true
        }
        Err(err) => {
            eprintln!("[magicnet-ebpf] DNS UDP attach skipped: {err}");
            false
        }
    };
    close_fd(prog);
    attached
}

fn detach(opts: &Options) -> Result<(), String> {
    let cgroup_fd = open_dir(&opts.cgroup)?;
    for name in [
        LINK4_PIN,
        LINK6_PIN,
        UDP4_DNS_LINK_PIN,
        UDP6_DNS_LINK_PIN,
        SOCKOPS_LINK_PIN,
    ] {
        let path = pin_path(name);
        if path.exists() {
            fs::remove_file(&path).ok();
        }
    }
    for (name, attach_type) in [
        (PROG4_PIN, BPF_CGROUP_INET4_CONNECT),
        (PROG6_PIN, BPF_CGROUP_INET6_CONNECT),
        (UDP4_DNS_PIN, BPF_CGROUP_UDP4_SENDMSG),
        (UDP6_DNS_PIN, BPF_CGROUP_UDP6_SENDMSG),
        (SOCKOPS_PIN, BPF_CGROUP_SOCK_OPS),
    ] {
        let path = pin_path(name);
        if path.exists() {
            let prog_fd = obj_get(&path)?;
            detach_prog(cgroup_fd, prog_fd, attach_type).ok();
            close_fd(prog_fd);
            fs::remove_file(&path).ok();
        }
    }
    fs::remove_file(pin_path(COOKIE_MAP_PIN)).ok();
    fs::remove_file(pin_path(PEER_MAP_PIN)).ok();
    fs::remove_dir(pin_root()).ok();
    fs::remove_dir_all(&opts.state_dir).ok();
    close_fd(cgroup_fd);
    println!("detach=ok");
    Ok(())
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct OriginalDst {
    family: u32,
    port: u32,
    addr: [u32; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct PeerKey {
    family: u32,
    port: u32,
    addr: [u32; 4],
}

fn run_bridge(
    bridge4: TcpListener,
    bridge6: TcpListener,
    peer_map_fd: RawFd,
    mixed_port: u16,
) -> Result<(), String> {
    bridge4
        .set_nonblocking(true)
        .map_err(|err| format!("set IPv4 bridge nonblocking: {err}"))?;
    bridge6
        .set_nonblocking(true)
        .map_err(|err| format!("set IPv6 bridge nonblocking: {err}"))?;
    let peer_map = Arc::new(FdHolder(peer_map_fd));
    let map4 = Arc::clone(&peer_map);
    let worker4 = thread::spawn(move || accept_loop(bridge4, map4, mixed_port));
    let map6 = Arc::clone(&peer_map);
    let worker6 = thread::spawn(move || accept_loop(bridge6, map6, mixed_port));

    let start = Instant::now();
    loop {
        if worker4.is_finished() {
            return worker4
                .join()
                .unwrap_or_else(|_| Err("IPv4 bridge thread panicked".to_string()));
        }
        if worker6.is_finished() {
            return worker6
                .join()
                .unwrap_or_else(|_| Err("IPv6 bridge thread panicked".to_string()));
        }
        if start.elapsed() > Duration::from_secs(u64::MAX / 2) {
            return Ok(());
        }
        thread::sleep(Duration::from_secs(60));
    }
}

struct FdHolder(RawFd);

impl Drop for FdHolder {
    fn drop(&mut self) {
        close_fd(self.0);
    }
}

unsafe impl Send for FdHolder {}
unsafe impl Sync for FdHolder {}

fn accept_loop(
    listener: TcpListener,
    peer_map: Arc<FdHolder>,
    mixed_port: u16,
) -> Result<(), String> {
    loop {
        match listener.accept() {
            Ok((stream, peer)) => {
                let map = Arc::clone(&peer_map);
                thread::spawn(move || {
                    if let Err(err) = handle_client(stream, peer, map.0, mixed_port) {
                        eprintln!("[magicnet-ebpf] bridge client failed: {err}");
                    }
                });
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(20));
            }
            Err(err) => return Err(format!("bridge accept failed: {err}")),
        }
    }
}

fn handle_client(
    client: TcpStream,
    peer: SocketAddr,
    peer_map_fd: RawFd,
    mixed_port: u16,
) -> Result<(), String> {
    let original = lookup_original_dst(peer_map_fd, peer)
        .ok_or_else(|| format!("original destination not found for peer {peer}"))?;
    let target = original.to_socket_addr()?;
    if env::var_os("MAGICNET_EBPF_DEBUG").is_some() {
        eprintln!("[magicnet-ebpf] bridge {peer} -> {target}");
    }
    let mut upstream = TcpStream::connect((Ipv4Addr::LOCALHOST, mixed_port))
        .map_err(|err| format!("connect sing-box mixed inbound 127.0.0.1:{mixed_port}: {err}"))?;
    socks5_connect(&mut upstream, target)?;
    relay(client, upstream)
}

fn lookup_original_dst(peer_map_fd: RawFd, peer: SocketAddr) -> Option<OriginalDst> {
    let key = PeerKey::from_peer(peer)?;
    let mut value = OriginalDst::default();
    let mut attr = BpfAttrMapElem {
        map_fd: peer_map_fd as u32,
        key: &key as *const PeerKey as u64,
        value: &mut value as *mut OriginalDst as u64,
        ..Default::default()
    };
    bpf(BPF_MAP_LOOKUP_ELEM, &mut attr).ok()?;
    Some(value)
}

impl PeerKey {
    fn from_peer(peer: SocketAddr) -> Option<Self> {
        match peer {
            SocketAddr::V4(addr) => Some(Self {
                family: AF_INET,
                port: addr.port() as u32,
                addr: [u32::from_ne_bytes(addr.ip().octets()), 0, 0, 0],
            }),
            SocketAddr::V6(addr) => {
                let octets = addr.ip().octets();
                Some(Self {
                    family: AF_INET6,
                    port: addr.port() as u32,
                    addr: [
                        u32::from_ne_bytes([octets[0], octets[1], octets[2], octets[3]]),
                        u32::from_ne_bytes([octets[4], octets[5], octets[6], octets[7]]),
                        u32::from_ne_bytes([octets[8], octets[9], octets[10], octets[11]]),
                        u32::from_ne_bytes([octets[12], octets[13], octets[14], octets[15]]),
                    ],
                })
            }
        }
    }
}

impl OriginalDst {
    fn to_socket_addr(self) -> Result<SocketAddr, String> {
        let port = u16::from_be((self.port & 0xffff) as u16);
        match self.family {
            AF_INET => {
                let ip = Ipv4Addr::from(self.addr[0].to_ne_bytes());
                Ok(SocketAddr::new(IpAddr::V4(ip), port))
            }
            AF_INET6 => {
                let mut octets = [0u8; 16];
                for (index, word) in self.addr.iter().enumerate() {
                    octets[index * 4..index * 4 + 4].copy_from_slice(&word.to_ne_bytes());
                }
                Ok(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(octets)), port))
            }
            other => Err(format!("unsupported original destination family: {other}")),
        }
    }
}

fn socks5_connect(stream: &mut TcpStream, target: SocketAddr) -> Result<(), String> {
    stream
        .write_all(&[0x05, 0x01, 0x00])
        .map_err(|err| format!("write SOCKS5 greeting: {err}"))?;
    let mut reply = [0u8; 2];
    stream
        .read_exact(&mut reply)
        .map_err(|err| format!("read SOCKS5 greeting reply: {err}"))?;
    if reply != [0x05, 0x00] {
        return Err(format!("sing-box rejected SOCKS5 greeting: {:02x?}", reply));
    }

    let mut request = Vec::with_capacity(32);
    request.extend_from_slice(&[0x05, 0x01, 0x00]);
    match target {
        SocketAddr::V4(addr) => {
            request.push(0x01);
            request.extend_from_slice(&addr.ip().octets());
            request.extend_from_slice(&addr.port().to_be_bytes());
        }
        SocketAddr::V6(addr) => {
            request.push(0x04);
            request.extend_from_slice(&addr.ip().octets());
            request.extend_from_slice(&addr.port().to_be_bytes());
        }
    }
    stream
        .write_all(&request)
        .map_err(|err| format!("write SOCKS5 connect request for {target}: {err}"))?;

    let mut head = [0u8; 4];
    stream
        .read_exact(&mut head)
        .map_err(|err| format!("read SOCKS5 connect reply head: {err}"))?;
    if head[0] != 0x05 || head[1] != 0x00 {
        return Err(format!(
            "SOCKS5 connect to {target} failed: reply={:02x?}",
            head
        ));
    }
    match head[3] {
        0x01 => read_discard(stream, 4 + 2),
        0x03 => {
            let mut len = [0u8; 1];
            stream
                .read_exact(&mut len)
                .map_err(|err| format!("read SOCKS5 domain length: {err}"))?;
            read_discard(stream, len[0] as usize + 2)
        }
        0x04 => read_discard(stream, 16 + 2),
        atyp => Err(format!("unsupported SOCKS5 bind address type: {atyp}")),
    }
}

fn read_discard(stream: &mut TcpStream, len: usize) -> Result<(), String> {
    let mut remaining = len;
    let mut buf = [0u8; 32];
    while remaining > 0 {
        let take = remaining.min(buf.len());
        stream
            .read_exact(&mut buf[..take])
            .map_err(|err| format!("read SOCKS5 trailing reply: {err}"))?;
        remaining -= take;
    }
    Ok(())
}

fn relay(mut left: TcpStream, mut right: TcpStream) -> Result<(), String> {
    let mut left_reader = left
        .try_clone()
        .map_err(|err| format!("clone client stream: {err}"))?;
    let mut right_reader = right
        .try_clone()
        .map_err(|err| format!("clone upstream stream: {err}"))?;
    let left_to_right = thread::spawn(move || {
        let result = std::io::copy(&mut left_reader, &mut right);
        let _ = right.shutdown(Shutdown::Write);
        result
    });
    let right_to_left = thread::spawn(move || {
        let result = std::io::copy(&mut right_reader, &mut left);
        let _ = left.shutdown(Shutdown::Write);
        result
    });
    left_to_right
        .join()
        .map_err(|_| "client-to-upstream relay thread panicked".to_string())?
        .map_err(|err| format!("client-to-upstream relay failed: {err}"))?;
    right_to_left
        .join()
        .map_err(|_| "upstream-to-client relay thread panicked".to_string())?
        .map_err(|err| format!("upstream-to-client relay failed: {err}"))?;
    Ok(())
}

fn ensure_runtime_ready(opts: &Options) -> Result<(), String> {
    if !bpffs_ready() {
        return Err("/sys/fs/bpf is not mounted as bpffs".to_string());
    }
    if !opts.cgroup.is_dir() {
        return Err(format!("cgroup path not found: {}", opts.cgroup.display()));
    }
    Ok(())
}

fn bpffs_ready() -> bool {
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

fn btf_ready() -> bool {
    Path::new("/sys/kernel/btf/vmlinux").is_file()
        || fs::read_to_string("/proc/config.gz")
            .ok()
            .map(|_| false)
            .unwrap_or(false)
}

fn load_allow_prog(name: &str, attach_type: u32) -> Result<RawFd, String> {
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

fn load_connect_prog(
    name: &str,
    attach_type: u32,
    cookie_map_fd: RawFd,
    bridge_port: u16,
    dns_port: u16,
    ipv6: bool,
) -> Result<RawFd, String> {
    let insns = build_connect_prog(cookie_map_fd, bridge_port, dns_port, ipv6)?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

fn load_udp_dns_prog(
    name: &str,
    attach_type: u32,
    dns_port: u16,
    ipv6: bool,
) -> Result<RawFd, String> {
    let insns = build_udp_dns_prog(dns_port, ipv6)?;
    load_prog(name, BPF_PROG_TYPE_CGROUP_SOCK_ADDR, attach_type, &insns)
}

fn load_sockops_prog(
    name: &str,
    cookie_map_fd: RawFd,
    peer_map_fd: RawFd,
) -> Result<RawFd, String> {
    let insns = build_sockops_prog(cookie_map_fd, peer_map_fd)?;
    load_prog(name, BPF_PROG_TYPE_SOCK_OPS, BPF_CGROUP_SOCK_OPS, &insns)
}

fn load_prog(
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

fn create_cookie_map() -> Result<RawFd, String> {
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

fn create_peer_map() -> Result<RawFd, String> {
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

fn build_connect_prog(
    cookie_map_fd: RawFd,
    bridge_port: u16,
    dns_port: u16,
    ipv6: bool,
) -> Result<Vec<BpfInsn>, String> {
    let mut p = ProgramBuilder::default();
    let bridge_port_be = bridge_port.to_be() as i32;
    let dns_port_be = dns_port.to_be() as i32;
    let dns53_be = 53u16.to_be() as i32;

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_TYPE));
    p.jne_imm(BPF_REG_1, SOCK_STREAM as i32, "pass");
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_PROTOCOL));
    p.jne_imm(BPF_REG_1, IPPROTO_TCP as i32, "pass");
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.jeq_imm(BPF_REG_1, dns53_be, "dns_redirect");
    p.ja("normal_tcp");

    p.label("dns_redirect");
    emit_loopback_guard(&mut p, ipv6, "dns_do_redirect", "pass");
    p.label("dns_do_redirect");
    emit_local_redirect(&mut p, ipv6, dns_port_be);
    p.ja("pass");

    p.label("normal_tcp");
    if ipv6 {
        // Do not redirect ::1, fc00::/7, fe80::/10, or ff00::/8.
        p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_IP6));
        p.jeq_imm(BPF_REG_1, 0, "check_v6_loopback_tail");
        p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_1));
        p.push(BpfInsn::and64_imm(BPF_REG_2, 0x000000ff));
        p.jeq_imm(BPF_REG_2, 0x000000fc, "pass");
        p.jeq_imm(BPF_REG_2, 0x000000fd, "pass");
        p.jeq_imm(BPF_REG_2, 0x000000fe, "pass");
        p.jeq_imm(BPF_REG_2, 0x000000ff, "pass");
        p.ja("store_orig");
        p.label("check_v6_loopback_tail");
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 4,
        ));
        p.jne_imm(BPF_REG_1, 0, "store_orig");
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 8,
        ));
        p.jne_imm(BPF_REG_1, 0, "store_orig");
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 12,
        ));
        p.jeq_imm(BPF_REG_1, 0x01000000, "pass");
    } else {
        p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_IP4));
        p.jeq_imm(BPF_REG_1, ipv4_raw([127, 0, 0, 1]) as i32, "pass");
        p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_1));
        p.push(BpfInsn::and64_imm(BPF_REG_2, 0x000000ff));
        p.jeq_imm(BPF_REG_2, 0x0000000a, "pass");
        p.jeq_imm(BPF_REG_2, 0x0000007f, "pass");
        p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_1));
        p.push(BpfInsn::and64_imm(BPF_REG_2, 0x0000ffff));
        p.jeq_imm(BPF_REG_2, 0x0000a8c0, "pass");
        p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_1));
        p.push(BpfInsn::and64_imm(BPF_REG_2, 0x0000f0ff));
        p.jeq_imm(BPF_REG_2, 0x000010ac, "pass");
    }

    p.label("store_orig");
    p.push(BpfInsn::store_imm(
        BPF_REG_10,
        -32,
        if ipv6 {
            AF_INET6 as i32
        } else {
            AF_INET as i32
        },
    ));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_1, -28));
    if ipv6 {
        for index in 0..4 {
            p.push(BpfInsn::load_mem(
                BPF_REG_1,
                BPF_REG_6,
                SOCK_ADDR_USER_IP6 + (index * 4) as i16,
            ));
            p.push(BpfInsn::store_mem(
                BPF_REG_10,
                BPF_REG_1,
                -24 + (index * 4) as i16,
            ));
        }
    } else {
        p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_IP4));
        p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_1, -24));
        p.push(BpfInsn::store_imm(BPF_REG_10, -20, 0));
        p.push(BpfInsn::store_imm(BPF_REG_10, -16, 0));
        p.push(BpfInsn::store_imm(BPF_REG_10, -12, 0));
    }

    p.push(BpfInsn::mov64_reg(BPF_REG_1, BPF_REG_6));
    p.push(BpfInsn::call(BPF_FUNC_GET_SOCKET_COOKIE));
    p.push(BpfInsn::store_mem_dw(BPF_REG_10, BPF_REG_0, -40));
    p.extend(BpfInsn::load_map_fd(BPF_REG_1, cookie_map_fd));
    p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_2, -40));
    p.push(BpfInsn::mov64_reg(BPF_REG_3, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_3, -32));
    p.push(BpfInsn::mov64_imm(BPF_REG_4, BPF_ANY as i32));
    p.push(BpfInsn::call(BPF_FUNC_MAP_UPDATE_ELEM));

    if ipv6 {
        store_ctx_imm(&mut p, SOCK_ADDR_USER_IP6, 0);
        store_ctx_imm(&mut p, SOCK_ADDR_USER_IP6 + 4, 0);
        store_ctx_imm(&mut p, SOCK_ADDR_USER_IP6 + 8, 0);
        store_ctx_imm(&mut p, SOCK_ADDR_USER_IP6 + 12, 0x01000000);
    } else {
        store_ctx_imm(&mut p, SOCK_ADDR_USER_IP4, ipv4_raw([127, 0, 0, 1]) as i32);
    }
    store_ctx_imm(&mut p, SOCK_ADDR_USER_PORT, bridge_port_be);

    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    p.finish()
}

fn build_udp_dns_prog(dns_port: u16, ipv6: bool) -> Result<Vec<BpfInsn>, String> {
    let mut p = ProgramBuilder::default();
    let dns_port_be = dns_port.to_be() as i32;
    let dns53_be = 53u16.to_be() as i32;

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.push(BpfInsn::and64_imm(BPF_REG_1, 0x0000ffff));
    p.jeq_imm(BPF_REG_1, 53, "dns_port_matched");
    p.jne_imm(BPF_REG_1, dns53_be, "pass");
    p.label("dns_port_matched");
    emit_loopback_guard(&mut p, ipv6, "dns_do_redirect", "pass");
    p.label("dns_do_redirect");
    emit_local_redirect(&mut p, ipv6, dns_port_be);
    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    p.finish()
}

fn emit_loopback_guard(
    p: &mut ProgramBuilder,
    ipv6: bool,
    redirect_label: &'static str,
    pass_label: &'static str,
) {
    if ipv6 {
        p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_IP6));
        p.jne_imm(BPF_REG_1, 0, redirect_label);
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 4,
        ));
        p.jne_imm(BPF_REG_1, 0, redirect_label);
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 8,
        ));
        p.jne_imm(BPF_REG_1, 0, redirect_label);
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 12,
        ));
        p.jeq_imm(BPF_REG_1, 0x01000000, pass_label);
    } else {
        p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_IP4));
        p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_1));
        p.push(BpfInsn::and64_imm(BPF_REG_2, 0x000000ff));
        p.jeq_imm(BPF_REG_2, 0x0000007f, pass_label);
    }
}

fn emit_local_redirect(p: &mut ProgramBuilder, ipv6: bool, port_be: i32) {
    if ipv6 {
        store_ctx_imm(p, SOCK_ADDR_USER_IP6, 0);
        store_ctx_imm(p, SOCK_ADDR_USER_IP6 + 4, 0);
        store_ctx_imm(p, SOCK_ADDR_USER_IP6 + 8, 0);
        store_ctx_imm(p, SOCK_ADDR_USER_IP6 + 12, 0x01000000);
    } else {
        store_ctx_imm(p, SOCK_ADDR_USER_IP4, ipv4_raw([127, 0, 0, 1]) as i32);
    }
    store_ctx_imm(p, SOCK_ADDR_USER_PORT, port_be);
}

fn build_sockops_prog(cookie_map_fd: RawFd, peer_map_fd: RawFd) -> Result<Vec<BpfInsn>, String> {
    let mut p = ProgramBuilder::default();
    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_OPS_OP));
    p.jne_imm(BPF_REG_1, SOCK_OPS_ACTIVE_ESTABLISHED_CB as i32, "pass");
    p.push(BpfInsn::mov64_reg(BPF_REG_1, BPF_REG_6));
    p.push(BpfInsn::call(BPF_FUNC_GET_SOCKET_COOKIE));
    p.push(BpfInsn::store_mem_dw(BPF_REG_10, BPF_REG_0, -8));

    p.extend(BpfInsn::load_map_fd(BPF_REG_1, cookie_map_fd));
    p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_2, -8));
    p.push(BpfInsn::call(BPF_FUNC_MAP_LOOKUP_ELEM));
    p.jeq_imm(BPF_REG_0, 0, "pass");
    p.push(BpfInsn::mov64_reg(BPF_REG_7, BPF_REG_0));

    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_OPS_FAMILY));
    p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_1, -32));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_OPS_LOCAL_PORT));
    p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_1, -28));

    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_OPS_FAMILY));
    p.jeq_imm(BPF_REG_1, AF_INET6 as i32, "sockops_v6");
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_OPS_LOCAL_IP4));
    p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_1, -24));
    p.push(BpfInsn::store_imm(BPF_REG_10, -20, 0));
    p.push(BpfInsn::store_imm(BPF_REG_10, -16, 0));
    p.push(BpfInsn::store_imm(BPF_REG_10, -12, 0));
    p.ja("peer_update");

    p.label("sockops_v6");
    for index in 0..4 {
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_OPS_LOCAL_IP6 + (index * 4) as i16,
        ));
        p.push(BpfInsn::store_mem(
            BPF_REG_10,
            BPF_REG_1,
            -24 + (index * 4) as i16,
        ));
    }

    p.label("peer_update");
    p.extend(BpfInsn::load_map_fd(BPF_REG_1, peer_map_fd));
    p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_2, -32));
    p.push(BpfInsn::mov64_reg(BPF_REG_3, BPF_REG_7));
    p.push(BpfInsn::mov64_imm(BPF_REG_4, BPF_ANY as i32));
    p.push(BpfInsn::call(BPF_FUNC_MAP_UPDATE_ELEM));

    p.extend(BpfInsn::load_map_fd(BPF_REG_1, cookie_map_fd));
    p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_2, -8));
    p.push(BpfInsn::call(BPF_FUNC_MAP_DELETE_ELEM));

    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    p.finish()
}

fn ipv4_raw(octets: [u8; 4]) -> u32 {
    u32::from_ne_bytes(octets)
}

fn store_ctx_imm(p: &mut ProgramBuilder, off: i16, imm: i32) {
    p.push(BpfInsn::mov64_imm(BPF_REG_1, imm));
    p.push(BpfInsn::store_mem(BPF_REG_6, BPF_REG_1, off));
}

fn attach_prog(cgroup_fd: RawFd, prog_fd: RawFd, attach_type: u32) -> Result<(), String> {
    attach_prog_flags(cgroup_fd, prog_fd, attach_type, 0)
}

fn attach_prog_flags(
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

fn attach_any(cgroup_fd: RawFd, prog_fd: RawFd, attach_type: u32) -> Result<Option<RawFd>, String> {
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

fn link_create(cgroup_fd: RawFd, prog_fd: RawFd, attach_type: u32) -> Result<RawFd, String> {
    let mut attr = BpfAttrLinkCreate {
        prog_fd: prog_fd as u32,
        target_fd: cgroup_fd as u32,
        attach_type,
        flags: 0,
    };
    bpf(BPF_LINK_CREATE, &mut attr)
}

fn detach_prog(cgroup_fd: RawFd, prog_fd: RawFd, attach_type: u32) -> Result<(), String> {
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

fn pin_fd(fd: RawFd, path: &Path) -> Result<(), String> {
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

fn obj_get(path: &Path) -> Result<RawFd, String> {
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("path contains NUL: {}", path.display()))?;
    let mut attr = BpfAttrObj {
        pathname: c_path.as_ptr() as u64,
        ..Default::default()
    };
    bpf(BPF_OBJ_GET, &mut attr)
}

fn prog_id(fd: RawFd) -> Result<u32, String> {
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

fn open_dir(path: &Path) -> Result<RawFd, String> {
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("path contains NUL: {}", path.display()))?;
    let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) };
    if fd < 0 {
        Err(last_os_error(format!("open {}", path.display())))
    } else {
        Ok(fd)
    }
}

fn open_lock(path: &Path) -> Result<RawFd, String> {
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

fn flock_exclusive(fd: RawFd) -> Result<(), String> {
    let rc = unsafe { libc::flock(fd, libc::LOCK_EX) };
    if rc < 0 {
        Err(last_os_error("flock netd reflag lock".to_string()))
    } else {
        Ok(())
    }
}

fn bpf<T>(cmd: u32, attr: &mut T) -> Result<RawFd, String> {
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

fn set_bpf_name(target: &mut [u8; 16], name: &str) {
    let bytes = name.as_bytes();
    let len = bytes.len().min(target.len() - 1);
    target[..len].copy_from_slice(&bytes[..len]);
}

fn pin_root() -> &'static Path {
    Path::new("/sys/fs/bpf/magicnet")
}

fn pin_path(name: &str) -> PathBuf {
    pin_root().join(name)
}

fn close_fd(fd: RawFd) {
    unsafe {
        libc::close(fd);
    }
}

fn last_os_error(context: String) -> String {
    format!("{context}: {}", std::io::Error::last_os_error())
}

fn yes(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}
