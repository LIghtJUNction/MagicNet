mod base64;
mod files;
mod http;
mod logs;
mod rpc;
mod server;
mod tools;

use std::env;
use std::fmt;
use std::io;
use std::net::{IpAddr, SocketAddr, TcpListener};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;

use http::handle_connection;
pub(crate) use rpc::run_cli;
pub(crate) use server::Server;

const MAX_CONCURRENT_CONNECTIONS: usize = 32;
const MODULE_DIR: &str = "/data/adb/modules/MagicNet";

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

#[derive(Debug)]
enum StartupError {
    Configuration(String),
    Listen { addr: SocketAddr, source: io::Error },
}

impl StartupError {
    fn recovery(&self) -> &'static str {
        match self {
            Self::Configuration(_) => {
                "set MAGICNET_MCP_BIND to an IP literal and MAGICNET_MCP_PORT to 1-65535"
            }
            Self::Listen { .. } => {
                "check whether the address is available and another MCP server already uses the port"
            }
        }
    }
}

impl fmt::Display for StartupError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(message) => {
                write!(formatter, "invalid MCP configuration: {message}")
            }
            Self::Listen { addr, source } => write!(formatter, "cannot listen on {addr}: {source}"),
        }
    }
}

impl std::error::Error for StartupError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Configuration(_) => None,
            Self::Listen { source, .. } => Some(source),
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("[error] {error}");
            eprintln!("[hint] {}", error.recovery());
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), StartupError> {
    let moddir = if cfg!(target_os = "android") {
        // The installed module root is a privileged boundary. A direct
        // launcher must not redirect the server to an attacker-writable tree.
        MODULE_DIR.to_string()
    } else {
        env::var("MODDIR").unwrap_or_else(|_| MODULE_DIR.to_string())
    };
    let bind = env::var("MAGICNET_MCP_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = env::var("MAGICNET_MCP_PORT").unwrap_or_else(|_| "8766".to_string());
    let secret = env::var("MAGICNET_MCP_SECRET").unwrap_or_default();
    let addr = parse_listen_addr(&bind, &port).map_err(StartupError::Configuration)?;
    let listener =
        TcpListener::bind(addr).map_err(|source| StartupError::Listen { addr, source })?;
    let cli = if cfg!(target_os = "android") {
        PathBuf::from(&moddir).join("bin/magicnet-cli")
    } else {
        env::var("MAGICNET_CLI")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from(&moddir).join("bin/magicnet-cli"))
    };
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
    Ok(())
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

    #[test]
    fn startup_errors_include_actionable_recovery_context() {
        let configuration =
            StartupError::Configuration("MAGICNET_MCP_BIND must be an IP literal".to_string());
        assert!(configuration
            .to_string()
            .contains("invalid MCP configuration"));
        assert!(configuration.recovery().contains("MAGICNET_MCP_BIND"));

        let listen = StartupError::Listen {
            addr: "127.0.0.1:8766".parse().unwrap(),
            source: io::Error::new(io::ErrorKind::AddrInUse, "address in use"),
        };
        assert!(listen.to_string().contains("127.0.0.1:8766"));
        assert!(listen.recovery().contains("already uses the port"));
    }
}
