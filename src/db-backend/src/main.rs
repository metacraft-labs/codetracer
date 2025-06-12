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
use chrono::Local;
use clap::Parser;
use log::LevelFilter;
use log::{error, info};
use std::fs::File;
use std::io::Write;
use std::panic::PanicHookInfo;

use std::thread;
use std::{error::Error, panic};

mod calltrace;
mod core;
mod dap;
mod dap_server;
mod db;
mod distinct_vec;
mod event_db;
mod expr_loader;
mod flow_preloader;
mod handler;
mod lang;
mod paths;
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

    // env_logger setup based and adapted from
    //   https://github.com/rust-cli/env_logger/issues/125#issuecomment-1406333500
    //   and https://github.com/rust-cli/env_logger/issues/125#issuecomment-1582209797 (imports)
    // TODO: restore old version or make it compatible with our logging format again

    // let run_dir = core.run_dir()?;
    // fs::create_dir_all(&run_dir)?;
    // let log_path = run_dir.join("db-backend_db-backend_0.log");
    // eprintln!("{}", log_path.display());

    let target = Box::new(File::create("/tmp/codetracer/db-backend.log")?);

    env_logger::Builder::new()
        .format(|buf, record| {
            writeln!(
                buf,
                "{}:{} {} [{}] - {}",
                record.file().unwrap_or("unknown"),
                record.line().unwrap_or(0),
                Local::now().format("%Y-%m-%dT%H:%M:%S%.3f"),
                record.level(),
                record.args()
            )
        })
        .target(env_logger::Target::Pipe(target))
        .filter(None, LevelFilter::Info)
        .init();

    let cli = Args::parse();
    info!("logging from db-backend");

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
