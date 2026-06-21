use super::bridge::run_bridge;
use super::dns_attach::{attach_dns, detach_dns};
use super::loader::*;
use super::*;

pub(crate) fn attach(opts: &Options) -> Result<(), String> {
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
        Tcp6Mode::Bridge,
        opts.dns_redirect,
        false,
    )?;
    let prog6 = load_connect_prog(
        "mn_conn6_tcp",
        BPF_CGROUP_INET6_CONNECT,
        cookie_map_fd,
        bridge6_port,
        opts.dns_port,
        opts.tcp6_mode,
        opts.dns_redirect,
        true,
    )?;
    let sockops = load_sockops_prog("mn_sockops_tcp", cookie_map_fd, peer_map_fd)?;
    pin_fd(prog4, &pin_path(PROG4_PIN))?;
    pin_fd(prog6, &pin_path(PROG6_PIN))?;
    pin_fd(sockops, &pin_path(SOCKOPS_PIN))?;
    let link4 = attach_any(cgroup_fd, prog4, BPF_CGROUP_INET4_CONNECT)?;
    let link6 = attach_any(cgroup_fd, prog6, BPF_CGROUP_INET6_CONNECT)?;
    let sockops_link = attach_any(cgroup_fd, sockops, BPF_CGROUP_SOCK_OPS)?;
    let dns = attach_dns(opts, cgroup_fd);
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
        "mode=tcp-bridge\nprofile=tcp\ncgroup={}\ndns_cgroup={}\nmixed_port={}\ndns_port={}\ntcp6_mode={}\nbridge4_port={}\nbridge6_port={}\ndns_udp4={}\ndns_udp6={}\nnetd_dns_connect4={}\nnetd_dns_connect6={}\nnetd_dns_udp4={}\nnetd_dns_udp6={}\n",
        opts.cgroup.display(),
        dns.cgroup.as_ref().unwrap_or(&opts.dns_cgroup).display(),
        opts.mixed_port,
        opts.dns_port,
        opts.tcp6_mode.as_str(),
        bridge4_port,
        bridge6_port,
        if dns.app_udp4 {
            "attached"
        } else {
            "unavailable"
        },
        if dns.app_udp6 {
            "attached"
        } else {
            "unavailable"
        },
        if dns.netd_connect4 {
            "attached"
        } else {
            "unavailable"
        },
        if dns.netd_connect6 {
            "attached"
        } else {
            "unavailable"
        },
        if dns.netd_udp4 {
            "attached"
        } else {
            "unavailable"
        },
        if dns.netd_udp6 {
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

    if opts.daemonize {
        match daemonize_after_attach()? {
            DaemonRole::Parent => return Ok(()),
            DaemonRole::Child => {}
        }
    }

    println!("attach=tcp-bridge");
    run_bridge(bridge4, bridge6, peer_map_fd, opts.mixed_port)
}

enum DaemonRole {
    Parent,
    Child,
}

fn daemonize_after_attach() -> Result<DaemonRole, String> {
    match unsafe { libc::fork() } {
        -1 => Err(format!(
            "fork daemon after eBPF attach: {}",
            std::io::Error::last_os_error()
        )),
        0 => {
            if unsafe { libc::setsid() } == -1 {
                return Err(format!(
                    "setsid daemon after eBPF attach: {}",
                    std::io::Error::last_os_error()
                ));
            }
            redirect_stdio_to_devnull();
            Ok(DaemonRole::Child)
        }
        pid => {
            println!("daemon_pid={pid}");
            Ok(DaemonRole::Parent)
        }
    }
}

fn redirect_stdio_to_devnull() {
    let fd = unsafe { libc::open(c"/dev/null".as_ptr(), libc::O_RDWR) };
    if fd < 0 {
        return;
    }
    for target in [0, 1, 2] {
        unsafe {
            libc::dup2(fd, target);
        }
    }
    if fd > 2 {
        unsafe {
            libc::close(fd);
        }
    }
}

pub(crate) fn detach(opts: &Options) -> Result<(), String> {
    let cgroup_fd = open_dir(&opts.cgroup)?;
    for name in [
        LINK4_PIN,
        LINK6_PIN,
        UDP4_BRIDGE_SEND_LINK_PIN,
        UDP4_BRIDGE_RECV_LINK_PIN,
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
        (UDP4_BRIDGE_SEND_PIN, BPF_CGROUP_UDP4_SENDMSG),
        (UDP4_BRIDGE_RECV_PIN, BPF_CGROUP_UDP4_RECVMSG),
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
    detach_dns(opts);
    fs::remove_file(pin_path(COOKIE_MAP_PIN)).ok();
    fs::remove_file(pin_path(PEER_MAP_PIN)).ok();
    fs::remove_file(pin_path(UDP_TOKEN_MAP_PIN)).ok();
    fs::remove_dir(pin_root()).ok();
    fs::remove_dir_all(&opts.state_dir).ok();
    close_fd(cgroup_fd);
    println!("detach=ok");
    Ok(())
}
