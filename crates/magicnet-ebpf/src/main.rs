use std::collections::HashMap;
use std::env;
use std::ffi::{c_void, CString};
use std::fs;
use std::io::{Read, Write};
use std::mem;
use std::net::{
    IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream, UdpSocket,
};
use std::os::fd::RawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

mod attach_flow;
mod bridge;
mod commands;
mod dns_attach;
mod live_udp_probe;
mod loader;
mod netd;
mod programs;
mod udp_cookie_probe;
mod udp_programs;

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
const BPF_CGROUP_INET4_POST_BIND: u32 = 12;
const BPF_CGROUP_UDP4_SENDMSG: u32 = 14;
const BPF_CGROUP_UDP6_SENDMSG: u32 = 15;
const BPF_CGROUP_UDP4_RECVMSG: u32 = 19;
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
const BPF_OR: u8 = 0x40;
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
const SO_COOKIE: i32 = 57;

const PROG4_PIN: &str = "connect4_allow";
const PROG6_PIN: &str = "connect6_allow";
const UDP4_DNS_PIN: &str = "udp4_dns";
const UDP6_DNS_PIN: &str = "udp6_dns";
const ROOT_TCP4_DNS_PIN: &str = "root_tcp4_dns";
const ROOT_TCP6_DNS_PIN: &str = "root_tcp6_dns";
const ROOT_UDP4_DNS_PIN: &str = "root_udp4_dns";
const ROOT_UDP6_DNS_PIN: &str = "root_udp6_dns";
const NETD_CONNECT4_DNS_PIN: &str = "netd_connect4_dns";
const NETD_CONNECT6_DNS_PIN: &str = "netd_connect6_dns";
const NETD_UDP4_DNS_PIN: &str = "netd_udp4_dns";
const NETD_UDP6_DNS_PIN: &str = "netd_udp6_dns";
const SOCKOPS_PIN: &str = "sockops_index";
const COOKIE_MAP_PIN: &str = "cookie_original_dst";
const PEER_MAP_PIN: &str = "peer_original_dst";
const UDP_TOKEN_MAP_PIN: &str = "udp_token_original_dst";
const LINK4_PIN: &str = "connect4_link";
const LINK6_PIN: &str = "connect6_link";
const UDP4_DNS_LINK_PIN: &str = "udp4_dns_link";
const UDP6_DNS_LINK_PIN: &str = "udp6_dns_link";
const ROOT_TCP4_DNS_LINK_PIN: &str = "root_tcp4_dns_link";
const ROOT_TCP6_DNS_LINK_PIN: &str = "root_tcp6_dns_link";
const ROOT_UDP4_DNS_LINK_PIN: &str = "root_udp4_dns_link";
const ROOT_UDP6_DNS_LINK_PIN: &str = "root_udp6_dns_link";
const NETD_CONNECT4_DNS_LINK_PIN: &str = "netd_connect4_dns_link";
const NETD_CONNECT6_DNS_LINK_PIN: &str = "netd_connect6_dns_link";
const NETD_UDP4_DNS_LINK_PIN: &str = "netd_udp4_dns_link";
const NETD_UDP6_DNS_LINK_PIN: &str = "netd_udp6_dns_link";
const SOCKOPS_LINK_PIN: &str = "sockops_link";
const UDP4_BRIDGE_SEND_PIN: &str = "udp4_bridge_send";
const UDP4_BRIDGE_RECV_PIN: &str = "udp4_bridge_recv";
const UDP4_BRIDGE_SEND_LINK_PIN: &str = "udp4_bridge_send_link";
const UDP4_BRIDGE_RECV_LINK_PIN: &str = "udp4_bridge_recv_link";
const STATE_FILE: &str = "magicnet-ebpf.state";

const AF_INET: u32 = 2;
const AF_INET6: u32 = 10;
const IPPROTO_TCP: u32 = 6;
const IPPROTO_UDP: u32 = 17;
const SOCK_STREAM: u32 = 1;
const SOCK_DGRAM: u32 = 2;
const SOCK_OPS_ACTIVE_ESTABLISHED_CB: u32 = 4;

const SOCK_ADDR_USER_IP4: i16 = 4;
const SOCK_ADDR_USER_IP6: i16 = 8;
const SOCK_ADDR_USER_PORT: i16 = 24;
const SOCK_ADDR_TYPE: i16 = 32;
const SOCK_ADDR_PROTOCOL: i16 = 36;
const SOCK_ADDR_MSG_SRC_IP4: i16 = 40;

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

    fn or64_imm(dst: u8, imm: i32) -> Self {
        Self::raw(BPF_ALU64 | BPF_OR | BPF_K, dst, 0, 0, imm)
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
    dns_cgroup: PathBuf,
    mixed_port: u16,
    dns_port: u16,
    tcp6_mode: Tcp6Mode,
    dns_redirect: bool,
    daemonize: bool,
    probe_only: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Tcp6Mode {
    Bridge,
    Block,
}

impl Tcp6Mode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Bridge => "bridge",
            Self::Block => "block",
        }
    }
}

impl Default for Options {
    fn default() -> Self {
        Self {
            state_dir: PathBuf::from("/data/adb/modules/MagicNet/.state/ebpf"),
            cgroup: PathBuf::from("/sys/fs/cgroup"),
            dns_cgroup: PathBuf::from("/sys/fs/cgroup"),
            mixed_port: 7890,
            dns_port: 1053,
            tcp6_mode: Tcp6Mode::Bridge,
            dns_redirect: false,
            daemonize: false,
            probe_only: false,
        }
    }
}

fn main() {
    if let Err(err) = commands::run() {
        eprintln!("[magicnet-ebpf] {err}");
        std::process::exit(1);
    }
}
