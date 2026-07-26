mod base64;
mod files;
mod http;
mod logs;
mod rpc;
mod server;
mod tools;

use std::env;
use std::net::{IpAddr, SocketAddr, TcpListener};
use std::path::PathBuf;
use std::thread;

use http::handle_connection;
pub(crate) use rpc::run_cli;
pub(crate) use server::Server;

fn main() {
    let moddir = env::var("MODDIR").unwrap_or_else(|_| "/data/adb/modules/MagicNet".to_string());
    let bind = env::var("MAGICNET_MCP_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = env::var("MAGICNET_MCP_PORT").unwrap_or_else(|_| "8766".to_string());
    let secret = env::var("MAGICNET_MCP_SECRET").unwrap_or_default();
    let addr = parse_listen_addr(&bind, &port).unwrap_or_else(|error| panic!("{error}"));
    let listener = TcpListener::bind(addr).unwrap_or_else(|err| panic!("listen {addr}: {err}"));
    let cli = env::var("MAGICNET_CLI")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(&moddir).join("bin/magicnet-cli"));
    let server = Server {
        cli,
        moddir: PathBuf::from(moddir),
        secret,
    };
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let server = server.clone_ref();
                thread::spawn(move || {
                    let _ = handle_connection(stream, &server);
                });
            }
            Err(err) => eprintln!("accept failed: {err}"),
        }
    }
}

fn parse_listen_addr(bind: &str, port: &str) -> Result<SocketAddr, String> {
    let bind = bind
        .parse::<IpAddr>()
        .map_err(|_| "MAGICNET_MCP_BIND must be an IP literal".to_string())?;
    let port = port
        .parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .ok_or("MAGICNET_MCP_PORT must be a nonzero u16")?;
    Ok(SocketAddr::new(bind, port))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ipv6_loopback_as_an_unambiguous_socket_address() {
        let address = parse_listen_addr("::1", "8766").unwrap();

        assert_eq!(address.to_string(), "[::1]:8766");
    }

    #[test]
    fn rejects_unsafe_or_zero_listen_values() {
        assert!(parse_listen_addr("localhost", "8766").is_err());
        assert!(parse_listen_addr("::1", "0").is_err());
    }
}
