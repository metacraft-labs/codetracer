#[macro_use]
extern crate log;

mod backend_manager;
mod config;
mod dap_init;
mod dap_parser;
mod errors;
pub mod mcp_server;
mod paths;
mod python_bridge;
mod script_executor;
mod session;
mod trace_metadata;

use std::error::Error;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use clap::{Parser, Subcommand};
use serde_json::{Value, json};
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
#[command(
    version,
    about = "CodeTracer backend manager -- daemon, trace CLI, and MCP server.",
    long_about = "CodeTracer backend manager.\n\n\
        Provides:\n  \
        - A daemon that manages replay backend processes (ct daemon start)\n  \
        - A CLI for inspecting recorded traces (ct trace query / ct trace info)\n  \
        - An MCP server for LLM agent integration (ct trace mcp)"
)]
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
    /// Trace inspection and scripting commands.
    ///
    /// Connects to the daemon (auto-starting if needed) and provides CLI
    /// access to trace data.
    Trace {
        #[command(subcommand)]
        action: TraceAction,
    },
}

/// Subcommands under `ct trace`.
#[derive(Subcommand, Debug)]
enum TraceAction {
    /// Execute a Python script against a trace.
    ///
    /// The script has access to a pre-bound `trace` variable (a
    /// `codetracer.Trace` instance) connected to the daemon.  Script
    /// stdout is printed to the terminal.
    ///
    /// Scripts can be provided in three ways:
    ///   ct trace query /path script.py          # from file
    ///   ct trace query /path -c "print('hi')"   # inline code
    ///   ct trace query /path <<'PYEOF'          # from stdin (HEREDOC)
    ///   trace.step_over()
    ///   print(trace.location)
    ///   PYEOF
    Query {
        /// Path to the trace directory.
        trace_path: PathBuf,

        /// Python script file to execute (omit when using `-c`).
        script_file: Option<PathBuf>,

        /// Inline Python code to execute.
        #[arg(short = 'c', long = "code")]
        code: Option<String>,

        /// Execution timeout in seconds.
        #[arg(long, default_value_t = 30)]
        timeout: u64,

        /// Reusable session identifier for stateful debugging.
        ///
        /// When provided, the trace session is kept alive after the script
        /// finishes so that subsequent calls with the same session ID
        /// continue from the same execution position (breakpoints, ticks).
        /// Without this flag, each call creates and destroys its own session.
        #[arg(long)]
        session: Option<String>,

        /// Close a named session without running a script.
        ///
        /// Explicitly tears down the session and kills the backend process.
        /// Without this, sessions are cleaned up automatically by the
        /// daemon's TTL timer after an idle period.
        #[arg(long)]
        session_close: Option<String>,
    },
    /// Print trace metadata (language, events, source files).
    Info {
        /// Path to the trace directory.
        trace_path: PathBuf,
    },
    /// Start the MCP (Model Context Protocol) server on stdio.
    ///
    /// The MCP server exposes CodeTracer trace querying as tools for
    /// LLM agents.  It communicates via JSON-RPC 2.0 over stdin/stdout,
    /// following the Model Context Protocol specification.
    ///
    /// All diagnostic logging goes to stderr; stdout is reserved
    /// exclusively for JSON-RPC messages.
    ///
    /// The server connects to the daemon (auto-starting if needed) to
    /// execute tool operations.
    Mcp,
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
            eprintln!(
                "Cannot connect to daemon at {}: {err}",
                socket_path.display()
            );
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
async fn daemon_connect(socket_path: &PathBuf, pid_path: &PathBuf) -> Result<(), Box<dyn Error>> {
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
    info!("Auto-starting daemon: {} daemon start", exe.display());

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

    // Multi-process simulation state.
    //
    // `is_multi_process` is determined by the trace folder path: if it
    // contains "multi" then the mock simulates a multi-process trace
    // with two processes.  `selected_process_id` tracks which process
    // is currently selected (affects locals and other query responses).
    let mut is_multi_process = false;
    let mut selected_process_id: i64 = 1;

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

            let msg_type = msg
                .get("type")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            let command = msg
                .get("command")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            let seq = msg
                .get("seq")
                .and_then(serde_json::Value::as_i64)
                .unwrap_or(0);

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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                "launch" => {
                    // Detect multi-process mode from the trace folder path.
                    // If the traceFolder argument contains "multi", the mock
                    // simulates a multi-process trace with two processes.
                    let trace_folder = msg
                        .get("arguments")
                        .and_then(|a| a.get("traceFolder"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    if trace_folder.contains("multi") {
                        is_multi_process = true;
                    }

                    let response = json!({
                        "type": "response",
                        "command": "launch",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                "configurationDone" => {
                    let response = json!({
                        "type": "response",
                        "command": "configurationDone",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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
                    let next_bp = breakpoints
                        .iter()
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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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

                    let prev_bp = breakpoints
                        .iter()
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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;

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
                //
                // In multi-process mode, the returned variables depend on
                // the currently selected process:
                // - Process 1 ("main"): x=42, y=20, point
                // - Process 2 ("child"): worker_id=7, task_count=3
                "ct/load-locals" => {
                    // The daemon sends `depthLimit` (matching the real
                    // backend's CtLoadLocalsArguments schema); fall back
                    // to the legacy `depth` key for older callers.
                    let depth = msg
                        .get("arguments")
                        .and_then(|a| a.get("depthLimit").or_else(|| a.get("depth")))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(3);

                    let mut variables = if is_multi_process && selected_process_id == 2 {
                        // Process 2 ("child") has different variables.
                        vec![
                            json!({"name": "worker_id", "value": "7", "type": "int", "children": []}),
                            json!({"name": "task_count", "value": "3", "type": "int", "children": []}),
                        ]
                    } else {
                        // Process 1 ("main") or single-process mode.
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
                        vec![
                            json!({"name": "x", "value": "42", "type": "int", "children": []}),
                            json!({"name": "y", "value": "20", "type": "int", "children": []}),
                            json!({"name": "point", "value": "Point{x: 1, y: 2}", "type": "Point",
                             "children": point_children}),
                        ]
                    };

                    // When the daemon translates ct/py-evaluate into a
                    // ct/load-locals request, it includes the expression
                    // in `watchExpressions`.  The mock resolves each
                    // watch expression and prepends the result to the
                    // variables list so format_evaluate_response can
                    // find it as the first entry.
                    if let Some(watch_arr) = msg
                        .get("arguments")
                        .and_then(|a| a.get("watchExpressions"))
                        .and_then(serde_json::Value::as_array)
                    {
                        let mut watch_results: Vec<Value> = Vec::new();
                        for watch in watch_arr {
                            let expr = watch.as_str().unwrap_or("");
                            match expr {
                                "x" => watch_results.push(json!({
                                    "name": "x", "value": "42", "type": "int", "children": []
                                })),
                                "y" => watch_results.push(json!({
                                    "name": "y", "value": "20", "type": "int", "children": []
                                })),
                                "x + y" => watch_results.push(json!({
                                    "name": "x + y", "value": "30", "type": "int", "children": []
                                })),
                                _ => {
                                    // Unknown expression — include a
                                    // sentinel with empty value so the
                                    // formatter can detect the failure.
                                    watch_results.push(json!({
                                        "name": expr,
                                        "value": "",
                                        "type": "",
                                        "children": [],
                                        "_watch_error": true
                                    }));
                                }
                            }
                        }
                        // Prepend watch results so they appear first.
                        watch_results.append(&mut variables);
                        variables = watch_results;
                    }

                    let response = json!({
                        "type": "response",
                        "command": "ct/load-locals",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "variables": serde_json::Value::Array(variables),
                        }
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                // --- ct/load-flow: returns mock flow/omniscience data ---
                //
                // Simulates a loop body with `i` from 0 to 4 and `x = i * 2`.
                // In "call" mode, returns additional steps for function entry
                // and exit (spanning the full function).  In "line" mode,
                // returns only the steps for the specific queried line.
                "ct/load-flow" => {
                    let args = msg.get("arguments");
                    // The daemon now sends `location.line` instead of top-level `line`.
                    let line = args
                        .and_then(|a| a.get("location"))
                        .and_then(|loc| loc.get("line"))
                        .and_then(serde_json::Value::as_i64)
                        .or_else(|| {
                            args.and_then(|a| a.get("line"))
                                .and_then(serde_json::Value::as_i64)
                        })
                        .unwrap_or(1);
                    // The daemon now sends `flowMode` as an integer (0=Call, 1=Diff)
                    // instead of a string `mode`.
                    let flow_mode = args
                        .and_then(|a| a.get("flowMode"))
                        .and_then(serde_json::Value::as_u64)
                        .unwrap_or(0); // default to Call
                    let is_call_mode = flow_mode == 0;

                    // Generate mock flow data with a loop (i from 0 to 4, x = i * 2).
                    let mut steps = vec![];

                    if is_call_mode {
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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                // --- ct/load-calltrace-section: returns mock call trace ---
                //
                // Returns a deterministic list of calls that can be sliced
                // by start/count.  The mock simulates three functions:
                // main, helper, and process.
                "ct/load-calltrace-section" => {
                    let args = msg.get("arguments");
                    let start = args
                        .and_then(|a| a.get("start"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(0) as usize;
                    let count = args
                        .and_then(|a| a.get("count"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(20) as usize;

                    let all_calls = vec![
                        json!({"id": 0, "name": "main", "location": {"path": "main.nim", "line": 1, "column": 1}, "returnValue": "0", "childrenCount": 2, "depth": 0}),
                        json!({"id": 1, "name": "helper", "location": {"path": "helpers.nim", "line": 10, "column": 1}, "returnValue": "42", "childrenCount": 0, "depth": 1}),
                        json!({"id": 2, "name": "process", "location": {"path": "process.nim", "line": 20, "column": 1}, "returnValue": null, "childrenCount": 1, "depth": 1}),
                    ];

                    let sliced: Vec<_> = all_calls.into_iter().skip(start).take(count).collect();

                    let response = json!({
                        "type": "response",
                        "command": "ct/load-calltrace-section",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "calls": sliced,
                        }
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                // --- ct/search-calltrace: search mock call trace by name ---
                "ct/search-calltrace" => {
                    let args = msg.get("arguments");
                    let query = args
                        .and_then(|a| a.get("query"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");

                    let all_calls = vec![
                        json!({"id": 0, "name": "main", "location": {"path": "main.nim", "line": 1, "column": 1}, "returnValue": "0", "childrenCount": 2, "depth": 0}),
                        json!({"id": 1, "name": "helper", "location": {"path": "helpers.nim", "line": 10, "column": 1}, "returnValue": "42", "childrenCount": 0, "depth": 1}),
                        json!({"id": 2, "name": "process", "location": {"path": "process.nim", "line": 20, "column": 1}, "returnValue": null, "childrenCount": 1, "depth": 1}),
                    ];

                    let matched: Vec<_> = all_calls
                        .into_iter()
                        .filter(|c| c["name"].as_str().unwrap_or("").contains(query))
                        .collect();

                    let response = json!({
                        "type": "response",
                        "command": "ct/search-calltrace",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "calls": matched,
                        }
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                // --- ct/event-load: returns mock events with optional filter ---
                //
                // Returns a mix of stdout and stderr events.  Supports
                // typeFilter to return only events of a specific type,
                // and start/count for pagination.
                "ct/event-load" => {
                    let args = msg.get("arguments");
                    let start = args
                        .and_then(|a| a.get("start"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(0) as usize;
                    let count = args
                        .and_then(|a| a.get("count"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(100) as usize;
                    let type_filter = args
                        .and_then(|a| a.get("typeFilter"))
                        .and_then(serde_json::Value::as_str);

                    let all_events = vec![
                        json!({"id": 0, "type": "stdout", "ticks": 100, "content": "Hello, World!\n", "location": {"path": "main.nim", "line": 5, "column": 1}}),
                        json!({"id": 1, "type": "stderr", "ticks": 200, "content": "warning: unused var\n", "location": {"path": "main.nim", "line": 8, "column": 1}}),
                        json!({"id": 2, "type": "stdout", "ticks": 300, "content": "Done.\n", "location": {"path": "main.nim", "line": 12, "column": 1}}),
                    ];

                    let filtered: Vec<_> = if let Some(tf) = type_filter {
                        all_events
                            .into_iter()
                            .filter(|e| e["type"].as_str().unwrap_or("") == tf)
                            .collect()
                    } else {
                        all_events
                    };

                    let sliced: Vec<_> = filtered.into_iter().skip(start).take(count).collect();

                    let response = json!({
                        "type": "response",
                        "command": "ct/event-load",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "events": sliced,
                        }
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                // --- ct/load-terminal: returns mock terminal output ---
                "ct/load-terminal" => {
                    let response = json!({
                        "type": "response",
                        "command": "ct/load-terminal",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "output": "Hello, World!\nDone.\n"
                        }
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                // --- ct/read-source: returns mock source file content ---
                //
                // Returns different content based on the requested path,
                // simulating a multi-file project.
                "ct/read-source" => {
                    let args = msg.get("arguments");
                    let path = args
                        .and_then(|a| a.get("path"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("main.nim");

                    let content = if path.contains("main") {
                        "proc main() =\n  echo \"Hello, World!\"\n  let x = 42\n  echo \"Done.\"\n"
                    } else if path.contains("helper") {
                        "proc helper(n: int): int =\n  return n * 2\n"
                    } else {
                        "# unknown source\n"
                    };

                    let response = json!({
                        "type": "response",
                        "command": "ct/read-source",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "content": content,
                        }
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                // --- ct/list-processes: returns the list of processes ---
                //
                // In multi-process mode (trace folder contains "multi"),
                // returns two processes.  Otherwise returns a single process.
                "ct/list-processes" => {
                    let processes = if is_multi_process {
                        json!([
                            {"id": 1, "name": "main", "command": "/usr/bin/prog"},
                            {"id": 2, "name": "child", "command": "/usr/bin/prog --worker"},
                        ])
                    } else {
                        json!([
                            {"id": 1, "name": "main", "command": "/usr/bin/prog"},
                        ])
                    };

                    let response = json!({
                        "type": "response",
                        "command": "ct/list-processes",
                        "request_seq": seq,
                        "success": true,
                        "body": {
                            "processes": processes,
                        }
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
                }
                // --- ct/select-replay: switches the selected process ---
                //
                // Updates the internal `selected_process_id` so that
                // subsequent queries (locals, evaluate, etc.) return
                // data from the selected process.
                "ct/select-replay" => {
                    let process_id = msg
                        .get("arguments")
                        .and_then(|a| a.get("processId"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(1);
                    selected_process_id = process_id;

                    let response = json!({
                        "type": "response",
                        "command": "ct/select-replay",
                        "request_seq": seq,
                        "success": true,
                        "body": {}
                    });
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
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
                    write_half
                        .write_all(&DapParser::to_bytes(&response))
                        .await?;
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
// CLI helpers: DAP communication from the CLI client
// ---------------------------------------------------------------------------

/// Sends a DAP request over `stream` and reads the response.
///
/// Returns the parsed JSON response.  Times out after `deadline` seconds.
async fn cli_dap_request(
    stream: &mut UnixStream,
    command: &str,
    seq: i64,
    arguments: serde_json::Value,
    deadline_secs: u64,
) -> Result<serde_json::Value, Box<dyn Error>> {
    let request = json!({
        "type": "request",
        "command": command,
        "seq": seq,
        "arguments": arguments,
    });
    let bytes = DapParser::to_bytes(&request);
    stream.write_all(&bytes).await?;

    // Read messages until we find the response matching our request.
    //
    // The daemon broadcasts events (e.g., "stopped", "initialized") to ALL
    // connected clients.  When `ct/exec-script` spawns a Python subprocess
    // that opens a trace on a new connection, the resulting backend events
    // may arrive on the CLI's connection before the actual exec-script
    // response.  We must skip those interleaved events/unrelated responses.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(deadline_secs);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(format!("timeout waiting for {command} response").into());
        }

        let msg = tokio::time::timeout(remaining, cli_dap_read(stream))
            .await
            .map_err(|_| format!("timeout waiting for {command} response"))??;

        // Skip events — we only want the response to our request.
        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            continue;
        }

        // Match on request_seq to ensure this is the response to OUR request,
        // not a stale response from a previous interaction.
        if msg_type == "response" {
            let resp_seq = msg.get("request_seq").and_then(Value::as_i64).unwrap_or(-1);
            if resp_seq != seq {
                continue;
            }
        }

        return Ok(msg);
    }
}

/// Reads a single DAP-framed JSON message from `stream`.
///
/// Minimal parser: reads `Content-Length` header, then the JSON body.
async fn cli_dap_read(stream: &mut UnixStream) -> Result<serde_json::Value, Box<dyn Error>> {
    let mut header_buf = Vec::with_capacity(256);
    let mut single = [0u8; 1];

    loop {
        let n = stream.read(&mut single).await?;
        if n == 0 {
            return Err("EOF while reading DAP header".into());
        }
        header_buf.push(single[0]);
        if header_buf.len() >= 4 && header_buf.ends_with(b"\r\n\r\n") {
            break;
        }
        if header_buf.len() > 8192 {
            return Err("DAP header too large".into());
        }
    }

    let header_str = String::from_utf8_lossy(&header_buf);
    let prefix = "Content-Length: ";
    let line = header_str
        .lines()
        .find(|l| l.starts_with(prefix))
        .ok_or("missing Content-Length in DAP header")?;
    let content_length: usize = line[prefix.len()..]
        .trim()
        .parse()
        .map_err(|e| format!("bad Content-Length: {e}"))?;

    let mut body_buf = vec![0u8; content_length];
    stream.read_exact(&mut body_buf).await?;

    Ok(serde_json::from_slice(&body_buf)?)
}

/// Ensures the daemon is running and returns a connected socket.
///
/// If the daemon socket does not exist or a connection attempt fails, this
/// function auto-starts the daemon by spawning `backend-manager daemon start`
/// as a background process and polling for the socket.
async fn ensure_daemon_connected(
    socket_path: &PathBuf,
    pid_path: &PathBuf,
) -> Result<UnixStream, Box<dyn Error>> {
    // First try to connect to an already-running daemon.
    if socket_path.exists() {
        if let Ok(stream) = UnixStream::connect(socket_path).await {
            return Ok(stream);
        }
        // Socket file exists but connection failed — stale.
        let _ = remove_file(socket_path).await;
    }

    // Clean up stale PID file if the process is dead.
    if pid_path.exists() {
        let contents = read_to_string(pid_path).await.unwrap_or_default();
        if let Ok(old_pid) = contents.trim().parse::<u32>()
            && !is_pid_alive(old_pid)
        {
            let _ = remove_file(pid_path).await;
        }
    }

    // Ensure the parent directory exists.
    if let Some(parent) = socket_path.parent() {
        create_dir_all(parent).await?;
    }

    // Spawn the daemon.
    let exe = std::env::current_exe()?;
    let _child = std::process::Command::new(&exe)
        .arg("daemon")
        .arg("start")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("failed to spawn daemon: {e}"))?;

    // Poll for the socket with exponential backoff.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut delay = Duration::from_millis(50);

    loop {
        tokio::time::sleep(delay).await;

        if socket_path.exists()
            && let Ok(stream) = UnixStream::connect(socket_path).await
        {
            return Ok(stream);
        }

        if tokio::time::Instant::now() > deadline {
            return Err("timeout waiting for daemon to start".into());
        }

        delay = (delay * 2).min(Duration::from_millis(500));
    }
}

// ---------------------------------------------------------------------------
// Trace CLI implementations
// ---------------------------------------------------------------------------

/// Implements `ct trace query`.
///
/// Reads the script (from a file or inline `-c`), connects to the daemon,
/// sends `ct/exec-script`, and prints the result.
async fn run_trace_query(
    trace_path: &std::path::Path,
    script_file: Option<&std::path::Path>,
    code: Option<&str>,
    timeout_secs: u64,
    session_id: Option<&str>,
    daemon_socket_path: &PathBuf,
    daemon_pid_path: &PathBuf,
) -> Result<(), Box<dyn Error>> {
    // Determine the script content.
    let script = match (script_file, code) {
        (_, Some(inline)) => inline.to_string(),
        (Some(path), None) => std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read script file '{}': {e}", path.display()))?,
        (None, None) => {
            // No script file or inline code — read from stdin.
            // This enables shell HEREDOC syntax:
            //   ct trace query /path <<'PYEOF'
            //   trace.step_over()
            //   print(trace.location)
            //   PYEOF
            use std::io::{IsTerminal, Read};
            if std::io::stdin().is_terminal() {
                eprintln!(
                    "error: no script provided.\n\n\
                     Usage:\n  \
                     ct trace query <trace> script.py\n  \
                     ct trace query <trace> -c 'print(trace.location)'\n  \
                     ct trace query <trace> <<'PYEOF'\n  \
                     trace.step_over()\n  \
                     print(trace.location)\n  \
                     PYEOF"
                );
                std::process::exit(1);
            }
            let mut buf = String::new();
            std::io::stdin()
                .read_to_string(&mut buf)
                .map_err(|e| format!("failed to read script from stdin: {e}"))?;
            if buf.trim().is_empty() {
                eprintln!("error: stdin was empty (no script to execute)");
                std::process::exit(1);
            }
            buf
        }
    };

    let mut stream = ensure_daemon_connected(daemon_socket_path, daemon_pid_path).await?;

    let trace_path_str = trace_path
        .canonicalize()
        .unwrap_or_else(|_| trace_path.to_path_buf())
        .to_string_lossy()
        .to_string();

    // Send ct/exec-script request.
    //
    // Use a generous timeout for the DAP-level response — the script
    // timeout is enforced by the daemon, and we need to wait at least
    // that long plus overhead for trace opening.
    let resp = cli_dap_request(
        &mut stream,
        "ct/exec-script",
        1,
        json!({
            "tracePath": trace_path_str,
            "script": script,
            "timeout": timeout_secs,
            "sessionId": session_id,
        }),
        timeout_secs + 30, // daemon-side timeout + overhead for open-trace
    )
    .await?;

    if resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        eprintln!("error: {message}");
        std::process::exit(1);
    }

    let body = resp.get("body").cloned().unwrap_or(json!({}));
    let stdout = body.get("stdout").and_then(Value::as_str).unwrap_or("");
    let stderr = body.get("stderr").and_then(Value::as_str).unwrap_or("");
    let exit_code = body.get("exitCode").and_then(Value::as_i64).unwrap_or(0);
    let timed_out = body
        .get("timedOut")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    // Print stdout to the terminal.
    if !stdout.is_empty() {
        print!("{stdout}");
    }

    // Print stderr to the terminal's stderr.
    if !stderr.is_empty() {
        eprint!("{stderr}");
    }

    if timed_out {
        eprintln!("error: script execution timed out after {timeout_secs} seconds");
    }

    if exit_code != 0 {
        std::process::exit(exit_code as i32);
    }

    Ok(())
}

/// Implements `ct trace query --session-close`.
///
/// Connects to the daemon and sends `ct/close-trace` to explicitly
/// tear down a session and kill the backend process.
async fn run_session_close(
    trace_path: &std::path::Path,
    daemon_socket_path: &PathBuf,
    daemon_pid_path: &PathBuf,
) -> Result<(), Box<dyn Error>> {
    let mut stream = ensure_daemon_connected(daemon_socket_path, daemon_pid_path).await?;

    let trace_path_str = trace_path
        .canonicalize()
        .unwrap_or_else(|_| trace_path.to_path_buf())
        .to_string_lossy()
        .to_string();

    let resp = cli_dap_request(
        &mut stream,
        "ct/close-trace",
        1,
        json!({"tracePath": trace_path_str}),
        10,
    )
    .await?;

    if resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        eprintln!("error: {message}");
        std::process::exit(1);
    }

    eprintln!("Session closed.");
    Ok(())
}

/// Implements `ct trace info`.
///
/// Connects to the daemon, opens the trace (if not already open), sends
/// `ct/trace-info`, and pretty-prints the metadata.
async fn run_trace_info(
    trace_path: &std::path::Path,
    daemon_socket_path: &PathBuf,
    daemon_pid_path: &PathBuf,
) -> Result<(), Box<dyn Error>> {
    let mut stream = ensure_daemon_connected(daemon_socket_path, daemon_pid_path).await?;

    let trace_path_str = trace_path
        .canonicalize()
        .unwrap_or_else(|_| trace_path.to_path_buf())
        .to_string_lossy()
        .to_string();

    // First, open the trace so that trace-info has session data to return.
    let open_resp = cli_dap_request(
        &mut stream,
        "ct/open-trace",
        1,
        json!({"tracePath": trace_path_str}),
        30,
    )
    .await?;

    if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = open_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("failed to open trace");
        eprintln!("error: {message}");
        std::process::exit(1);
    }

    // Now query trace-info.
    let info_resp = cli_dap_request(
        &mut stream,
        "ct/trace-info",
        2,
        json!({"tracePath": trace_path_str}),
        10,
    )
    .await?;

    if info_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = info_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("failed to get trace info");
        eprintln!("error: {message}");
        std::process::exit(1);
    }

    let body = info_resp.get("body").cloned().unwrap_or(json!({}));

    // Pretty-print in table format.
    println!("Trace Information");
    println!("=================");
    println!();
    if let Some(path) = body.get("tracePath").and_then(Value::as_str) {
        println!("  Path:          {path}");
    }
    if let Some(lang) = body.get("language").and_then(Value::as_str) {
        println!("  Language:      {lang}");
    }
    if let Some(events) = body.get("totalEvents").and_then(Value::as_u64) {
        println!("  Total events:  {events}");
    }
    if let Some(program) = body.get("program").and_then(Value::as_str) {
        println!("  Program:       {program}");
    }
    if let Some(workdir) = body.get("workdir").and_then(Value::as_str) {
        println!("  Working dir:   {workdir}");
    }
    if let Some(files) = body.get("sourceFiles").and_then(Value::as_array) {
        println!("  Source files:  ({} files)", files.len());
        for file in files {
            if let Some(path) = file.as_str() {
                println!("    - {path}");
            }
        }
    }
    println!();

    Ok(())
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
    // Trace subcommands (ct trace query / ct trace info)
    // ------------------------------------------------------------------
    if let Some(Commands::Trace { action }) = &cli.command {
        flexi_logger::init();
        match action {
            TraceAction::Query {
                trace_path,
                script_file,
                code,
                timeout,
                session,
                session_close,
            } => {
                if let Some(_close_id) = session_close {
                    return run_session_close(trace_path, &daemon_socket_path, &daemon_pid_path)
                        .await;
                }
                return run_trace_query(
                    trace_path,
                    script_file.as_deref(),
                    code.as_deref(),
                    *timeout,
                    session.as_deref(),
                    &daemon_socket_path,
                    &daemon_pid_path,
                )
                .await;
            }
            TraceAction::Info { trace_path } => {
                return run_trace_info(trace_path, &daemon_socket_path, &daemon_pid_path).await;
            }
            TraceAction::Mcp => {
                // MCP server: redirect all logging to stderr only.
                // stdout is reserved exclusively for JSON-RPC transport.
                if let Err(e) = flexi_logger::Logger::try_with_str("info")
                    .and_then(|l| l.log_to_stderr().start())
                {
                    eprintln!("Warning: could not configure MCP logging: {e}");
                }
                let config = mcp_server::McpServerConfig {
                    daemon_socket_path: daemon_socket_path.clone(),
                    daemon_pid_path: daemon_pid_path.clone(),
                };
                return mcp_server::run_mcp_server(config).await;
            }
        }
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
