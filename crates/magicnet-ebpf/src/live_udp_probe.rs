use std::fs;
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::time::{SystemTime, UNIX_EPOCH};

use super::*;

pub(crate) fn probe_udp53(opts: &Options) -> Result<(), String> {
    join_cgroup(opts)?;
    let target = SocketAddrV4::new(Ipv4Addr::new(211, 138, 21, 66), 53);
    send_probe_datagram(target)?;
    println!("probe_live_udp53=sent");
    println!("target={target}");
    Ok(())
}

fn send_probe_datagram(target: SocketAddrV4) -> Result<(), String> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))
        .map_err(|err| format!("bind live UDP probe socket: {err}"))?;
    let sent_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| format!("read clock: {err}"))?
        .as_nanos();
    let payload = format!("magicnet-ebpf-live-udp:{sent_at}");
    socket
        .send_to(payload.as_bytes(), target)
        .map_err(|err| format!("send live UDP probe to {target}: {err}"))?;
    Ok(())
}

fn join_cgroup(opts: &Options) -> Result<(), String> {
    fs::write(
        opts.cgroup.join("cgroup.procs"),
        std::process::id().to_string(),
    )
    .map_err(|err| format!("join cgroup {}: {err}", opts.cgroup.display()))
}
