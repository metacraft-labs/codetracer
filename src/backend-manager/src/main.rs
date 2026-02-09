#[macro_use]
extern crate log;

mod backend_manager;
mod dap_parser;
mod errors;
mod paths;

use std::error::Error;
use std::path::PathBuf;

use clap::{Parser, Subcommand};
use serde_json::json;
use tokio::{
    fs::{create_dir_all, read_to_string, remove_file, write},
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
    signal,
    sync::mpsc,
};
// use flexi_logger::{Logger, FileSpec, Duplicate};

use crate::backend_manager::BackendManager;
use crate::dap_parser::DapParser;
use crate::paths::CODETRACER_PATHS;

#[derive(Parser, Debug)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Execute this command to start as ID 0 (legacy single-client mode)
    start: Option<String>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Run in daemon mode (multi-client, well-known socket)
    Daemon {
        #[command(subcommand)]
        action: DaemonAction,
    },
}

#[derive(Subcommand, Debug)]
enum DaemonAction {
    /// Start the daemon (foreground)
    Start,
    /// Stop a running daemon
    Stop,
    /// Check daemon status
    Status,
}

// ---------------------------------------------------------------------------
// PID-file helpers
// ---------------------------------------------------------------------------

/// Checks whether a process with the given PID is currently alive.
///
/// Uses the POSIX `kill(pid, 0)` technique: sending signal 0 does not
/// actually deliver a signal but still performs the permission / existence
/// check.
fn is_pid_alive(pid: u32) -> bool {
    // SAFETY: signal 0 never kills anything; it only checks existence.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

/// Writes the current process PID to the daemon PID file.
///
/// If a PID file already exists *and* the recorded process is still alive,
/// returns an error so the caller can abort instead of running a second
/// daemon instance.
async fn write_pid_file(pid_path: &PathBuf) -> Result<(), Box<dyn Error>> {
    // Ensure the parent directory exists.
    if let Some(parent) = pid_path.parent() {
        create_dir_all(parent).await?;
    }

    // Check for a stale PID file.
    if pid_path.exists() {
        let contents = read_to_string(pid_path).await.unwrap_or_default();
        if let Ok(old_pid) = contents.trim().parse::<u32>()
            && is_pid_alive(old_pid)
        {
            return Err(Box::new(errors::DaemonAlreadyRunning(old_pid)));
        }
        // Stale — remove it and continue.
        let _ = remove_file(pid_path).await;
    }

    let pid = std::process::id();
    write(pid_path, pid.to_string()).await?;
    info!("PID file written: {} (pid={})", pid_path.display(), pid);
    Ok(())
}

/// Removes the PID file if it exists.
async fn remove_pid_file(pid_path: &PathBuf) {
    if let Err(err) = remove_file(pid_path).await {
        // It is fine if the file was already removed.
        if err.kind() != std::io::ErrorKind::NotFound {
            warn!("Could not remove PID file {}: {err}", pid_path.display());
        }
    }
}

// ---------------------------------------------------------------------------
// Daemon stop / status subcommands
// ---------------------------------------------------------------------------

/// Connects to the daemon socket and sends a `ct/daemon-shutdown` request.
///
/// Waits briefly for the acknowledgement response before returning.
async fn daemon_stop(socket_path: &PathBuf) -> Result<(), Box<dyn Error>> {
    let mut stream = match UnixStream::connect(socket_path).await {
        Ok(s) => s,
        Err(err) => {
            eprintln!("Cannot connect to daemon at {}: {err}", socket_path.display());
            eprintln!("Daemon is not running.");
            return Err(Box::new(err));
        }
    };

    let request = json!({
        "type": "request",
        "command": "ct/daemon-shutdown",
        "seq": 1
    });
    let bytes = DapParser::to_bytes(&request);
    stream.write_all(&bytes).await?;

    // Wait briefly for the ack.
    let mut buf = vec![0u8; 4096];
    let timeout = tokio::time::timeout(std::time::Duration::from_secs(5), stream.read(&mut buf));
    match timeout.await {
        Ok(Ok(n)) if n > 0 => {
            // We got a response — daemon acknowledged shutdown.
            println!("Daemon acknowledged shutdown.");
        }
        _ => {
            println!("Daemon may have shut down (no response received).");
        }
    }

    Ok(())
}

/// Checks whether the daemon is running and prints a human-readable status
/// line to stdout.
async fn daemon_status(socket_path: &PathBuf, pid_path: &PathBuf) {
    // First, check the PID file.
    let pid_info = if pid_path.exists() {
        match read_to_string(pid_path).await {
            Ok(contents) => contents.trim().parse::<u32>().ok(),
            Err(_) => None,
        }
    } else {
        None
    };

    // Try to connect to the daemon socket.
    match UnixStream::connect(socket_path).await {
        Ok(_stream) => {
            if let Some(pid) = pid_info {
                println!("Daemon is running (PID {pid}).");
            } else {
                println!("Daemon is running (PID unknown).");
            }
        }
        Err(_) => {
            println!("Daemon is not running.");
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // let _logger = Logger::try_with_str("info")?
    //     .log_to_file(FileSpec::default())         // write logs to file
    //     .duplicate_to_stderr(Duplicate::Warn)     // print warnings and errors also to the console
    //     .start()?;
    flexi_logger::init();

    let cli = Cli::parse();

    // Resolve well-known daemon paths once.
    let (daemon_socket_path, daemon_pid_path) = {
        let paths = CODETRACER_PATHS.lock()?;
        (paths.daemon_socket_path(), paths.daemon_pid_path())
    };

    // ------------------------------------------------------------------
    // Daemon subcommands
    // ------------------------------------------------------------------
    if let Some(Commands::Daemon { action }) = cli.command {
        match action {
            DaemonAction::Start => {
                // Write PID file (fails if a daemon is already running).
                write_pid_file(&daemon_pid_path).await?;

                let (mgr, mut shutdown_rx) =
                    BackendManager::new_daemon(daemon_socket_path.clone()).await?;

                // Optionally auto-start a replay if requested.
                if let Some(cmd) = cli.start {
                    let mut locked = mgr.lock().await;
                    locked.start_replay(&cmd, &[]).await?;
                }

                // Wait for shutdown signal (Ctrl-C or ct/daemon-shutdown).
                tokio::select! {
                    _ = signal::ctrl_c() => {
                        println!("Ctrl+C detected. Shutting down daemon...");
                    }
                    _ = shutdown_rx.recv() => {
                        println!("Shutdown request received. Exiting daemon...");
                    }
                }

                // Clean up: remove socket and PID files.
                let _ = remove_file(&daemon_socket_path).await;
                remove_pid_file(&daemon_pid_path).await;

                println!("Daemon stopped.");
            }
            DaemonAction::Stop => {
                daemon_stop(&daemon_socket_path).await?;
            }
            DaemonAction::Status => {
                daemon_status(&daemon_socket_path, &daemon_pid_path).await;
            }
        }
        return Ok(());
    }

    // ------------------------------------------------------------------
    // Legacy single-client mode (original behaviour, unchanged)
    // ------------------------------------------------------------------

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
