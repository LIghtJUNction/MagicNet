pub(crate) mod extended;
pub(crate) mod files;
pub(crate) mod http;
pub(crate) mod logs;
pub(crate) mod rpc;
pub(crate) mod server;
pub(crate) mod tools;

use std::net::{SocketAddr, TcpListener};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::App;
use http::handle_connection;
pub(crate) use rpc::run_cli;
pub(crate) use server::Server;

const MAX_CONCURRENT_CONNECTIONS: usize = 32;

struct ConnectionPermit {
    active: Arc<AtomicUsize>,
}

impl ConnectionPermit {
    fn try_acquire(active: &Arc<AtomicUsize>, limit: usize) -> Option<Self> {
        let mut current = active.load(Ordering::Acquire);
        loop {
            if current >= limit {
                return None;
            }
            match active.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(observed) => current = observed,
            }
        }
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

pub(crate) fn serve(app: &App, address: SocketAddr, secret: String) -> Result<(), String> {
    if secret.is_empty() {
        return Err("MCP secret is missing".to_string());
    }
    let listener = TcpListener::bind(address)
        .map_err(|error| format!("cannot listen on {address}: {error}"))?;
    let server = Arc::new(Server {
        cli: app.moddir.join("bin/magicnet-cli"),
        moddir: app.moddir.clone(),
        secret,
    });
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
                let server = Arc::clone(&server);
                if let Err(error) = thread::Builder::new()
                    .name("magicnet-mcp".to_string())
                    .spawn(move || {
                        let _permit = permit;
                        let _ = handle_connection(stream, &server);
                    })
                {
                    // A failed spawn drops the closure (and its permit/socket).
                    // Do not abort the entire server under resource pressure.
                    eprintln!("MCP worker unavailable: {error}");
                    thread::sleep(Duration::from_millis(100));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => {
                // EMFILE/ENFILE can fail immediately on every accept. Back off
                // instead of busy-spinning and filling the log indefinitely.
                eprintln!("accept failed: {error}");
                thread::sleep(Duration::from_millis(100));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn connection_permits_reject_full_counter_without_overflow() {
        let active = Arc::new(AtomicUsize::new(usize::MAX));
        assert!(ConnectionPermit::try_acquire(&active, usize::MAX).is_none());
        assert_eq!(active.load(Ordering::Acquire), usize::MAX);
    }

    #[test]
    fn concurrent_connection_permits_never_exceed_capacity() {
        let active = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(std::sync::Barrier::new(16));
        let acquired = Arc::new(std::sync::Barrier::new(17));
        let release = Arc::new(std::sync::Barrier::new(17));
        let workers: Vec<_> = (0..16)
            .map(|_| {
                let (active, start, acquired, release) = (
                    active.clone(),
                    start.clone(),
                    acquired.clone(),
                    release.clone(),
                );
                thread::spawn(move || {
                    start.wait();
                    let permit = ConnectionPermit::try_acquire(&active, 4);
                    acquired.wait();
                    release.wait();
                    permit.is_some()
                })
            })
            .collect();
        acquired.wait();
        let peak = active.load(Ordering::Acquire);
        release.wait();
        let granted = workers
            .into_iter()
            .map(|w| w.join().unwrap())
            .filter(|granted| *granted)
            .count();
        assert_eq!(peak, 4);
        assert_eq!(granted, 4);
        assert_eq!(active.load(Ordering::Acquire), 0);
    }
}
