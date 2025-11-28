#[macro_use]
extern crate log;

mod backend_manager;
mod dap_parser;
mod errors;
mod paths;

use std::error::Error;

use clap::Parser;
use tokio::{signal, sync::mpsc};
// use flexi_logger::{Logger, FileSpec, Duplicate};

use crate::backend_manager::BackendManager;

#[derive(Parser, Debug)]
#[command(version)]
struct Cli {
    /// Execute this command to start as ID 0
    start: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // let _logger = Logger::try_with_str("info")?
    //     .log_to_file(FileSpec::default())         // write logs to file
    //     .duplicate_to_stderr(Duplicate::Warn)     // print warnings and errors also to the console
    //     .start()?;
    flexi_logger::init();

    let cli = Cli::parse();

    // TODO: maybe implement shutdown message?
    let (_shutdown_send, mut shutdown_recv) = mpsc::unbounded_channel::<()>();

    let mgr = BackendManager::new().await?;

    if let Some(cmd) = cli.start {
        let mut mgr = mgr.lock().await;
        // TODO: add args to cmd
        mgr.start_replay(&cmd, &[]).await?;
    }

    tokio::select! {
        _ = signal::ctrl_c() => {
            println!("Ctrl+C detected. Shutting down...")
        },
        _ = shutdown_recv.recv() => {},
    }

    Ok(())
}
