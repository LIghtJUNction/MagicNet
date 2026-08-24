use std::fmt;
use std::io::{self, Write};

// Rust's standard print macros panic when a WebUI/background-task reader closes
// its pipe before a long-running command reports completion.  Release builds
// abort on that panic, creating a tombstone and bypassing normal cleanup.  CLI
// output is best-effort: keep executing cleanup and preserve the real status
// even after the consumer disconnects.
fn write_stdout(args: fmt::Arguments<'_>) {
    let _ = io::stdout().lock().write_fmt(args);
}

fn write_stderr(args: fmt::Arguments<'_>) {
    let _ = io::stderr().lock().write_fmt(args);
}

macro_rules! print {
    ($($arg:tt)*) => {{ crate::write_stdout(format_args!($($arg)*)); }};
}

macro_rules! println {
    () => {{ crate::write_stdout(format_args!("\n")); }};
    ($($arg:tt)*) => {{ crate::write_stdout(format_args!("{}\n", format_args!($($arg)*))); }};
}

macro_rules! eprintln {
    ($($arg:tt)*) => {{ crate::write_stderr(format_args!("{}\n", format_args!($($arg)*))); }};
}

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
#[cfg(test)]
mod test_support;
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
    SHORT_TIMEOUT,
};
pub(crate) use utils::{
    clean_module_lines, clear_node_cache, cmdline_has_command, cmdline_has_script,
    command_text_timeout, cstring_from_os_str, first_clean_module_line, proc_start_time, read_kv,
    read_proc_argv, read_proc_text_bounded, replace_module_text_files_transactionally,
    run_bounded_command, shell_inert_conf_value, write_kv, write_secret_file, write_text_file,
    MAX_PROC_COMM_BYTES, MAX_PROC_STAT_BYTES,
};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let result = if args.first().map(String::as_str) == Some("__proc-cmdline") {
        utils::proc_cmdline_command(&args[1..])
    } else if args.first().map(String::as_str) == Some("__proc-comm") {
        utils::proc_comm_command(&args[1..])
    } else if args.first().map(String::as_str) == Some("__proc-stat") {
        utils::proc_stat_command(&args[1..])
    } else if args.first().map(String::as_str) == Some("__proc-pids") {
        process::proc_named_pids_command(&args[1..])
    } else {
        let app = App::from_env();
        dispatch(&app, &args)
    };
    let code = match result {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("[error] {err}");
            1
        }
    };
    std::process::exit(code);
}
