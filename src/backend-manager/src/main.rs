#[macro_use]
extern crate log;

mod backend_manager;
mod dap_parser;
mod errors;

use std::error::Error;

use clap::Parser;
use tokio::{signal, sync::mpsc};

use crate::backend_manager::BackendManager;

#[derive(Parser, Debug)]
#[command(version)]
struct Cli {
    /// Execute this command to start as ID 0
    start: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    flexi_logger::init();

    let cli = Cli::parse();

    // TODO: maybe implement shutdown message?
    let (_shutdown_send, mut shutdown_recv) = mpsc::unbounded_channel::<()>();

    let mgr = BackendManager::new().await?;

    match cli.start {
        Some(cmd) => {
            let mut mgr = mgr.lock().await;
            mgr.start_replay(&cmd).await?;
        }

        None => {}
    }

    tokio::select! {
        _ = signal::ctrl_c() => {
            println!("Ctrl+C detected. Shutting down...")
        },
        _ = shutdown_recv.recv() => {},
    }

    Ok(())
}
