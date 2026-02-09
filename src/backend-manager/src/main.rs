#[macro_use]
extern crate log;

mod backend_manager;
mod config;
mod dap_init;
mod dap_parser;
mod errors;
mod paths;
mod python_bridge;
mod session;
mod trace_metadata;

use std::error::Error;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use clap::{Parser, Subcommand};
use serde_json::json;
use tokio::{
    fs::{create_dir_all, read_to_string, remove_file, write},
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
    signal,
    sync::mpsc,
};

use crate::backend_manager::BackendManager;
use crate::config::DaemonConfig;
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
    /// Mock backend for testing (connects to a socket and sleeps).
    ///
    /// Used by integration tests to simulate a child replay process that
    /// connects back to the parent's Unix listener.  The last positional
    /// argument is treated as the socket path; any preceding arguments are
    /// ignored (this matches `start_replay`'s convention of appending the
    /// socket path as the final CLI argument).
    #[command(trailing_var_arg = true)]
    MockBackend {
        /// All positional arguments; the last one is the socket path.
        args: Vec<String>,
    },
    /// Mock DAP-speaking backend for integration tests.
    ///
    /// Like `mock-backend`, but speaks the DAP protocol: responds to
    /// `initialize`, `launch`, and `configurationDone` requests, sends
    /// a `stopped` event, and then loops responding to further requests
    /// with generic success responses.
    ///
    /// The last positional argument is the socket path (same convention
    /// as `start_replay`).
    #[command(trailing_var_arg = true)]
    MockDapBackend {
        /// All positional arguments; the last one is the socket path.
        args: Vec<String>,
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
    /// Connect to daemon, auto-starting if needed (used by CLI/MCP clients)
    Connect,
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
// Daemon stop / status / connect subcommands
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

/// Auto-daemonization: connects to the daemon, starting it if necessary.
///
/// Protocol:
/// 1. Try to connect to the well-known daemon socket.
/// 2. If the connection fails (socket missing or stale):
///    a. Remove the stale socket file if present.
///    b. Spawn `backend-manager daemon start` as a detached child process.
///    c. Poll for the socket file and a successful connection (exponential
///    backoff, up to 5 seconds).
/// 3. Once connected, print "connected" and exit.
async fn daemon_connect(
    socket_path: &PathBuf,
    pid_path: &PathBuf,
) -> Result<(), Box<dyn Error>> {
    // Try to connect to an existing daemon.
    if socket_path.exists() {
        if let Ok(stream) = UnixStream::connect(socket_path).await {
            drop(stream);
            println!("connected");
            return Ok(());
        }
        // Socket file exists but connection failed — stale.
        info!("Removing stale socket file: {}", socket_path.display());
        let _ = remove_file(socket_path).await;
    }

    // Also clean up a stale PID file if the process is dead.
    if pid_path.exists() {
        let contents = read_to_string(pid_path).await.unwrap_or_default();
        if let Ok(old_pid) = contents.trim().parse::<u32>()
            && !is_pid_alive(old_pid)
        {
            info!("Removing stale PID file for dead process {old_pid}");
            let _ = remove_file(pid_path).await;
        }
    }

    // Ensure the daemon socket directory exists.
    if let Some(parent) = socket_path.parent() {
        create_dir_all(parent).await?;
    }

    // Spawn `backend-manager daemon start` as a detached process.
    let exe = std::env::current_exe()?;
    info!(
        "Auto-starting daemon: {} daemon start",
        exe.display()
    );

    // Build the command with the same environment (including TMPDIR) so that
    // the daemon uses the same paths.
    let _child = std::process::Command::new(&exe)
        .arg("daemon")
        .arg("start")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("failed to spawn daemon: {e}"))?;

    // Poll for the socket file to appear and a successful connection.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut delay = Duration::from_millis(50);

    loop {
        tokio::time::sleep(delay).await;

        if socket_path.exists()
            && let Ok(stream) = UnixStream::connect(socket_path).await
        {
            drop(stream);
            println!("connected");
            return Ok(());
        }

        if tokio::time::Instant::now() > deadline {
            return Err("timeout waiting for daemon to start".into());
        }

        // Exponential backoff: 50ms, 100ms, 200ms, ...
        delay = (delay * 2).min(Duration::from_millis(500));
    }
}

// ---------------------------------------------------------------------------
// Mock backend (for integration tests)
// ---------------------------------------------------------------------------

/// A minimal mock backend that connects to a Unix socket and sleeps.
///
/// Used by integration tests to simulate a child replay process.  The real
/// replay backend connects to a listener socket created by `start_replay`;
/// this mock does the same but simply sleeps instead of speaking DAP.
async fn run_mock_backend(socket_path: &str) -> Result<(), Box<dyn Error>> {
    let _stream = UnixStream::connect(socket_path).await?;
    // Keep the connection alive indefinitely (until killed).
    loop {
        tokio::time::sleep(Duration::from_secs(3600)).await;
    }
}

/// A DAP-speaking mock backend for integration tests.
///
/// Connects to the parent's listener socket, reads DAP messages, and
/// responds to the standard initialization sequence (`initialize`,
/// `launch`, `configurationDone`) with success responses plus a
/// `stopped` event.  After initialization, handles navigation commands
/// (`next`, `stepIn`, `stepOut`, `stepBack`, `continue`,
/// `reverseContinue`, `ct/goto-ticks`) with stateful tracking: each
/// command updates the mock's current position (file, line, ticks) and
/// emits a `stopped` event.  `stackTrace` returns the current position.
///
/// This enables end-to-end testing of the `ct/open-trace` and
/// `ct/py-navigate` flows without needing a real db-backend binary.
async fn run_mock_dap_backend(socket_path: &str) -> Result<(), Box<dyn Error>> {
    use tokio::io::AsyncReadExt as _;

    let stream = UnixStream::connect(socket_path).await?;
    let (mut read_half, mut write_half) = tokio::io::split(stream);

    let mut parser = DapParser::new();
    let mut buf = vec![0u8; 8 * 1024];
    let mut init_done = false;

    // Stateful mock position for navigation commands.
    //
    // The mock simulates a small program across three files:
    // - "main.nim" (main function, lines 1-100)
    // - "helpers.nim" (helper function, lines 10-50)
    // - "process.nim" (process function, lines 20-80)
    let mut current_file = "main.nim".to_string();
    let mut current_line: i64 = 1;
    let current_column: i64 = 1;
    let mut current_ticks: i64 = 100;
    let mut end_of_trace = false;
    // Track call depth for step_in / step_out simulation.
    let mut call_depth: i32 = 0;

    // Breakpoint and watchpoint tracking for the mock backend.
    //
    // `breakpoints` stores (file, line) pairs received via setBreakpoints.
    // `watchpoints` stores watched expressions received via setDataBreakpoints.
    // When `continue` is called, the mock checks for the next breakpoint
    // line after the current position.  When `reverseContinue` is called,
    // it checks for the previous breakpoint line.  If a watchpoint is
    // active, `continue` simulates a variable change at line 5.
    let mut breakpoints: Vec<(String, i64)> = Vec::new();
    let mut watchpoints: Vec<String> = Vec::new();

    loop {
        let cnt = read_half.read(&mut buf).await?;
        if cnt == 0 {
            // EOF — parent closed the connection.
            break;
        }

        parser.add_bytes(&buf[..cnt]);

        loop {
            let msg = match parser.get_message() {
                Some(Ok(msg)) => msg,
                Some(Err(e)) => {
                    warn!("mock-dap-backend: bad DAP message: {e}");
                    continue;
                }
                None => break,
            };

            let msg_type = msg.get("type").and_then(serde_json::Value::as_str).unwrap_or("");
            let command = msg.get("command").and_then(serde_json::Value::as_str).unwrap_or("");
            let seq = msg.get("seq").and_then(serde_json::Value::as_i64).unwrap_or(0);

            if msg_type != "request" {
                // Ignore non-request messages.
                continue;
            }

            match command {
                "initialize" => {
                    let response = json!({
                        "type": "response",
                        "command": "initialize",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "supportsConfigurationDoneRequest": true,
                            "supportsStepBack": true,
                        }
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
                "launch" => {
                    let response = json!({
                        "type": "response",
                        "command": "launch",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
                "configurationDone" => {
                    let response = json!({
                        "type": "response",
                        "command": "configurationDone",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    // Send the stopped event after configurationDone.
                    if !init_done {
                        let stopped = json!({
                            "type": "event",
                            "event": "stopped",
                            "body": {
                                "reason": "entry",
                                "threadId": 1,
                            }
                        });
                        write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                        init_done = true;
                    }
                }
                // --- Navigation commands ---
                // Each navigation command: update state, send success response,
                // then send a "stopped" event.
                "next" => {
                    // step_over: advance one line, increment ticks.
                    end_of_trace = false;
                    current_line += 1;
                    current_ticks += 10;

                    let response = json!({
                        "type": "response",
                        "command": "next",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    let stopped = json!({
                        "type": "event",
                        "event": "stopped",
                        "body": {"reason": "step", "threadId": 1}
                    });
                    write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                }
                "stepIn" => {
                    // step_in: dive into a function (change file to helpers.nim).
                    end_of_trace = false;
                    call_depth += 1;
                    current_file = "helpers.nim".to_string();
                    current_line = 10;
                    current_ticks += 10;

                    let response = json!({
                        "type": "response",
                        "command": "stepIn",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    let stopped = json!({
                        "type": "event",
                        "event": "stopped",
                        "body": {"reason": "step", "threadId": 1}
                    });
                    write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                }
                "stepOut" => {
                    // step_out: return to caller (main.nim).
                    end_of_trace = false;
                    if call_depth > 0 {
                        call_depth -= 1;
                    }
                    current_file = "main.nim".to_string();
                    current_line += 1;
                    current_ticks += 10;

                    let response = json!({
                        "type": "response",
                        "command": "stepOut",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    let stopped = json!({
                        "type": "event",
                        "event": "stopped",
                        "body": {"reason": "step", "threadId": 1}
                    });
                    write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                }
                "stepBack" => {
                    // step_back: go back one line, decrement ticks.
                    end_of_trace = false;
                    current_line = (current_line - 1).max(1);
                    current_ticks = (current_ticks - 10).max(100);

                    let response = json!({
                        "type": "response",
                        "command": "stepBack",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    let stopped = json!({
                        "type": "event",
                        "event": "stopped",
                        "body": {"reason": "step", "threadId": 1}
                    });
                    write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                }
                "continue" => {
                    // continue_forward: check for breakpoints/watchpoints ahead
                    // of the current position, otherwise jump to end of trace.

                    // Find the nearest breakpoint line > current_line in the
                    // current file.
                    let next_bp = breakpoints.iter()
                        .filter(|(f, l)| f == &current_file && *l > current_line)
                        .map(|(_, l)| *l)
                        .min();

                    // Simulate a watchpoint trigger: if any watchpoint is active
                    // and we haven't yet reached line 5, the variable "changes"
                    // at line 5.
                    let wp_trigger = if !watchpoints.is_empty() && current_line < 5 {
                        Some(5i64)
                    } else {
                        None
                    };

                    // Pick the nearest stop point.
                    let stop_line = match (next_bp, wp_trigger) {
                        (Some(bp), Some(wp)) => bp.min(wp),
                        (Some(bp), None) => bp,
                        (None, Some(wp)) => wp,
                        (None, None) => 100, // end of trace
                    };

                    let stop_reason;
                    if stop_line >= 100 && next_bp.is_none() && wp_trigger.is_none() {
                        // No breakpoint or watchpoint hit; jump to end of trace.
                        end_of_trace = true;
                        current_line = 100;
                        current_ticks = 99999;
                        stop_reason = "end";
                    } else {
                        end_of_trace = false;
                        current_ticks += (stop_line - current_line) * 10;
                        current_line = stop_line;
                        stop_reason = "breakpoint";
                    }

                    let response = json!({
                        "type": "response",
                        "command": "continue",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    let stopped = json!({
                        "type": "event",
                        "event": "stopped",
                        "body": {"reason": stop_reason, "threadId": 1}
                    });
                    write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                }
                "reverseContinue" => {
                    // continue_reverse: check for breakpoints behind the
                    // current position, otherwise jump to start of trace.

                    let prev_bp = breakpoints.iter()
                        .filter(|(f, l)| f == &current_file && *l < current_line)
                        .map(|(_, l)| *l)
                        .max();

                    let stop_reason;
                    match prev_bp {
                        Some(line) => {
                            end_of_trace = false;
                            current_ticks -= (current_line - line) * 10;
                            current_line = line;
                            stop_reason = "breakpoint";
                        }
                        None => {
                            end_of_trace = true;
                            current_line = 1;
                            current_ticks = 100;
                            stop_reason = "start";
                        }
                    }

                    let response = json!({
                        "type": "response",
                        "command": "reverseContinue",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    let stopped = json!({
                        "type": "event",
                        "event": "stopped",
                        "body": {"reason": stop_reason, "threadId": 1}
                    });
                    write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                }
                "ct/goto-ticks" => {
                    // goto_ticks: jump to a specific ticks value.
                    end_of_trace = false;
                    let requested_ticks = msg
                        .get("arguments")
                        .and_then(|a| a.get("ticks"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(100);
                    current_ticks = requested_ticks;
                    // Derive a line number from ticks for deterministic testing.
                    current_line = ((requested_ticks - 100) / 10) + 1;

                    let response = json!({
                        "type": "response",
                        "command": "ct/goto-ticks",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    let stopped = json!({
                        "type": "event",
                        "event": "stopped",
                        "body": {"reason": "goto", "threadId": 1}
                    });
                    write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                }
                "ct/reverseStepIn" | "ct/reverseStepOut" => {
                    // Reverse step variants: decrement ticks, adjust position.
                    end_of_trace = false;
                    current_line = (current_line - 1).max(1);
                    current_ticks = (current_ticks - 10).max(100);

                    let response = json!({
                        "type": "response",
                        "command": command,
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;

                    let stopped = json!({
                        "type": "event",
                        "event": "stopped",
                        "body": {"reason": "step", "threadId": 1}
                    });
                    write_half.write_all(&DapParser::to_bytes(&stopped)).await?;
                }
                // --- ct/load-locals: returns mock local variables ---
                //
                // The response format mirrors the CodeTracer extension that
                // returns variables already expanded to the requested depth
                // with children included inline.
                "ct/load-locals" => {
                    let depth = msg
                        .get("arguments")
                        .and_then(|a| a.get("depth"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(3);

                    // Build the "point" variable with nested children.
                    // When depth > 1, the children are populated; when
                    // depth == 1, only top-level variables are returned
                    // (children are empty).
                    let point_children = if depth > 1 {
                        json!([
                            {"name": "x", "value": "1", "type": "int", "children": []},
                            {"name": "y", "value": "2", "type": "int", "children": []},
                        ])
                    } else {
                        json!([])
                    };

                    let response = json!({
                        "type": "response",
                        "command": "ct/load-locals",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "variables": [
                                {"name": "x", "value": "42", "type": "int", "children": []},
                                {"name": "y", "value": "20", "type": "int", "children": []},
                                {"name": "point", "value": "Point{x: 1, y: 2}", "type": "Point",
                                 "children": point_children},
                            ]
                        }
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
                // --- evaluate: evaluates expressions against mock state ---
                "evaluate" => {
                    let expression = msg
                        .get("arguments")
                        .and_then(|a| a.get("expression"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");

                    let response = match expression {
                        "x" => json!({
                            "type": "response",
                            "command": "evaluate",
                            "request_seq": seq,
                            "success": true,
                            "body": {"result": "42", "type": "int"}
                        }),
                        "y" => json!({
                            "type": "response",
                            "command": "evaluate",
                            "request_seq": seq,
                            "success": true,
                            "body": {"result": "20", "type": "int"}
                        }),
                        "x + y" => json!({
                            "type": "response",
                            "command": "evaluate",
                            "request_seq": seq,
                            "success": true,
                            "body": {"result": "30", "type": "int"}
                        }),
                        other => json!({
                            "type": "response",
                            "command": "evaluate",
                            "request_seq": seq,
                            "success": false,
                            "message": format!("cannot evaluate: {other}")
                        }),
                    };
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
                // --- ct/load-flow: returns mock flow/omniscience data ---
                //
                // Simulates a loop body with `i` from 0 to 4 and `x = i * 2`.
                // In "call" mode, returns additional steps for function entry
                // and exit (spanning the full function).  In "line" mode,
                // returns only the steps for the specific queried line.
                "ct/load-flow" => {
                    let line = msg
                        .get("arguments")
                        .and_then(|a| a.get("line"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(1);
                    let mode = msg
                        .get("arguments")
                        .and_then(|a| a.get("mode"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("call");

                    // Generate mock flow data with a loop (i from 0 to 4, x = i * 2).
                    let mut steps = vec![];

                    if mode == "call" {
                        // Call mode: return steps spanning the full function (more steps).
                        // Include a step at function entry before the loop.
                        steps.push(json!({
                            "line": 5, "ticks": 50, "loopId": 0, "iteration": 0,
                            "beforeValues": {}, "afterValues": {"i": "0", "x": "0"}
                        }));

                        // Loop iterations: i from 0 to 4, x = i * 2.
                        for i in 0..5i64 {
                            let x = i * 2;
                            let prev_x = if i > 0 { (i - 1) * 2 } else { 0 };
                            steps.push(json!({
                                "line": line, "ticks": 100 + i * 10,
                                "loopId": 1, "iteration": i,
                                "beforeValues": {"i": format!("{i}"), "x": format!("{prev_x}")},
                                "afterValues": {"i": format!("{i}"), "x": format!("{x}")}
                            }));
                        }

                        // Post-loop step at function exit.
                        steps.push(json!({
                            "line": 15, "ticks": 200, "loopId": 0, "iteration": 0,
                            "beforeValues": {"x": "8"}, "afterValues": {"result": "8"}
                        }));
                    } else {
                        // Line mode: only return steps for the specific line (fewer steps).
                        for i in 0..5i64 {
                            let x = i * 2;
                            steps.push(json!({
                                "line": line, "ticks": 100 + i * 10,
                                "loopId": 1, "iteration": i,
                                "beforeValues": {"i": format!("{i}")},
                                "afterValues": {"x": format!("{x}")}
                            }));
                        }
                    }

                    let loops = json!([{
                        "id": 1, "startLine": 8, "endLine": 12, "iterationCount": 5
                    }]);

                    let response = json!({
                        "type": "response",
                        "command": "ct/load-flow",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "steps": steps,
                            "loops": loops,
                            "finished": true,
                        }
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
                // --- stackTrace: returns current mock position ---
                //
                // When call_depth > 0 (after stepIn), returns multiple frames
                // to simulate a real call stack.  The top frame is the current
                // position, and additional frames represent the call chain.
                "stackTrace" => {
                    let mut frames = vec![json!({
                        "id": 0,
                        "name": if call_depth > 0 { "helper" } else { "main" },
                        "source": {"path": current_file},
                        "line": current_line,
                        "column": current_column,
                        "ticks": current_ticks,
                        "endOfTrace": end_of_trace,
                    })];

                    // Add caller frames when we are inside a function call.
                    if call_depth > 0 {
                        frames.push(json!({
                            "id": 1,
                            "name": "main",
                            "source": {"path": "main.nim"},
                            "line": 5,
                            "column": 1,
                            "ticks": current_ticks - 10,
                            "endOfTrace": false,
                        }));
                    }

                    let total_frames = frames.len();
                    let response = json!({
                        "type": "response",
                        "command": "stackTrace",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "stackFrames": frames,
                            "totalFrames": total_frames,
                        }
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
                // --- setBreakpoints: update tracked breakpoints for a file ---
                //
                // The DAP `setBreakpoints` command replaces ALL breakpoints
                // for a single source file.  We extract the source path and
                // the breakpoint lines, store them, and return verified
                // breakpoints.
                "setBreakpoints" => {
                    let source_path = msg
                        .get("arguments")
                        .and_then(|a| a.get("source"))
                        .and_then(|s| s.get("path"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("")
                        .to_string();

                    let bp_array = msg
                        .get("arguments")
                        .and_then(|a| a.get("breakpoints"))
                        .and_then(serde_json::Value::as_array);

                    // Remove all existing breakpoints for this file.
                    breakpoints.retain(|(f, _)| f != &source_path);

                    let mut result_bps = vec![];
                    if let Some(bps) = bp_array {
                        for (i, bp) in bps.iter().enumerate() {
                            let line = bp
                                .get("line")
                                .and_then(serde_json::Value::as_i64)
                                .unwrap_or(0);
                            breakpoints.push((source_path.clone(), line));
                            result_bps.push(json!({
                                "id": i + 1,
                                "verified": true,
                                "line": line,
                            }));
                        }
                    }

                    let response = json!({
                        "type": "response",
                        "command": "setBreakpoints",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "breakpoints": result_bps,
                        }
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
                // --- setDataBreakpoints: update tracked watchpoints ---
                //
                // Replaces all data breakpoints (watchpoints).  Each entry
                // has a `dataId` field containing the watched expression.
                "setDataBreakpoints" => {
                    let bp_array = msg
                        .get("arguments")
                        .and_then(|a| a.get("breakpoints"))
                        .and_then(serde_json::Value::as_array);

                    watchpoints.clear();
                    let mut result_bps = vec![];
                    if let Some(bps) = bp_array {
                        for (i, bp) in bps.iter().enumerate() {
                            let expr = bp
                                .get("dataId")
                                .and_then(serde_json::Value::as_str)
                                .unwrap_or("")
                                .to_string();
                            watchpoints.push(expr.clone());
                            result_bps.push(json!({
                                "id": i + 1,
                                "verified": true,
                                "dataId": expr,
                            }));
                        }
                    }

                    let response = json!({
                        "type": "response",
                        "command": "setDataBreakpoints",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "breakpoints": result_bps,
                        }
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
                _ => {
                    // Generic success response for any other command.
                    let response = json!({
                        "type": "response",
                        "command": command,
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half.write_all(&DapParser::to_bytes(&response)).await?;
                }
            }
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Daemon logging
// ---------------------------------------------------------------------------

/// Configures logging for daemon mode.
///
/// If a log file path is configured (via [`DaemonConfig`]), writes logs to
/// that file.  Otherwise, writes to `~/.codetracer/daemon.log`.  Falls back
/// to stderr if file logging cannot be set up.
fn init_daemon_logging(config: &DaemonConfig) {
    let log_path = config.log_file.clone().or_else(|| {
        std::env::var("HOME")
            .ok()
            .map(|home| PathBuf::from(home).join(".codetracer").join("daemon.log"))
    });

    if let Some(path) = log_path {
        // Ensure the parent directory exists.
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        let dir = path
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .to_path_buf();
        let basename = path
            .file_stem()
            .unwrap_or_else(|| std::ffi::OsStr::new("daemon"))
            .to_string_lossy()
            .to_string();

        match flexi_logger::Logger::try_with_str("info") {
            Ok(logger) => {
                let result = logger
                    .log_to_file(
                        flexi_logger::FileSpec::default()
                            .directory(dir)
                            .basename(basename),
                    )
                    .start();
                match result {
                    Ok(_handle) => {
                        // Logger started, _handle kept alive by being moved
                        // into main's scope (we leak it intentionally since
                        // the daemon runs for the entire process lifetime).
                        std::mem::forget(_handle);
                        return;
                    }
                    Err(e) => {
                        eprintln!("Warning: could not start file logging: {e}");
                    }
                }
            }
            Err(e) => {
                eprintln!("Warning: could not configure logger: {e}");
            }
        }
    }

    // Fallback: basic stderr logging.
    flexi_logger::init();
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse();

    // Resolve well-known daemon paths once.
    let (daemon_socket_path, daemon_pid_path) = {
        let paths = CODETRACER_PATHS.lock()?;
        (paths.daemon_socket_path(), paths.daemon_pid_path())
    };

    // ------------------------------------------------------------------
    // MockBackend subcommand (used by integration tests)
    // ------------------------------------------------------------------
    if let Some(Commands::MockBackend { args }) = &cli.command {
        flexi_logger::init();
        let socket_path = args
            .last()
            .ok_or("mock-backend: no arguments provided (expected socket path as last arg)")?;
        return run_mock_backend(socket_path).await;
    }

    // ------------------------------------------------------------------
    // MockDapBackend subcommand (used by M2+ integration tests)
    // ------------------------------------------------------------------
    if let Some(Commands::MockDapBackend { args }) = &cli.command {
        flexi_logger::init();
        let socket_path = args
            .last()
            .ok_or("mock-dap-backend: no arguments provided (expected socket path as last arg)")?;
        return run_mock_dap_backend(socket_path).await;
    }

    // ------------------------------------------------------------------
    // Daemon subcommands
    // ------------------------------------------------------------------
    if let Some(Commands::Daemon { action }) = cli.command {
        match action {
            DaemonAction::Start => {
                // Load configuration from env vars / config file / defaults.
                let config = DaemonConfig::load();

                // Detach from the controlling terminal (if any) so that the
                // daemon survives the parent process exiting.
                // SAFETY: setsid() is safe to call; it creates a new session
                // if the calling process is not already a process group leader.
                // If it fails (e.g. when already a session leader), we simply
                // ignore the error — the daemon still works, just without full
                // terminal detachment.
                unsafe {
                    libc::setsid();
                }

                // Configure daemon-mode logging (file-based).
                init_daemon_logging(&config);

                // Write PID file (fails if a daemon is already running).
                write_pid_file(&daemon_pid_path).await?;

                let (mgr, mut shutdown_rx) =
                    BackendManager::new_daemon(daemon_socket_path.clone(), config).await?;

                // Optionally auto-start a replay if requested.
                if let Some(cmd) = cli.start {
                    let mut locked = mgr.lock().await;
                    locked.start_replay(&cmd, &[]).await?;
                }

                // Wait for shutdown signal (Ctrl-C, ct/daemon-shutdown, or auto-shutdown).
                tokio::select! {
                    _ = signal::ctrl_c() => {
                        info!("Ctrl+C detected. Shutting down daemon...");
                    }
                    _ = shutdown_rx.recv() => {
                        info!("Shutdown request received. Exiting daemon...");
                    }
                }

                // Clean up: remove socket and PID files.
                let _ = remove_file(&daemon_socket_path).await;
                remove_pid_file(&daemon_pid_path).await;

                info!("Daemon stopped.");
            }
            DaemonAction::Stop => {
                flexi_logger::init();
                daemon_stop(&daemon_socket_path).await?;
            }
            DaemonAction::Status => {
                flexi_logger::init();
                daemon_status(&daemon_socket_path, &daemon_pid_path).await;
            }
            DaemonAction::Connect => {
                flexi_logger::init();
                daemon_connect(&daemon_socket_path, &daemon_pid_path).await?;
            }
        }
        return Ok(());
    }

    // ------------------------------------------------------------------
    // Legacy single-client mode (original behaviour, unchanged)
    // ------------------------------------------------------------------
    flexi_logger::init();

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
