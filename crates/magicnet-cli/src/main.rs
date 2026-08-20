mod app;
mod base64;
#[cfg(test)]
mod base64_tests;
mod chain;
mod commands;
mod config_editor;
mod connection_control;
mod diagnostics;
mod diagnostics_dns;
mod diagnostics_routing;
mod dns;
mod ecapture;
mod mcp;
mod network;
mod node_delay;
mod nodes;
mod ping;
mod process;
mod rules;
mod selector_store;
mod service;
mod subscriptions;
mod utils;
mod warp;
mod webui_api;
mod webui_backup;
mod webui_payload;
mod wifi;

use std::env;

pub(crate) use app::App;
pub(crate) use base64::{decode_base64, encode_base64};
use commands::dispatch;
pub(crate) use process::{
    pid_summary, run_magicnet_function, run_subscription_source_update_from_inherited_fd,
    run_subscription_update_from_inherited_fd, singbox_pid_summary, stop_owned_singbox,
};
pub(crate) use utils::{
    clean_lines, clear_node_cache, command_text_timeout, first_clean_line, read_kv,
    shell_inert_conf_value, write_kv, write_secret_file, write_text_file,
};

fn main() {
    let app = App::from_env();
    let args: Vec<String> = env::args().skip(1).collect();
    let code = match dispatch(&app, &args) {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("[error] {err}");
            1
        }
    };
    std::process::exit(code);
}
