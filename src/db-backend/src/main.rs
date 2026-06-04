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
use chrono::Local;
use clap::{Parser, Subcommand};
use log::LevelFilter;
use log::{error, info};
use std::fs::{File, create_dir_all, remove_file};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::symlink as symlink_path;
#[cfg(windows)]
use std::os::windows::fs::symlink_dir as symlink_path;
use std::panic::PanicHookInfo;
use std::path::PathBuf;
use std::thread;
use std::{error::Error, panic};

mod calltrace;
mod core;
mod ctfs_trace_reader;
mod dap;
mod dap_error;
mod dap_handler;
mod dap_server;
mod dap_types;
mod db;
mod diff;
mod distinct_vec;
mod event_db;
mod expr_loader;
mod flow_preloader;
mod in_memory_trace_reader;
mod lang;
mod macro_sourcemap;
mod nim_mangling;
mod origin_query;
mod paths;
mod program_search_tool;
mod query;
mod recreator_session;
mod replay;
mod step_lines_loader;
mod task;
mod trace_processor;
mod trace_reader;
mod tracepoint_interpreter;
mod transport;
mod transport_endpoint;
mod value;

use crate::paths::{CODETRACER_PATHS, gc_stale_run_dirs, run_dir_for};

/// The replay server: a DAP-based replay backend for materialized-trace languages
/// (Ruby, Python, JS, shell, Wasm, etc.) as opposed to rr/gdb-based replay
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

#[cfg(all(feature = "browser-transport", not(feature = "io-transport")))]
fn main() {}

// #[cfg(not(any(feature = "io-transport", feature = "browser-transport")))]

#[cfg(feature = "io-transport")]
fn main() -> Result<(), Box<dyn Error>> {
    panic::set_hook(Box::new(panic_handler));

    // env_logger setup based and adapted from
    //   https://github.com/rust-cli/env_logger/issues/125#issuecomment-1406333500
    //   and https://github.com/rust-cli/env_logger/issues/125#issuecomment-1582209797 (imports)

    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    // M-REC-11: db-backend is the spawner; it doesn't yet know any
    // recording_id at this very early bootstrap point (cli is parsed
    // below), so its own log/run directory still uses its pid.  This
    // is fine — its child replay-workers will be steered to their
    // own recording-id-derived directories via $CODETRACER_RUN_ID.
    let pid = std::process::id();
    let run_id = pid.to_string();
    // GUI-Test-Stabilization M12: before creating our own run dir,
    // reclaim any leftover `run-<pid>/` dirs whose owning PID is no
    // longer alive.  This is fast (a directory listing + one
    // `kill(pid, 0)` syscall per candidate) and synchronous so that
    // a freshly-spawned replay-server never piles on top of stale
    // 18 MB per-run blobs.  Best-effort: errors are swallowed
    // internally and never abort startup.
    let _gc_removed = gc_stale_run_dirs(&tmp_path, pid);
    let run_dir = run_dir_for(&tmp_path, &run_id)?;
    create_dir_all(&run_dir)?;

    let log_path = run_dir.join("replay-server.log");

    let target = Box::new(File::create(&log_path)?);

    env_logger::Builder::new()
        .format(|buf, record| {
            let thread = thread::current();
            let thread_id_as_string = &format!("{:?}", thread.id());
            let thread_name_or_id = thread.name().unwrap_or(thread_id_as_string);
            // format explanation: `:<char><alignment-where><width>`
            //   based on https://stackoverflow.com/a/41496138/438099
            let thread_column = format!("[{: <18}]", format!("{} thread", thread_name_or_id));
            writeln!(
                buf,
                "{} {}:{} {} [{}] - {}",
                thread_column,
                record.file().unwrap_or("unknown"),
                record.line().unwrap_or(0),
                Local::now().format("%H:%M:%S%.3f"),
                // too long? Local::now().format("%Y-%m-%dT%H:%M:%S%.3f"),
                record.level(),
                record.args()
            )
        })
        .target(env_logger::Target::Pipe(target))
        .filter(None, LevelFilter::Info)
        .init();

    let cli = Args::parse();
    info!("logging from replay-server");

    info!("pid {:?}", std::process::id());

    let run_id = std::process::id().to_string();

    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    let run_dir = run_dir_for(&tmp_path, &run_id)?;
    // remove_dir_all(&run_dir)?;
    create_dir_all(&run_dir)?;
    let last_link = tmp_path.join("last");
    eprintln!("last {:?}", last_link.display());
    if last_link.exists() {
        // On Windows this is a directory symlink (`symlink_dir`), so remove_dir is required.
        let _ = std::fs::remove_dir(&last_link);
        let _ = remove_file(&last_link);
    }
    if let Err(e) = symlink_path(run_dir, &last_link) {
        // ignore if it can't happen: it's just a help for debugging
        eprintln!("error symlink {e:?}");
    }

    match cli.cmd {
        Commands::DapServer { socket_path, stdio } => {
            if stdio {
                // thread::spawn(move || {
                let res = db_backend::dap_server::run_stdio();
                if let Err(e) = res {
                    error!("dap server run error: {e:?}");
                }
                // })
            } else {
                let socket_path = if let Some(p) = socket_path {
                    p
                } else {
                    let pid = std::process::id() as usize;
                    db_backend::dap_server::socket_path_for(pid)
                };
                // thread::spawn(move || {
                let res = db_backend::dap_server::run(&socket_path);
                if let Err(e) = res {
                    error!("dap server run error: {e:?}");
                }
                // })
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
