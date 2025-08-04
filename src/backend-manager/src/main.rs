mod backend_manager;
mod dap_parser;
mod errors;

use std::error::Error;

use tokio::{signal, sync::mpsc};

use crate::backend_manager::BackendManager;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // TODO: maybe implement shutdown message?
    let (_shutdown_send, mut shutdown_recv) = mpsc::unbounded_channel::<()>();

    let mgr = BackendManager::new().await?;
    let mut mgr = mgr.lock().await;
    mgr.start_replay().await?;

    tokio::select! {
        _ = signal::ctrl_c() => {
            println!("Ctrl+C detected. Shutting down...")
        },
        _ = shutdown_recv.recv() => {},
    }

    Ok(())
}
