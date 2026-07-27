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
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;

use http::handle_connection;
pub(crate) use rpc::run_cli;
pub(crate) use server::Server;

const MAX_CONCURRENT_CONNECTIONS: usize = 32;

struct ConnectionPermit {
    active: Arc<AtomicUsize>,
}

impl ConnectionPermit {
    fn try_acquire(active: &Arc<AtomicUsize>, limit: usize) -> Option<Self> {
        active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
                (current < limit).then_some(current + 1)
            })
            .ok()?;
        Some(Self {
            active: Arc::clone(active),
        })
    }
}

impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }
}

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
    let active_connections = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let Some(permit) =
                    ConnectionPermit::try_acquire(&active_connections, MAX_CONCURRENT_CONNECTIONS)
                else {
                    eprintln!("connection limit reached; dropping request");
                    continue;
                };
                let server = server.clone_ref();
                thread::spawn(move || {
                    let _permit = permit;
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

    #[test]
    fn connection_permits_bound_and_release_worker_capacity() {
        let active = Arc::new(AtomicUsize::new(0));
        let first = ConnectionPermit::try_acquire(&active, 2).unwrap();
        let second = ConnectionPermit::try_acquire(&active, 2).unwrap();
        assert!(ConnectionPermit::try_acquire(&active, 2).is_none());
        drop(first);
        assert!(ConnectionPermit::try_acquire(&active, 2).is_some());
        drop(second);
    }
}
