mod base64;
mod files;
mod http;
mod logs;
mod rpc;
mod server;
mod tools;

use std::env;
use std::net::TcpListener;
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
    let addr = format!("{bind}:{port}");
    let listener = TcpListener::bind(&addr).unwrap_or_else(|err| panic!("listen {addr}: {err}"));
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
