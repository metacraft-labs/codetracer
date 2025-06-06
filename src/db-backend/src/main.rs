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
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use std::{error::Error, panic};

use db_backend::db::Db;
use db_backend::handler::Handler;

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
}

// Already panicking so the unwraps won't change anything
#[allow(clippy::unwrap_used)]
fn panic_handler(info: &PanicHookInfo) {
    error!("PANIC!!! {}", info);
}

fn main() -> Result<(), Box<dyn Error>> {
    panic::set_hook(Box::new(panic_handler));

    let cli = Args::parse();

    let socket_path = if let Some(p) = cli.socket_path {
        p
    } else {
        let pid = std::process::id() as usize;
        db_backend::dap_server::socket_path_for(pid)
    };

    println!("pid {:?}", std::process::id());
    let (tx, _rx) = mpsc::channel();
    let db = Db::new(&PathBuf::from(""));
    let mut handler = Handler::construct(Box::new(db), tx, true);

    let handle = thread::spawn(move || {
        let _ = db_backend::dap_server::run(&socket_path, &mut handler);
    });
    match handle.join() {
        Ok(_) => Ok(()),
        Err(_) => Err("dap server thread panicked".into()),
    }
}
