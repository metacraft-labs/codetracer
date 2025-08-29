#[macro_use]
extern crate log;

mod backend_manager;
mod dap_parser;
mod errors;

use std::{error::Error, sync::Arc};

use clap::Parser;
use tokio::{
    signal,
    sync::{Mutex, mpsc},
};

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
    let (shutdown_send, shutdown_recv) = mpsc::unbounded_channel::<()>();
    let shutdown_recv = Arc::new(Mutex::new(shutdown_recv));

    let runner_task = tokio::spawn(async move {
        let mgr = match BackendManager::new(shutdown_recv).await {
            Ok(x) => x,
            Err(err) => {
                error!("Can't start: {err}");
                return;
            }
        };

        if let Some(cmd) = cli.start {
            let mut mgr = mgr.lock().await;
            // TODO: add args to cmd
            if let Err(err) = mgr.start_replay(&cmd, &[]).await {
                error!("Can't replay: {err}");
            }
        }
    });

    tokio::pin!(runner_task);

    loop {
        tokio::select! {
            _ = signal::ctrl_c() => {
                info!("Ctrl+C detected. Shutting down...");
                shutdown_send.send(()).inspect_err(|e| {
                    warn!("Can't perform graceful shutdown! {e}");
                })?;
            },
            _ = &mut runner_task => {
                info!("Finished");
                return Ok(());
            }
        }
    }
}
