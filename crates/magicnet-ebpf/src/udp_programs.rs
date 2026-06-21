use super::programs::{emit_local_redirect, emit_loopback_guard, ipv4_raw, store_ctx_imm};
use super::*;

pub(crate) fn build_udp_dns_prog(
    dns_port: u16,
    ipv6: bool,
    block_non_dns: bool,
) -> Result<Vec<BpfInsn>, String> {
    let mut p = ProgramBuilder::default();
    let dns_port_be = dns_port.to_be() as i32;
    let dns53_be = 53u16.to_be() as i32;
    let dns_port_be_high = ((dns_port.to_be() as u32) << 16) as i32;
    let dns53_be_high = ((53u16.to_be() as u32) << 16) as i32;

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.jeq_imm(BPF_REG_1, 53, "dns_port_matched_low");
    p.jeq_imm(BPF_REG_1, dns53_be, "dns_port_matched_low");
    p.jeq_imm(BPF_REG_1, 53 << 16, "dns_port_matched_high");
    p.jne_imm(
        BPF_REG_1,
        dns53_be_high,
        if block_non_dns { "reject" } else { "pass" },
    );
    p.label("dns_port_matched_high");
    emit_loopback_guard(&mut p, ipv6, "dns_do_redirect_high", "pass");
    p.label("dns_do_redirect_high");
    emit_local_redirect(&mut p, ipv6, dns_port_be_high);
    p.ja("pass");
    p.label("dns_port_matched_low");
    emit_loopback_guard(&mut p, ipv6, "dns_do_redirect_low", "pass");
    p.label("dns_do_redirect_low");
    emit_local_redirect(&mut p, ipv6, dns_port_be);
    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    if block_non_dns {
        p.label("reject");
        p.push(BpfInsn::mov64_imm(BPF_REG_0, 0));
        p.push(BpfInsn::exit());
    }
    p.finish()
}

pub(crate) fn build_udp443_probe_prog(_ipv6: bool) -> Result<Vec<BpfInsn>, String> {
    let mut p = ProgramBuilder::default();
    let udp443_be = 443u16.to_be() as i32;
    let udp443_be_high = ((443u16.to_be() as u32) << 16) as i32;

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.jeq_imm(BPF_REG_1, 443, "matched_low");
    p.jeq_imm(BPF_REG_1, udp443_be, "matched_low");
    p.jeq_imm(BPF_REG_1, 443 << 16, "matched_high");
    p.jne_imm(BPF_REG_1, udp443_be_high, "pass");
    p.label("matched_high");
    p.ja("pass");
    p.label("matched_low");
    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    p.finish()
}

pub(crate) fn build_udp_cookie_probe_prog(
    cookie_map_fd: RawFd,
    ipv6: bool,
) -> Result<Vec<BpfInsn>, String> {
    if ipv6 {
        return Err("UDP cookie probe currently supports IPv4 only".to_string());
    }
    let mut p = ProgramBuilder::default();
    let udp443_be = 443u16.to_be() as i32;
    let udp443_be_high = ((443u16.to_be() as u32) << 16) as i32;

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.jeq_imm(BPF_REG_1, 443, "matched_low");
    p.jeq_imm(BPF_REG_1, udp443_be, "matched_low");
    p.jeq_imm(BPF_REG_1, 443 << 16, "matched_high");
    p.jne_imm(BPF_REG_1, udp443_be_high, "pass");
    p.label("matched_high");
    p.ja("store_orig");
    p.label("matched_low");

    p.label("store_orig");
    p.push(BpfInsn::store_imm(BPF_REG_10, -32, AF_INET as i32));
    p.push(BpfInsn::store_imm(BPF_REG_10, -28, udp443_be));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_IP4));
    p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_1, -24));
    p.push(BpfInsn::store_imm(BPF_REG_10, -20, 0));
    p.push(BpfInsn::store_imm(BPF_REG_10, -16, 0));
    p.push(BpfInsn::store_imm(BPF_REG_10, -12, 0));

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

    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    p.finish()
}

pub(crate) fn build_udp_post_bind_probe_prog(
    port_map_fd: RawFd,
    ipv6: bool,
) -> Result<Vec<BpfInsn>, String> {
    if ipv6 {
        return Err("UDP post-bind probe currently supports IPv4 only".to_string());
    }
    let mut p = ProgramBuilder::default();

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_TYPE));
    p.jne_imm(BPF_REG_1, SOCK_DGRAM as i32, "pass");
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_PROTOCOL));
    p.jne_imm(BPF_REG_1, IPPROTO_UDP as i32, "pass");

    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_1, -4));
    p.push(BpfInsn::mov64_reg(BPF_REG_1, BPF_REG_6));
    p.push(BpfInsn::call(BPF_FUNC_GET_SOCKET_COOKIE));
    p.push(BpfInsn::store_mem_dw(BPF_REG_10, BPF_REG_0, -16));
    p.extend(BpfInsn::load_map_fd(BPF_REG_1, port_map_fd));
    p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_2, -16));
    p.push(BpfInsn::mov64_reg(BPF_REG_3, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_3, -4));
    p.push(BpfInsn::mov64_imm(BPF_REG_4, BPF_ANY as i32));
    p.push(BpfInsn::call(BPF_FUNC_MAP_UPDATE_ELEM));

    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    p.finish()
}

pub(crate) fn build_udp_token_probe_prog(
    token_map_fd: RawFd,
    bridge_port: u16,
    ipv6: bool,
) -> Result<Vec<BpfInsn>, String> {
    if ipv6 {
        return Err("UDP token probe currently supports IPv4 only".to_string());
    }
    let mut p = ProgramBuilder::default();
    let udp443_be = 443u16.to_be() as i32;
    let udp443_be_high = ((443u16.to_be() as u32) << 16) as i32;
    let bridge_port_be = bridge_port.to_be() as i32;

    p.push(BpfInsn::mov64_reg(BPF_REG_6, BPF_REG_1));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_PORT));
    p.jeq_imm(BPF_REG_1, 443, "matched_low");
    p.jeq_imm(BPF_REG_1, udp443_be, "matched_low");
    p.jeq_imm(BPF_REG_1, 443 << 16, "matched_high");
    p.jne_imm(BPF_REG_1, udp443_be_high, "pass");
    p.label("matched_high");
    p.ja("store_orig");
    p.label("matched_low");

    p.label("store_orig");
    p.push(BpfInsn::store_imm(BPF_REG_10, -32, AF_INET as i32));
    p.push(BpfInsn::store_imm(BPF_REG_10, -28, udp443_be));
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_6, SOCK_ADDR_USER_IP4));
    p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_1, -24));
    p.push(BpfInsn::store_imm(BPF_REG_10, -20, 0));
    p.push(BpfInsn::store_imm(BPF_REG_10, -16, 0));
    p.push(BpfInsn::store_imm(BPF_REG_10, -12, 0));

    p.push(BpfInsn::mov64_reg(BPF_REG_1, BPF_REG_6));
    p.push(BpfInsn::call(BPF_FUNC_GET_SOCKET_COOKIE));
    p.push(BpfInsn::and64_imm(BPF_REG_0, -256));
    p.push(BpfInsn::or64_imm(BPF_REG_0, 0x7f));
    p.push(BpfInsn::store_mem(BPF_REG_10, BPF_REG_0, -36));
    p.extend(BpfInsn::load_map_fd(BPF_REG_1, token_map_fd));
    p.push(BpfInsn::mov64_reg(BPF_REG_2, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_2, -36));
    p.push(BpfInsn::mov64_reg(BPF_REG_3, BPF_REG_10));
    p.push(BpfInsn::add64_imm(BPF_REG_3, -32));
    p.push(BpfInsn::mov64_imm(BPF_REG_4, BPF_ANY as i32));
    p.push(BpfInsn::call(BPF_FUNC_MAP_UPDATE_ELEM));

    store_ctx_imm(&mut p, SOCK_ADDR_USER_IP4, ipv4_raw([127, 0, 0, 1]) as i32);
    store_ctx_imm(&mut p, SOCK_ADDR_USER_PORT, bridge_port_be);
    p.push(BpfInsn::load_mem(BPF_REG_1, BPF_REG_10, -36));
    p.push(BpfInsn::store_mem(
        BPF_REG_6,
        BPF_REG_1,
        SOCK_ADDR_MSG_SRC_IP4,
    ));

    p.label("pass");
    p.push(BpfInsn::mov64_imm(BPF_REG_0, 1));
    p.push(BpfInsn::exit());
    p.finish()
}
