#![allow(clippy::enum_variant_names)]
#![allow(clippy::new_without_default)]
#![deny(clippy::panic)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![deny(clippy::exit)]
#![allow(dead_code)]

// TODO: deny when we cleanup
// dead code usage/add only
// specific allows
// #![deny(dead_code)]
use clap::Parser;
use log::error;
use std::panic::PanicHookInfo;
use std::thread;
use std::{error::Error, panic};

mod calltrace;
mod core;
mod db;
mod distinct_vec;
mod event_db;
mod expr_loader;
mod flow_preloader;
mod handler;
mod lang;
mod program_search_tool;
mod receiver;
mod response;
mod sender;
mod step_lines_loader;
mod task;
mod trace_processor;
mod tracepoint_interpreter;
mod value;

/// a custom backend for ruby (maybe others) support
/// based on db-like approach based on trace instead of rr/gdb
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    /// Path to the Unix domain socket for DAP communication.
    /// If omitted, a path based on the process id will be used.
    socket_path: Option<std::path::PathBuf>,
    /// Use stdio transport for DAP communication instead of a Unix socket.
    #[arg(long)]
    stdio: bool,
}

// Already panicking so the unwraps won't change anything
#[allow(clippy::unwrap_used)]
fn panic_handler(info: &PanicHookInfo) {
    error!("PANIC!!! {}", info);
}

fn main() -> Result<(), Box<dyn Error>> {
    panic::set_hook(Box::new(panic_handler));

    let cli = Args::parse();

    eprintln!("pid {:?}", std::process::id());
    let handle = if cli.stdio {
        thread::spawn(move || {
            let _ = db_backend::dap_server::run_stdio();
        })
    } else {
        let socket_path = if let Some(p) = cli.socket_path {
            p
        } else {
            let pid = std::process::id() as usize;
            db_backend::dap_server::socket_path_for(pid)
        };
        thread::spawn(move || {
            let _ = db_backend::dap_server::run(&socket_path);
        })
    };

    match handle.join() {
        Ok(_) => Ok(()),
        Err(_) => Err("dap server thread panicked".into()),
    }
}
