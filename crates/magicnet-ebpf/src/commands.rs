use super::attach_flow::{attach, detach};
use super::loader::*;
use super::netd::{query, restore_netd_if_missing, set_netd_flags};
use super::*;

pub(crate) fn run() -> Result<(), String> {
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
        "probe-udp443" => probe_udp443(&opts),
        "probe-udp-cookie" => probe_udp_cookie(&opts),
        "probe-udp-post-bind" => probe_udp_post_bind(&opts),
        "probe-udp-peer-key" => probe_udp_peer_key(&opts),
        "probe-udp-token" => probe_udp_token(&opts),
        "probe-live-udp53" => live_udp_probe::probe_udp53(&opts),
        "attach" => attach(&opts),
        "detach" => detach(&opts),
        "help" | "-h" | "--help" => {
            print_help();
            Ok(())
        }
        _ => Err("Usage: magicnet-ebpf {status|query|probe|probe-udp443|probe-udp-cookie|probe-udp-post-bind|probe-udp-peer-key|probe-udp-token|probe-live-udp53|promote-netd|demote-netd|supports-redirect|attach|detach} [options]".to_string()),
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
            "--dns-cgroup" => {
                opts.dns_cgroup = PathBuf::from(
                    iter.next()
                        .ok_or_else(|| "--dns-cgroup requires a path".to_string())?,
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
            "--tcp6-mode" => {
                let value = iter
                    .next()
                    .ok_or_else(|| "--tcp6-mode requires bridge or block".to_string())?;
                opts.tcp6_mode = match value.as_str() {
                    "bridge" => Tcp6Mode::Bridge,
                    "block" => Tcp6Mode::Block,
                    _ => return Err(format!("invalid tcp6 mode: {value}")),
                };
            }
            "--probe-only" => opts.probe_only = true,
            "--dns-redirect" => opts.dns_redirect = true,
            "--daemonize" => opts.daemonize = true,
            other => return Err(format!("unknown option: {other}")),
        }
    }
    Ok(opts)
}

fn print_help() {
    println!(
        "magicnet-ebpf {{status|query|probe|probe-udp443|probe-udp-cookie|probe-udp-post-bind|probe-udp-peer-key|probe-udp-token|probe-live-udp53|promote-netd|demote-netd|supports-redirect|attach|detach}} [--state DIR] [--cgroup PATH] [--dns-cgroup PATH] [--mixed-port PORT] [--dns-port PORT] [--tcp6-mode bridge|block] [--dns-redirect] [--daemonize] [--probe-only]"
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
    println!("dns_cgroup={}", yes(opts.dns_cgroup.is_dir()));
    println!(
        "pinned={}",
        yes(pin_path(PROG4_PIN).exists()
            || pin_path(PROG6_PIN).exists()
            || pin_path(UDP4_DNS_PIN).exists()
            || pin_path(UDP6_DNS_PIN).exists()
            || pin_path(ROOT_TCP4_DNS_PIN).exists()
            || pin_path(ROOT_TCP6_DNS_PIN).exists()
            || pin_path(ROOT_UDP4_DNS_PIN).exists()
            || pin_path(ROOT_UDP6_DNS_PIN).exists()
            || pin_path(NETD_CONNECT4_DNS_PIN).exists()
            || pin_path(NETD_CONNECT6_DNS_PIN).exists()
            || pin_path(NETD_UDP4_DNS_PIN).exists()
            || pin_path(NETD_UDP6_DNS_PIN).exists()
            || pin_path(UDP4_BRIDGE_SEND_PIN).exists()
            || pin_path(UDP4_BRIDGE_RECV_PIN).exists()
            || pin_path(SOCKOPS_PIN).exists())
    );
    println!("state={}", opts.state_dir.display());
    println!("cgroup_path={}", opts.cgroup.display());
    println!("dns_cgroup_path={}", opts.dns_cgroup.display());
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

fn probe_udp443(opts: &Options) -> Result<(), String> {
    ensure_runtime_ready(opts)?;
    let cgroup_fd = open_dir(&opts.cgroup)?;
    let prog4 = load_udp443_probe_prog("mn_udp443p4", BPF_CGROUP_UDP4_SENDMSG, false)?;
    let prog6 = load_udp443_probe_prog("mn_udp443p6", BPF_CGROUP_UDP6_SENDMSG, true)?;

    if let Some(link4) = attach_any(cgroup_fd, prog4, BPF_CGROUP_UDP4_SENDMSG)? {
        close_fd(link4);
    } else {
        detach_prog(cgroup_fd, prog4, BPF_CGROUP_UDP4_SENDMSG).ok();
    }
    if let Some(link6) = attach_any(cgroup_fd, prog6, BPF_CGROUP_UDP6_SENDMSG)? {
        close_fd(link6);
    } else {
        detach_prog(cgroup_fd, prog6, BPF_CGROUP_UDP6_SENDMSG).ok();
    }

    close_fd(prog4);
    close_fd(prog6);
    close_fd(cgroup_fd);
    restore_root_netd_udp(opts);
    println!("probe_udp443=ok");
    Ok(())
}

fn probe_udp_cookie(opts: &Options) -> Result<(), String> {
    ensure_runtime_ready(opts)?;
    let cgroup_fd = open_dir(&opts.cgroup)?;
    let cookie_map_fd = create_cookie_map()?;
    let prog4 = match load_udp_cookie_probe_prog(
        "mn_udpcookie4",
        BPF_CGROUP_UDP4_SENDMSG,
        cookie_map_fd,
        false,
    ) {
        Ok(fd) => fd,
        Err(err) => {
            close_fd(cookie_map_fd);
            close_fd(cgroup_fd);
            return Err(err);
        }
    };
    let attach_result = attach_any(cgroup_fd, prog4, BPF_CGROUP_UDP4_SENDMSG);
    let link4 = match attach_result {
        Ok(link) => link,
        Err(err) => {
            close_fd(prog4);
            close_fd(cookie_map_fd);
            close_fd(cgroup_fd);
            return Err(format!(
                "UDP cookie probe attach blocked: {err}. Effective cgroup programs without ALLOW_MULTI can block temporary probes; netd flags were not changed."
            ));
        }
    };

    let result = udp_cookie_probe::run(cookie_map_fd);

    if let Some(link_fd) = link4 {
        close_fd(link_fd);
    } else {
        detach_prog(cgroup_fd, prog4, BPF_CGROUP_UDP4_SENDMSG).ok();
    }
    close_fd(prog4);
    close_fd(cookie_map_fd);
    close_fd(cgroup_fd);
    restore_root_netd_udp4(opts);

    let original = result?;
    println!("probe_udp_cookie=ok");
    println!("cookie_original={}", original.to_socket_addr()?);
    Ok(())
}

fn probe_udp_post_bind(opts: &Options) -> Result<(), String> {
    ensure_runtime_ready(opts)?;
    let cgroup_fd = open_dir(&opts.cgroup)?;
    let prog = match load_allow_prog("mn_udp_bindp", BPF_CGROUP_INET4_POST_BIND) {
        Ok(fd) => fd,
        Err(err) => {
            close_fd(cgroup_fd);
            return Err(format!("UDP post-bind allow program load failed: {err}"));
        }
    };
    let link = match attach_any(cgroup_fd, prog, BPF_CGROUP_INET4_POST_BIND) {
        Ok(link) => link,
        Err(err) => {
            close_fd(prog);
            close_fd(cgroup_fd);
            return Err(format!(
                "UDP post-bind probe attach blocked: {err}. Effective cgroup programs without ALLOW_MULTI can block temporary probes; netd flags were not changed."
            ));
        }
    };
    detach_attached(cgroup_fd, prog, BPF_CGROUP_INET4_POST_BIND, link);
    close_fd(prog);
    close_fd(cgroup_fd);
    println!("probe_udp_post_bind=ok");
    Ok(())
}

fn probe_udp_peer_key(opts: &Options) -> Result<(), String> {
    ensure_runtime_ready(opts)?;
    let cgroup_fd = open_dir(&opts.cgroup)?;
    let cookie_map_fd = create_cookie_map()?;
    let port_map_fd = create_cookie_port_map()?;
    let bind_prog = match load_udp_post_bind_probe_prog(
        "mn_udpbind4",
        BPF_CGROUP_INET4_POST_BIND,
        port_map_fd,
        false,
    ) {
        Ok(fd) => fd,
        Err(err) => {
            close_fd(port_map_fd);
            close_fd(cookie_map_fd);
            close_fd(cgroup_fd);
            return Err(format!("UDP peer-key post-bind program load failed: {err}"));
        }
    };
    let send_prog = match load_udp_cookie_probe_prog(
        "mn_udppeer4",
        BPF_CGROUP_UDP4_SENDMSG,
        cookie_map_fd,
        false,
    ) {
        Ok(fd) => fd,
        Err(err) => {
            close_fd(bind_prog);
            close_fd(port_map_fd);
            close_fd(cookie_map_fd);
            close_fd(cgroup_fd);
            return Err(err);
        }
    };

    let bind_link = match attach_any(cgroup_fd, bind_prog, BPF_CGROUP_INET4_POST_BIND) {
        Ok(link) => link,
        Err(err) => {
            close_fd(send_prog);
            close_fd(bind_prog);
            close_fd(port_map_fd);
            close_fd(cookie_map_fd);
            close_fd(cgroup_fd);
            return Err(format!(
                "UDP peer-key post-bind probe attach blocked: {err}. Effective cgroup programs without ALLOW_MULTI can block temporary probes; netd flags were not changed."
            ));
        }
    };
    let send_link = match attach_any(cgroup_fd, send_prog, BPF_CGROUP_UDP4_SENDMSG) {
        Ok(link) => link,
        Err(err) => {
            detach_attached(cgroup_fd, bind_prog, BPF_CGROUP_INET4_POST_BIND, bind_link);
            close_fd(send_prog);
            close_fd(bind_prog);
            close_fd(port_map_fd);
            close_fd(cookie_map_fd);
            close_fd(cgroup_fd);
            return Err(format!(
                "UDP peer-key sendmsg probe attach blocked: {err}. Effective cgroup programs without ALLOW_MULTI can block temporary probes; netd flags were not changed."
            ));
        }
    };

    let result = udp_cookie_probe::run_peer_key(cookie_map_fd, port_map_fd);

    detach_attached(cgroup_fd, send_prog, BPF_CGROUP_UDP4_SENDMSG, send_link);
    detach_attached(cgroup_fd, bind_prog, BPF_CGROUP_INET4_POST_BIND, bind_link);
    close_fd(send_prog);
    close_fd(bind_prog);
    close_fd(port_map_fd);
    close_fd(cookie_map_fd);
    close_fd(cgroup_fd);
    restore_root_netd_udp4(opts);

    let proof = result?;
    println!("probe_udp_peer_key=ok");
    println!("cookie_original={}", proof.original.to_socket_addr()?);
    println!("cookie_source_port={}", proof.source_port);
    Ok(())
}

fn probe_udp_token(opts: &Options) -> Result<(), String> {
    ensure_runtime_ready(opts)?;
    let cgroup_fd = open_dir(&opts.cgroup)?;
    let token_map_fd = create_token_map()?;
    let bridge = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
        .map_err(|err| format!("bind UDP token bridge listener: {err}"))?;
    let bridge_port = bridge
        .local_addr()
        .map_err(|err| format!("read UDP token bridge address: {err}"))?
        .port();
    let prog = match load_udp_token_probe_prog(
        "mn_udptoken4",
        BPF_CGROUP_UDP4_SENDMSG,
        token_map_fd,
        bridge_port,
        false,
    ) {
        Ok(fd) => fd,
        Err(err) => {
            close_fd(token_map_fd);
            close_fd(cgroup_fd);
            return Err(format!("UDP token probe program load failed: {err}"));
        }
    };
    let link = match attach_any(cgroup_fd, prog, BPF_CGROUP_UDP4_SENDMSG) {
        Ok(link) => link,
        Err(err) => {
            close_fd(prog);
            close_fd(token_map_fd);
            close_fd(cgroup_fd);
            return Err(format!(
                "UDP token probe attach blocked: {err}. Effective cgroup programs without ALLOW_MULTI can block temporary probes; netd flags were not changed."
            ));
        }
    };

    let result = udp_cookie_probe::run_token(token_map_fd, bridge);

    detach_attached(cgroup_fd, prog, BPF_CGROUP_UDP4_SENDMSG, link);
    close_fd(prog);
    close_fd(token_map_fd);
    close_fd(cgroup_fd);
    restore_root_netd_udp4(opts);

    let proof = result?;
    println!("probe_udp_token=ok");
    println!("token_peer={}", proof.peer);
    println!("token_original={}", proof.original.to_socket_addr()?);
    Ok(())
}

fn restore_root_netd_udp(opts: &Options) {
    if opts.cgroup == Path::new("/sys/fs/cgroup") {
        if let Ok(cgroup_fd) = open_dir(&opts.cgroup) {
            restore_netd_if_missing(cgroup_fd, BPF_CGROUP_UDP4_SENDMSG).ok();
            restore_netd_if_missing(cgroup_fd, BPF_CGROUP_UDP6_SENDMSG).ok();
            close_fd(cgroup_fd);
        }
    }
}

fn restore_root_netd_udp4(opts: &Options) {
    if opts.cgroup == Path::new("/sys/fs/cgroup") {
        if let Ok(cgroup_fd) = open_dir(&opts.cgroup) {
            restore_netd_if_missing(cgroup_fd, BPF_CGROUP_UDP4_SENDMSG).ok();
            close_fd(cgroup_fd);
        }
    }
}
