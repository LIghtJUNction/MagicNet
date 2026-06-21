use super::loader::*;
use super::netd::find_netd_cgroup_path;
use super::*;

pub(crate) struct DnsAttachState {
    pub(crate) cgroup: Option<PathBuf>,
    pub(crate) app_udp4: bool,
    pub(crate) app_udp6: bool,
    pub(crate) netd_connect4: bool,
    pub(crate) netd_connect6: bool,
    pub(crate) netd_udp4: bool,
    pub(crate) netd_udp6: bool,
}

impl DnsAttachState {
    pub(crate) fn disabled() -> Self {
        Self {
            cgroup: None,
            app_udp4: false,
            app_udp6: false,
            netd_connect4: false,
            netd_connect6: false,
            netd_udp4: false,
            netd_udp6: false,
        }
    }
}

pub(crate) fn attach_dns(opts: &Options, app_cgroup_fd: RawFd) -> DnsAttachState {
    if !opts.dns_redirect {
        return DnsAttachState::disabled();
    }

    let app_udp4 = try_attach_udp_dns_prog(
        app_cgroup_fd,
        "mn_udp4_dns",
        BPF_CGROUP_UDP4_SENDMSG,
        UDP4_DNS_PIN,
        UDP4_DNS_LINK_PIN,
        opts.dns_port,
        false,
        false,
        "app",
    );
    let app_udp6 = try_attach_udp_dns_prog(
        app_cgroup_fd,
        "mn_udp6_dns",
        BPF_CGROUP_UDP6_SENDMSG,
        UDP6_DNS_PIN,
        UDP6_DNS_LINK_PIN,
        opts.dns_port,
        true,
        opts.tcp6_mode == Tcp6Mode::Block,
        "app",
    );

    let explicit_cgroup =
        (opts.dns_cgroup != PathBuf::from("/sys/fs/cgroup")).then(|| opts.dns_cgroup.clone());
    let netd_cgroup = match find_netd_cgroup_path().or(explicit_cgroup) {
        Some(path) if path.is_dir() => path,
        Some(path) => {
            eprintln!(
                "[magicnet-ebpf] netd DNS cgroup skipped: {} is not a directory",
                path.display()
            );
            return DnsAttachState {
                app_udp4,
                app_udp6,
                ..DnsAttachState::disabled()
            };
        }
        None => {
            eprintln!("[magicnet-ebpf] netd DNS cgroup skipped: netd process not found");
            return DnsAttachState {
                app_udp4,
                app_udp6,
                ..DnsAttachState::disabled()
            };
        }
    };

    let netd_fd = match open_dir(&netd_cgroup) {
        Ok(fd) => fd,
        Err(err) => {
            eprintln!("[magicnet-ebpf] netd DNS cgroup open skipped: {err}");
            return DnsAttachState {
                app_udp4,
                app_udp6,
                ..DnsAttachState::disabled()
            };
        }
    };

    let netd_connect4 = try_attach_connect_dns_prog(
        netd_fd,
        "mn_ndc4_dns",
        BPF_CGROUP_INET4_CONNECT,
        NETD_CONNECT4_DNS_PIN,
        NETD_CONNECT4_DNS_LINK_PIN,
        opts.dns_port,
        false,
    );
    let netd_connect6 = try_attach_connect_dns_prog(
        netd_fd,
        "mn_ndc6_dns",
        BPF_CGROUP_INET6_CONNECT,
        NETD_CONNECT6_DNS_PIN,
        NETD_CONNECT6_DNS_LINK_PIN,
        opts.dns_port,
        true,
    );
    let netd_udp4 = try_attach_udp_dns_prog(
        netd_fd,
        "mn_ndu4_dns",
        BPF_CGROUP_UDP4_SENDMSG,
        NETD_UDP4_DNS_PIN,
        NETD_UDP4_DNS_LINK_PIN,
        opts.dns_port,
        false,
        false,
        "netd",
    );
    let netd_udp6 = try_attach_udp_dns_prog(
        netd_fd,
        "mn_ndu6_dns",
        BPF_CGROUP_UDP6_SENDMSG,
        NETD_UDP6_DNS_PIN,
        NETD_UDP6_DNS_LINK_PIN,
        opts.dns_port,
        true,
        false,
        "netd",
    );
    close_fd(netd_fd);

    DnsAttachState {
        cgroup: Some(netd_cgroup),
        app_udp4,
        app_udp6,
        netd_connect4,
        netd_connect6,
        netd_udp4,
        netd_udp6,
    }
}

pub(crate) fn detach_dns(opts: &Options) {
    remove_link_pins();
    detach_pinned_programs(&opts.cgroup, APP_DNS_PINS);

    let state_cgroup = read_state_dns_cgroup(opts);
    let netd_cgroup = state_cgroup
        .or_else(find_netd_cgroup_path)
        .unwrap_or_else(|| opts.dns_cgroup.clone());
    detach_pinned_programs(&netd_cgroup, NETD_DNS_PINS);
    detach_pinned_programs(&opts.dns_cgroup, LEGACY_ROOT_DNS_PINS);
}

fn try_attach_connect_dns_prog(
    cgroup_fd: RawFd,
    name: &str,
    attach_type: u32,
    prog_pin: &str,
    link_pin: &str,
    dns_port: u16,
    ipv6: bool,
) -> bool {
    let prog = match load_netd_dns_connect_prog(name, attach_type, dns_port, ipv6) {
        Ok(fd) => fd,
        Err(err) => {
            eprintln!("[magicnet-ebpf] netd DNS connect program load skipped: {err}");
            return false;
        }
    };
    let attached = attach_and_pin(
        cgroup_fd,
        prog,
        attach_type,
        prog_pin,
        link_pin,
        "netd DNS connect",
    );
    close_fd(prog);
    attached
}

fn try_attach_udp_dns_prog(
    cgroup_fd: RawFd,
    name: &str,
    attach_type: u32,
    prog_pin: &str,
    link_pin: &str,
    dns_port: u16,
    ipv6: bool,
    block_non_dns: bool,
    scope: &str,
) -> bool {
    let prog = match load_udp_dns_prog(name, attach_type, dns_port, ipv6, block_non_dns) {
        Ok(fd) => fd,
        Err(err) => {
            eprintln!("[magicnet-ebpf] {scope} DNS UDP program load skipped: {err}");
            return false;
        }
    };
    let attached = attach_and_pin(cgroup_fd, prog, attach_type, prog_pin, link_pin, "DNS UDP");
    close_fd(prog);
    attached
}

fn attach_and_pin(
    cgroup_fd: RawFd,
    prog: RawFd,
    attach_type: u32,
    prog_pin: &str,
    link_pin: &str,
    label: &str,
) -> bool {
    match attach_any(cgroup_fd, prog, attach_type) {
        Ok(link) => {
            if let Err(err) = pin_fd(prog, &pin_path(prog_pin)) {
                eprintln!("[magicnet-ebpf] {label} program pin skipped: {err}");
                detach_attached(cgroup_fd, prog, attach_type, link);
                return false;
            }
            if let Some(link_fd) = link {
                if let Err(err) = pin_fd(link_fd, &pin_path(link_pin)) {
                    eprintln!("[magicnet-ebpf] {label} link pin skipped: {err}");
                    close_fd(link_fd);
                    fs::remove_file(pin_path(prog_pin)).ok();
                    return false;
                }
                close_fd(link_fd);
            }
            true
        }
        Err(err) => {
            eprintln!("[magicnet-ebpf] {label} attach skipped: {err}");
            false
        }
    }
}

fn remove_link_pins() {
    for name in [
        UDP4_DNS_LINK_PIN,
        UDP6_DNS_LINK_PIN,
        NETD_CONNECT4_DNS_LINK_PIN,
        NETD_CONNECT6_DNS_LINK_PIN,
        NETD_UDP4_DNS_LINK_PIN,
        NETD_UDP6_DNS_LINK_PIN,
        ROOT_TCP4_DNS_LINK_PIN,
        ROOT_TCP6_DNS_LINK_PIN,
        ROOT_UDP4_DNS_LINK_PIN,
        ROOT_UDP6_DNS_LINK_PIN,
    ] {
        fs::remove_file(pin_path(name)).ok();
    }
}

fn detach_pinned_programs(cgroup: &Path, pins: &[(&str, u32)]) {
    let Ok(cgroup_fd) = open_dir(cgroup) else {
        return;
    };
    for (name, attach_type) in pins {
        let path = pin_path(name);
        if path.exists() {
            if let Ok(prog_fd) = obj_get(&path) {
                detach_prog(cgroup_fd, prog_fd, *attach_type).ok();
                close_fd(prog_fd);
            }
            fs::remove_file(&path).ok();
        }
    }
    close_fd(cgroup_fd);
}

fn read_state_dns_cgroup(opts: &Options) -> Option<PathBuf> {
    let state = fs::read_to_string(opts.state_dir.join(STATE_FILE)).ok()?;
    for line in state.lines() {
        if let Some(path) = line.strip_prefix("dns_cgroup=") {
            if !path.is_empty() {
                return Some(PathBuf::from(path));
            }
        }
    }
    None
}

const APP_DNS_PINS: &[(&str, u32)] = &[
    (UDP4_DNS_PIN, BPF_CGROUP_UDP4_SENDMSG),
    (UDP6_DNS_PIN, BPF_CGROUP_UDP6_SENDMSG),
];

const NETD_DNS_PINS: &[(&str, u32)] = &[
    (NETD_CONNECT4_DNS_PIN, BPF_CGROUP_INET4_CONNECT),
    (NETD_CONNECT6_DNS_PIN, BPF_CGROUP_INET6_CONNECT),
    (NETD_UDP4_DNS_PIN, BPF_CGROUP_UDP4_SENDMSG),
    (NETD_UDP6_DNS_PIN, BPF_CGROUP_UDP6_SENDMSG),
];

const LEGACY_ROOT_DNS_PINS: &[(&str, u32)] = &[
    (ROOT_TCP4_DNS_PIN, BPF_CGROUP_INET4_CONNECT),
    (ROOT_TCP6_DNS_PIN, BPF_CGROUP_INET6_CONNECT),
    (ROOT_UDP4_DNS_PIN, BPF_CGROUP_UDP4_SENDMSG),
    (ROOT_UDP6_DNS_PIN, BPF_CGROUP_UDP6_SENDMSG),
];
