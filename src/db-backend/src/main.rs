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
use std::fs;
use std::io::Write;
use std::panic::PanicHookInfo;
use std::path::PathBuf;

use std::thread;
use std::time::Instant;
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

    // let run_dir = core.run_dir()?;
    // fs::create_dir_all(&run_dir)?;
    // let log_path = run_dir.join("db-backend_db-backend_0.log");
    // eprintln!("{}", log_path.display());

    // let mut builder = env_logger::Builder::from_default_env();
    // // credit to https://github.com/rust-cli/env_logger/issues/125#issuecomment-1406333500
    // // and https://github.com/rust-cli/env_logger/issues/125#issuecomment-1582209797
    // // for file targetting code
    // #[allow(clippy::expect_used)]
    // let target = Box::new(fs::File::create(log_path).expect("Can't create file"));

    // builder
    //     .target(env_logger::Target::Pipe(target))
    //     .format(|buf, record| {
    //         writeln!(
    //             buf,
    //             "{} - {}:{} {}",
    //             record.level(),
    //             record.file().unwrap_or("<unknown>"),
    //             record.line().unwrap_or(0),
    //             record.args()
    //         )
    //     })
    //     .filter(None, log::LevelFilter::Info)
    //     .init();

    // duration code copied from
    // https://rust-lang-nursery.github.io/rust-cookbook/datetime/duration.html

    // loading trace and metadata
    // let start = Instant::now();
    // let trace_file_format = if cli.trace_file.extension() == Some(std::ffi::OsStr::new("json")) {
    //     runtime_tracing::TraceEventsFileFormat::Json
    // } else {
    //     runtime_tracing::TraceEventsFileFormat::Binary
    // };
    // let trace = load_trace_data(&cli.trace_file, trace_file_format)?;
    // let trace_metadata = load_trace_metadata(&cli.trace_metadata_file)?;
    // let duration = start.elapsed();
    // info!("loading trace: duration: {:?}", duration);

    // // post processing
    // let start2 = Instant::now();
    // let mut db = Db::new(&trace_metadata.workdir);
    // let mut trace_processor = TraceProcessor::new(&mut db);
    // trace_processor.postprocess(&trace)?;
    // let duration2 = start2.elapsed();
    // info!("postprocessing trace: duration: {:?}", duration2);
    // // info!("{:#?}", &db.variables);
    // // info!("cell_changes {:#?}", db.cell_changes);
    // // db.display_variable_cells();

    // let socket_path = db_backend::dap_server::socket_path_for(cli.caller_process_pid);
    match handle.join() {
        Ok(_) => Ok(()),
        Err(_) => Err("dap server thread panicked".into()),
    }
}
