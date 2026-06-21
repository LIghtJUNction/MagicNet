use super::*;

pub(crate) fn build_connect_prog(
    cookie_map_fd: RawFd,
    bridge_port: u16,
    dns_port: u16,
    tcp6_mode: Tcp6Mode,
    dns_redirect: bool,
    ipv6: bool,
) -> Result<Vec<BpfInsn>, String> {
    let mut p = ProgramBuilder::default();
    let bridge_port_be = bridge_port.to_be() as i32;
    let dns_port_be = dns_port.to_be() as i32;
    let dns53_be = 53u16.to_be() as i32;
    let dns_port_be_high = ((dns_port.to_be() as u32) << 16) as i32;
    let dns53_be_high = ((53u16.to_be() as u32) << 16) as i32;

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_TYPE));
    if dns_redirect {
        p.jeq_imm(BPF_REG_1, SOCK_STREAM as i32, "tcp_type");
        p.jne_imm(BPF_REG_1, SOCK_DGRAM as i32, "pass");
        p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_PROTOCOL));
        p.jne_imm(BPF_REG_1, IPPROTO_UDP as i32, "pass");
        p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
        p.jeq_imm(BPF_REG_1, 53, "dns_redirect");
        p.jeq_imm(BPF_REG_1, dns53_be, "dns_redirect");
        p.jeq_imm(BPF_REG_1, 53 << 16, "dns_redirect_high");
        p.jne_imm(BPF_REG_1, dns53_be_high, "pass");
        p.ja("dns_redirect_high");
        p.label("tcp_type");
    } else {
        p.jne_imm(BPF_REG_1, SOCK_STREAM as i32, "pass");
    }
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_PROTOCOL));
    p.jne_imm(BPF_REG_1, IPPROTO_TCP as i32, "pass");
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    if dns_redirect {
        p.jeq_imm(BPF_REG_1, 53, "dns_redirect");
        p.jeq_imm(BPF_REG_1, dns53_be, "dns_redirect");
        p.jeq_imm(BPF_REG_1, 53 << 16, "dns_redirect_high");
        p.jeq_imm(BPF_REG_1, dns53_be_high, "dns_redirect_high");
    }
    p.ja("normal_tcp");

    if dns_redirect {
        p.label("dns_redirect_high");
        emit_loopback_guard(&mut p, ipv6, "dns_do_redirect_high", "pass");
        p.label("dns_do_redirect_high");
        emit_local_redirect(&mut p, ipv6, dns_port_be_high);
        p.ja("pass");
        p.label("dns_redirect");
        emit_loopback_guard(&mut p, ipv6, "dns_do_redirect", "pass");
        p.label("dns_do_redirect");
        emit_local_redirect(&mut p, ipv6, dns_port_be);
        p.ja("pass");
    }

    p.label("normal_tcp");
    if ipv6 {
        let v6_data_label = if tcp6_mode == Tcp6Mode::Block {
            "reject"
        } else {
            "store_orig"
        };
        // Do not redirect ::1, fc00::/7, fe80::/10, or ff00::/8.
        p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_IP6));
        p.jeq_imm(BPF_REG_1, 0, "check_v6_loopback_tail");
        p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_1));
        p.push(BpfInsn::and64_imm(BPF_REG_2, 0x000000ff));
        p.jeq_imm(BPF_REG_2, 0x000000fc, "pass");
        p.jeq_imm(BPF_REG_2, 0x000000fd, "pass");
        p.jeq_imm(BPF_REG_2, 0x000000fe, "pass");
        p.jeq_imm(BPF_REG_2, 0x000000ff, "pass");
        p.ja(v6_data_label);
        p.label("check_v6_loopback_tail");
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 4,
        ));
        p.jne_imm(BPF_REG_1, 0, v6_data_label);
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 8,
        ));
        p.jne_imm(BPF_REG_1, 0, v6_data_label);
        p.push(BpfInsn::load_mem(
            BPF_REG_1,
            BPF_REG_6,
            SOCK_ADDR_USER_IP6 + 12,
        ));
        p.jeq_imm(BPF_REG_1, 0x01000000, "pass");
        if tcp6_mode == Tcp6Mode::Block {
            p.ja("reject");
        }
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

    if ipv6 && tcp6_mode == Tcp6Mode::Block {
        p.label("pass");
        p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
        p.push(BpfInsn::exit());
        p.label("reject");
        p.push(BpfInsn::mov64_imm(BPF_REG_0, 0));
        p.push(BpfInsn::exit());
        return p.finish();
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

pub(crate) fn build_netd_dns_connect_prog(
    dns_port: u16,
    ipv6: bool,
) -> Result<Vec<BpfInsn>, String> {
    let mut p = ProgramBuilder::default();
    let dns_port_be = dns_port.to_be() as i32;
    let dns53_be = 53u16.to_be() as i32;
    let dns_port_be_high = ((dns_port.to_be() as u32) << 16) as i32;
    let dns53_be_high = ((53u16.to_be() as u32) << 16) as i32;

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_TYPE));
    p.jeq_imm(BPF_REG_1, SOCK_STREAM as i32, "type_ok");
    p.jne_imm(BPF_REG_1, SOCK_DGRAM as i32, "pass");
    p.label("type_ok");
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_PROTOCOL));
    p.jeq_imm(BPF_REG_1, IPPROTO_TCP as i32, "protocol_ok");
    p.jne_imm(BPF_REG_1, IPPROTO_UDP as i32, "pass");
    p.label("protocol_ok");
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.jeq_imm(BPF_REG_1, 53, "dns_port_matched");
    p.jeq_imm(BPF_REG_1, dns53_be, "dns_port_matched");
    p.jeq_imm(BPF_REG_1, 53 << 16, "dns_port_matched_high");
    p.jne_imm(BPF_REG_1, dns53_be_high, "pass");
    p.label("dns_port_matched_high");
    emit_loopback_guard(&mut p, ipv6, "dns_do_redirect_high", "pass");
    p.label("dns_do_redirect_high");
    emit_local_redirect(&mut p, ipv6, dns_port_be_high);
    p.ja("pass");
    p.label("dns_port_matched");
    emit_loopback_guard(&mut p, ipv6, "dns_do_redirect", "pass");
    p.label("dns_do_redirect");
    emit_local_redirect(&mut p, ipv6, dns_port_be);
    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    p.finish()
}

pub(crate) fn emit_loopback_guard(
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

pub(crate) fn emit_local_redirect(p: &mut ProgramBuilder, ipv6: bool, port_be: i32) {
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

pub(crate) fn build_sockops_prog(
    cookie_map_fd: RawFd,
    peer_map_fd: RawFd,
) -> Result<Vec<BpfInsn>, String> {
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

pub(crate) fn ipv4_raw(octets: [u8; 4]) -> u32 {
    u32::from_ne_bytes(octets)
}

pub(crate) fn store_ctx_imm(p: &mut ProgramBuilder, off: i16, imm: i32) {
    p.push(BpfInsn::mov64_imm(BPF_REG_1, imm));
    p.push(BpfInsn::store_mem(BPF_REG_6, BPF_REG_1, off));
}
