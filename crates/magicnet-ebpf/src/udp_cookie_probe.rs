use std::ffi::c_void;
use std::mem;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::os::fd::{AsRawFd, RawFd};
use std::thread;
use std::time::{Duration, Instant};

use super::bridge::OriginalDst;
use super::loader::{bpf, last_os_error};
use super::{BpfAttrMapElem, BPF_MAP_LOOKUP_ELEM, SO_COOKIE};

pub(super) fn run(cookie_map_fd: RawFd) -> Result<OriginalDst, String> {
    let target = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 443);
    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
        .map_err(|err| format!("bind UDP probe socket: {err}"))?;
    let cookie = socket_cookie(&socket)?;
    socket
        .send_to(&[0], target)
        .map_err(|err| format!("send UDP probe datagram to {target}: {err}"))?;

    let start = Instant::now();
    loop {
        if let Some(original) = lookup_original_dst_by_cookie(cookie_map_fd, cookie) {
            let observed = original.to_socket_addr()?;
            if observed != target {
                return Err(format!(
                    "UDP cookie probe stored {observed}, expected {target}"
                ));
            }
            return Ok(original);
        }
        if start.elapsed() >= Duration::from_millis(500) {
            return Err(format!(
                "UDP cookie probe map entry not found for SO_COOKIE {cookie}"
            ));
        }
        thread::sleep(Duration::from_millis(10));
    }
}

pub(super) struct PeerKeyProof {
    pub(super) original: OriginalDst,
    pub(super) source_port: u16,
}

pub(super) struct TokenProof {
    pub(super) original: OriginalDst,
    pub(super) peer: SocketAddr,
}

pub(super) fn run_peer_key(
    cookie_map_fd: RawFd,
    port_map_fd: RawFd,
) -> Result<PeerKeyProof, String> {
    let target = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 443);
    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
        .map_err(|err| format!("bind UDP peer-key probe socket: {err}"))?;
    let source_port = socket
        .local_addr()
        .map_err(|err| format!("read UDP peer-key local address: {err}"))?
        .port();
    let cookie = socket_cookie(&socket)?;
    socket
        .send_to(&[0], target)
        .map_err(|err| format!("send UDP peer-key datagram to {target}: {err}"))?;

    let start = Instant::now();
    loop {
        let original = lookup_original_dst_by_cookie(cookie_map_fd, cookie);
        let observed_port = lookup_source_port_by_cookie(port_map_fd, cookie);
        if let (Some(original), Some(observed_port)) = (original, observed_port) {
            let observed = original.to_socket_addr()?;
            if observed != target {
                return Err(format!(
                    "UDP peer-key probe stored {observed}, expected {target}"
                ));
            }
            if observed_port != source_port {
                return Err(format!(
                    "UDP peer-key probe stored source port {observed_port}, expected {source_port}"
                ));
            }
            return Ok(PeerKeyProof {
                original,
                source_port,
            });
        }
        if start.elapsed() >= Duration::from_millis(500) {
            return Err(format!(
                "UDP peer-key probe map entries not found for SO_COOKIE {cookie}"
            ));
        }
        thread::sleep(Duration::from_millis(10));
    }
}

pub(super) fn run_token(token_map_fd: RawFd, bridge: UdpSocket) -> Result<TokenProof, String> {
    let target = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 443);
    bridge
        .set_read_timeout(Some(Duration::from_millis(500)))
        .map_err(|err| format!("set UDP token bridge timeout: {err}"))?;

    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
        .map_err(|err| format!("bind UDP token client socket: {err}"))?;
    let token = token_from_cookie(socket_cookie(&socket)?);
    let token_addr = IpAddr::V4(Ipv4Addr::from(token.to_ne_bytes()));
    socket
        .send_to(&[0], target)
        .map_err(|err| format!("send UDP token datagram to {target}: {err}"))?;

    let mut buf = [0u8; 8];
    let (_, peer) = bridge
        .recv_from(&mut buf)
        .map_err(|err| format!("receive UDP token bridge datagram: {err}"))?;
    if peer.ip() != token_addr {
        return Err(format!("UDP token peer was {peer}, expected {token_addr}"));
    }
    let original = lookup_original_dst_by_token(token_map_fd, token)
        .ok_or_else(|| "UDP token original destination not found".to_string())?;
    let observed = original.to_socket_addr()?;
    if observed != target {
        return Err(format!(
            "UDP token probe stored {observed}, expected {target}"
        ));
    }
    Ok(TokenProof { original, peer })
}

fn token_from_cookie(cookie: u64) -> u32 {
    ((cookie as u32) & 0xffffff00) | 0x7f
}

fn lookup_original_dst_by_cookie(cookie_map_fd: RawFd, cookie: u64) -> Option<OriginalDst> {
    let mut value = OriginalDst::default();
    let mut attr = BpfAttrMapElem {
        map_fd: cookie_map_fd as u32,
        key: &cookie as *const u64 as u64,
        value: &mut value as *mut OriginalDst as u64,
        ..Default::default()
    };
    bpf(BPF_MAP_LOOKUP_ELEM, &mut attr).ok()?;
    Some(value)
}

fn lookup_original_dst_by_token(token_map_fd: RawFd, token: u32) -> Option<OriginalDst> {
    let mut value = OriginalDst::default();
    let mut attr = BpfAttrMapElem {
        map_fd: token_map_fd as u32,
        key: &token as *const u32 as u64,
        value: &mut value as *mut OriginalDst as u64,
        ..Default::default()
    };
    bpf(BPF_MAP_LOOKUP_ELEM, &mut attr).ok()?;
    Some(value)
}

fn lookup_source_port_by_cookie(port_map_fd: RawFd, cookie: u64) -> Option<u16> {
    let mut value = 0u32;
    let mut attr = BpfAttrMapElem {
        map_fd: port_map_fd as u32,
        key: &cookie as *const u64 as u64,
        value: &mut value as *mut u32 as u64,
        ..Default::default()
    };
    bpf(BPF_MAP_LOOKUP_ELEM, &mut attr).ok()?;
    Some(u16::from_be((value & 0xffff) as u16))
}

pub(super) fn socket_cookie(socket: &UdpSocket) -> Result<u64, String> {
    let mut cookie = 0u64;
    let mut len = mem::size_of::<u64>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            SO_COOKIE,
            &mut cookie as *mut u64 as *mut c_void,
            &mut len,
        )
    };
    if rc < 0 {
        return Err(last_os_error("getsockopt SO_COOKIE".to_string()));
    }
    if len as usize != mem::size_of::<u64>() {
        return Err(format!("getsockopt SO_COOKIE returned {len} bytes"));
    }
    Ok(cookie)
}
