#![allow(clippy::enum_variant_names)]
#![allow(clippy::new_without_default)]
#![deny(clippy::panic)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![deny(clippy::exit)]
#![allow(clippy::uninlined_format_args)]
#![allow(dead_code)]

// TODO: deny when we cleanup
// dead code usage/add only
// specific allows
// #![deny(dead_code)]
use crate::paths::CODETRACER_PATHS;
use chrono::Local;
use clap::{Parser, Subcommand};
use log::LevelFilter;
use log::{error, info};
use std::fs::File;
use std::io::Write;
use std::panic::PanicHookInfo;
use std::path::PathBuf;
use std::{error::Error, panic};

mod calltrace;
mod core;
mod dap;
mod dap_error;
mod dap_server;
mod dap_types;
mod db;
mod diff;
mod distinct_vec;
mod event_db;
mod expr_loader;
mod flow_preloader;
mod handler;
mod lang;
mod paths;
mod program_search_tool;
mod rr_dispatcher;
mod step_lines_loader;
mod task;
mod trace_processor;
mod tracepoint_interpreter;
mod transport;
mod value;

/// a custom backend for ruby (maybe others) support
/// based on db-like approach based on trace instead of rr/gdb
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    DapServer {
        /// Path to the Unix domain socket for DAP communication.
        /// If omitted, a path based on the process id will be used.
        socket_path: Option<std::path::PathBuf>,
        /// Use stdio transport for DAP communication instead of a Unix socket.
        #[arg(long)]
        stdio: bool,
    },
    IndexDiff {
        structured_diff_path: std::path::PathBuf,
        trace_folder: std::path::PathBuf,
        // TODO: multitrace_folder: std::path::PathBuf,
    },
}

// Already panicking so the unwraps won't change anything
#[allow(clippy::unwrap_used)]
fn panic_handler(info: &PanicHookInfo) {
    error!("PANIC!!! {}", info);
}

#[cfg(feature = "browser-transport")]
fn main() {}

// #[cfg(not(any(feature = "io-transport", feature = "browser-transport")))]

#[cfg(feature = "io-transport")]
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

    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };

    let target = Box::new(File::create(tmp_path.join("db-backend.log"))?);

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

    info!("pid {:?}", std::process::id());

    match cli.cmd {
        Commands::DapServer { socket_path, stdio } => {
            if stdio {
                let _ = db_backend::dap_server::run_stdio();
            } else {
                let socket_path = if let Some(p) = socket_path {
                    p
                } else {
                    let pid = std::process::id() as usize;
                    db_backend::dap_server::socket_path_for(pid)
                };

                info!("dap_server::run {:?}", socket_path);

                let _ = db_backend::dap_server::run(&socket_path);
            };
        }
        Commands::IndexDiff {
            structured_diff_path,
            trace_folder,
            // multitrace_folder,
        } => {
            let raw = std::fs::read_to_string(structured_diff_path)?;
            let structured_diff = serde_json::from_str::<diff::Diff>(&raw)?;
            diff::index_diff(structured_diff, &trace_folder)?;
        }
    }

    Ok(())
}
