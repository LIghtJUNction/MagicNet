use super::loader::{bpf, close_fd};
use super::*;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct OriginalDst {
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

pub(crate) fn run_bridge(
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
    pub(crate) fn to_socket_addr(self) -> Result<SocketAddr, String> {
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
