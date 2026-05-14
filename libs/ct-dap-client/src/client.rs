use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use log::info;
use serde_json::{json, Value};

use crate::protocol::{DapMessage, Event, ProtocolMessage, Request, Response};
use crate::transport::{read_dap_message, write_dap_message};
use crate::types::*;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// A DAP client that communicates with db-backend over stdio.
pub struct DapStdioClient {
    child: Child,
    writer: ChildStdin,
    rx: Receiver<Result<DapMessage, String>>,
    _reader_thread: JoinHandle<()>,
    _stderr_thread: JoinHandle<()>,
    stderr_lines: Arc<Mutex<Vec<String>>>,
    seq: i64,
}

impl DapStdioClient {
    /// Spawn a db-backend process and set up DAP communication over stdio.
    ///
    /// db-backend (and the ct-native-replay replay-worker it spawns) reads
    /// the daily-free-tier license counter from `$XDG_DATA_HOME/codetracer/state.db`.
    /// Without isolation, every test invocation increments the developer's
    /// real `~/.local/share/codetracer/state.db`; once the daily quota is
    /// exhausted, the replay-worker exits with
    /// `daily_replay_limit_reached`, which surfaces in the DAP layer as a
    /// db-backend startup timeout. Point XDG_DATA_HOME at a per-process
    /// temp dir so each test run starts with a fresh counter.
    pub fn spawn(db_backend_bin: &Path) -> Result<Self, BoxError> {
        let license_iso_dir = std::env::temp_dir()
            .join(format!("ct_dap_license_iso_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&license_iso_dir);
        let mut child = Command::new(db_backend_bin)
            .arg("dap-server")
            .arg("--stdio")
            .env("XDG_DATA_HOME", &license_iso_dir)
            .env("HOME", &license_iso_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                format!(
                    "Failed to spawn db-backend at {}: {}",
                    db_backend_bin.display(),
                    e
                )
            })?;

        let writer = child
            .stdin
            .take()
            .ok_or("Failed to get stdin of db-backend")?;
        let stdout = child
            .stdout
            .take()
            .ok_or("Failed to get stdout of db-backend")?;
        let stderr = child
            .stderr
            .take()
            .ok_or("Failed to get stderr of db-backend")?;

        let (tx, rx) = mpsc::channel();

        let reader_thread = thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                match read_dap_message(&mut reader) {
                    Ok(msg) => {
                        if tx.send(Ok(msg)).is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Err(e.to_string()));
                        break;
                    }
                }
            }
        });

        // Capture stderr for diagnostics
        let stderr_lines = Arc::new(Mutex::new(Vec::new()));
        let stderr_lines_clone = Arc::clone(&stderr_lines);
        let stderr_thread = thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines() {
                match line {
                    Ok(line) => {
                        info!("db-backend stderr: {}", line);
                        if let Ok(mut lines) = stderr_lines_clone.lock() {
                            lines.push(line);
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        Ok(DapStdioClient {
            child,
            writer,
            rx,
            _reader_thread: reader_thread,
            _stderr_thread: stderr_thread,
            stderr_lines,
            seq: 1,
        })
    }

    /// Disconnect and kill the db-backend process.
    pub fn disconnect(mut self) -> Result<(), BoxError> {
        // Send disconnect request, ignore errors (process may already be gone)
        let _ = self.send_request("disconnect", json!({}));
        // Give it a moment then kill
        std::thread::sleep(Duration::from_millis(100));
        let _ = self.child.kill();
        let _ = self.child.wait();
        Ok(())
    }

    // === DAP initialization sequence ===

    /// Send initialize request and return capabilities.
    pub fn initialize(&mut self) -> Result<Capabilities, BoxError> {
        self.send_request(
            "initialize",
            json!({
                "clientID": "ct-dap-client",
                "clientName": "ct-dap-client",
                "adapterID": "codetracer",
                "pathFormat": "path",
                "linesStartAt1": true,
                "columnsStartAt1": true
            }),
        )?;

        let resp = self.recv_response(Duration::from_secs(10))?;
        if !resp.success {
            return Err(format!("initialize failed: {:?}", resp.message).into());
        }

        let caps: Capabilities = serde_json::from_value(resp.body)?;
        Ok(caps)
    }

    /// Send launch request with the given arguments.
    pub fn launch(&mut self, args: LaunchRequestArguments) -> Result<(), BoxError> {
        self.send_request("launch", serde_json::to_value(&args)?)?;
        let resp = self.recv_response(Duration::from_secs(10))?;
        if !resp.success {
            return Err(format!("launch failed: {:?}", resp.message).into());
        }
        Ok(())
    }

    /// Send configurationDone request.
    pub fn configuration_done(&mut self) -> Result<(), BoxError> {
        self.send_request("configurationDone", json!({}))?;
        let resp = self.recv_response(Duration::from_secs(10))?;
        if !resp.success {
            return Err(format!("configurationDone failed: {:?}", resp.message).into());
        }
        Ok(())
    }

    /// Wait for a `stopped` event (emitted after configurationDone + runToEntry).
    pub fn wait_for_stopped(&mut self, timeout: Duration) -> Result<(), BoxError> {
        let start = std::time::Instant::now();
        let deadline = start + timeout;
        let mut received_events: Vec<String> = Vec::new();

        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                let stderr = self.recent_stderr(20);
                let elapsed = start.elapsed().as_secs_f64();
                let mut msg = format!("Timeout after {:.1}s waiting for event 'stopped'", elapsed);
                if !received_events.is_empty() {
                    msg.push_str(&format!(
                        "\n  Events received while waiting: {:?}",
                        received_events
                    ));
                } else {
                    msg.push_str("\n  No events received from db-backend");
                }
                if !stderr.is_empty() {
                    msg.push_str(&format!(
                        "\n  db-backend stderr (last {} lines):\n    {}",
                        stderr.len(),
                        stderr.join("\n    ")
                    ));
                }
                // Check if db-backend process is still alive
                if let Some(status) = self.child.try_wait().ok().flatten() {
                    msg.push_str(&format!("\n  db-backend process EXITED with: {}", status));
                } else {
                    msg.push_str("\n  db-backend process is still running");
                }
                return Err(msg.into());
            }
            match self.rx.recv_timeout(remaining) {
                Ok(Ok(DapMessage::Event(e))) => {
                    if e.event == "stopped" {
                        return Ok(());
                    }
                    eprintln!(
                        "[wait_for_stopped] received event '{}' at {:.1}s",
                        e.event,
                        start.elapsed().as_secs_f64()
                    );
                    received_events.push(e.event);
                }
                Ok(Ok(DapMessage::Response(r))) => {
                    received_events.push(format!(
                        "response(seq={}, cmd={})",
                        r.request_seq, r.command
                    ));
                }
                Ok(Ok(other)) => {
                    received_events.push(format!("{:?}", other));
                }
                Ok(Err(e)) => {
                    return Err(format!(
                        "Reader error while waiting for 'stopped': {}\n  elapsed: {:.1}s\n  events so far: {:?}",
                        e,
                        start.elapsed().as_secs_f64(),
                        received_events
                    ).into());
                }
                Err(_) => {
                    // recv_timeout expired, loop will check deadline
                }
            }
        }
    }

    // === Breakpoints ===

    /// Set breakpoints in a source file. Returns the response body.
    pub fn set_breakpoints(&mut self, file: &str, lines: &[usize]) -> Result<Value, BoxError> {
        let breakpoints: Vec<_> = lines.iter().map(|l| json!({"line": l})).collect();
        self.send_request(
            "setBreakpoints",
            json!({
                "source": { "path": file },
                "breakpoints": breakpoints,
            }),
        )?;
        let resp = self.recv_response(Duration::from_secs(10))?;
        if !resp.success {
            return Err(format!("setBreakpoints failed: {:?}", resp.message).into());
        }
        Ok(resp.body)
    }

    // === DAP continue ===

    /// Send standard DAP "continue", wait for stopped + ct/complete-move,
    /// then consume the trailing response.
    ///
    /// Returns the MoveState from ct/complete-move.
    ///
    /// db-backend's step handler sends events first (stopped,
    /// ct/complete-move) and then a response.  We must consume all three
    /// so later `recv_response` calls don't pick up a stale response
    /// belonging to this `continue` request.
    pub fn dap_continue(&mut self) -> Result<MoveState, BoxError> {
        self.send_request("continue", json!({"threadId": 1}))?;
        self.wait_for_stopped(Duration::from_secs(10))?;
        let event = self.recv_event("ct/complete-move", Duration::from_secs(10))?;
        let state: MoveState = serde_json::from_value(event.body)?;
        // Consume the trailing response sent by the step handler
        // (body is typically `0`).  Ignore errors — the response may
        // have been consumed by recv_event's skip logic if it arrived
        // before the events.
        let _ = self.recv_response(Duration::from_secs(5));
        Ok(state)
    }

    // === Flow ===

    /// Load flow data. Sends ct/load-flow, waits for ct/updated-flow event.
    /// Returns the raw event body (caller parses as needed).
    pub fn load_flow(&mut self, args: LoadFlowArguments) -> Result<Value, BoxError> {
        self.send_request("ct/load-flow", serde_json::to_value(&args)?)?;
        // TTD flow computation in CDB mode spawns a new CDB process per
        // operation (step, load_location, load_value), so the flow loop
        // for even a small function can take several minutes.
        let event = self.recv_event("ct/updated-flow", Duration::from_secs(10))?;
        Ok(event.body)
    }

    // === Tracepoints ===

    /// Run tracepoints and collect results.
    ///
    /// Sends `ct/run-tracepoints`, then waits for a `ct/tracepoint-results`
    /// event carrying the aggregate results. Note: this request does not
    /// produce a DAP response — only events (trace updates + results).
    pub fn run_tracepoints(
        &mut self,
        args: RunTracepointsArg,
    ) -> Result<TracepointResultsAggregate, BoxError> {
        self.send_request("ct/run-tracepoints", serde_json::to_value(&args)?)?;

        // Wait for the aggregate results event (skips intermediate trace update events)
        let event = self.recv_event("ct/tracepoint-results", Duration::from_secs(10))?;
        let results: TracepointResultsAggregate = serde_json::from_value(event.body)?;
        Ok(results)
    }

    // === Terminal output ===

    /// Load terminal output.
    pub fn load_terminal(&mut self) -> Result<Vec<ProgramEvent>, BoxError> {
        self.send_request("ct/load-terminal", json!({}))?;
        let event = self.recv_event("ct/loaded-terminal", Duration::from_secs(10))?;
        let events: Vec<ProgramEvent> = serde_json::from_value(event.body)?;
        Ok(events)
    }

    // === Call stack ===

    /// Request the current call stack (standard DAP stackTrace).
    ///
    /// Returns a `StackTraceResult` containing the stack frames and the
    /// total frame count as reported by the server.
    pub fn stack_trace(&mut self) -> Result<StackTraceResult, BoxError> {
        self.send_request(
            "stackTrace",
            json!({
                "threadId": 1,
            }),
        )?;
        let resp = self.recv_response(Duration::from_secs(10))?;
        if !resp.success {
            return Err(format!("stackTrace failed: {:?}", resp.message).into());
        }
        let result: StackTraceResult = serde_json::from_value(resp.body)?;
        Ok(result)
    }

    // === Navigation ===

    /// Step in (forward) using the custom ct/step protocol.
    pub fn step_in(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        self.send_step("ct/step", args)
    }

    /// Step over (forward) using the custom ct/step protocol.
    pub fn step_over(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        let mut step_args = args;
        step_args.action = Action::Next;
        self.send_step("ct/step", step_args)
    }

    /// Continue forward using the custom ct/step protocol.
    pub fn continue_forward(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        let mut step_args = args;
        step_args.action = Action::Continue;
        self.send_step("ct/step", step_args)
    }

    /// Step in backward (reverse step).
    pub fn step_back(&mut self) -> Result<MoveState, BoxError> {
        self.send_step("ct/step", StepArg::new(Action::StepIn, true))
    }

    /// Continue backward (reverse continue).
    pub fn continue_back(&mut self) -> Result<MoveState, BoxError> {
        self.send_step("ct/step", StepArg::new(Action::Continue, true))
    }

    fn send_step(&mut self, command: &str, args: StepArg) -> Result<MoveState, BoxError> {
        self.send_request(command, serde_json::to_value(&args)?)?;
        let event = self.recv_event("ct/complete-move", Duration::from_secs(30))?;
        let state: MoveState = serde_json::from_value(event.body)?;
        Ok(state)
    }

    /// Send a standard DAP step command (`next`, `stepIn`, `stepOut`)
    /// and wait for the stopped + ct/complete-move events, then consume
    /// the trailing response.
    ///
    /// Unlike `step_in`/`step_over` (which use the custom `ct/step`
    /// protocol for socket-based connections), this method uses the
    /// standard DAP command names that the stdio-based server expects.
    pub fn dap_step(&mut self, command: &str) -> Result<MoveState, BoxError> {
        self.send_request(command, json!({"threadId": 1}))?;
        self.wait_for_stopped(Duration::from_secs(10))?;
        let event = self.recv_event("ct/complete-move", Duration::from_secs(10))?;
        let state: MoveState = serde_json::from_value(event.body)?;
        // Consume the trailing response sent by the step handler.
        let _ = self.recv_response(Duration::from_secs(5));
        Ok(state)
    }

    // === Low-level send/receive ===

    /// Send a DAP request with the given command and arguments.
    pub fn send_request(&mut self, command: &str, arguments: Value) -> Result<i64, BoxError> {
        let seq = self.next_seq();
        let msg = DapMessage::Request(Request {
            base: ProtocolMessage {
                seq,
                type_: "request".to_string(),
            },
            command: command.to_string(),
            arguments,
        });
        write_dap_message(&mut self.writer, &msg)?;
        info!("DAP -> {} (seq={})", command, seq);
        Ok(seq)
    }

    /// Receive the next response, skipping events.
    pub fn recv_response(&mut self, timeout: Duration) -> Result<Response, BoxError> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err("Timeout waiting for response".into());
            }
            match self.rx.recv_timeout(remaining) {
                Ok(Ok(DapMessage::Response(r))) => return Ok(r),
                Ok(Ok(DapMessage::Event(e))) => {
                    info!("DAP <- event: {} (while waiting for response)", e.event);
                    continue;
                }
                Ok(Ok(other)) => {
                    info!(
                        "DAP <- unexpected message while waiting for response: {:?}",
                        other
                    );
                    continue;
                }
                Ok(Err(e)) => return Err(format!("Reader error: {}", e).into()),
                Err(_) => return Err("Timeout waiting for response".into()),
            }
        }
    }

    /// Receive a specific named event, skipping other messages.
    pub fn recv_event(&mut self, event_name: &str, timeout: Duration) -> Result<Event, BoxError> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err(format!("Timeout waiting for event '{}'", event_name).into());
            }
            match self.rx.recv_timeout(remaining) {
                Ok(Ok(DapMessage::Event(e))) => {
                    if e.event == event_name {
                        return Ok(e);
                    }
                    info!("DAP <- event: {} (waiting for {})", e.event, event_name);
                    continue;
                }
                Ok(Ok(DapMessage::Response(r))) => {
                    info!(
                        "DAP <- response (seq={}) while waiting for event '{}'",
                        r.request_seq, event_name
                    );
                    continue;
                }
                Ok(Ok(other)) => {
                    info!(
                        "DAP <- unexpected message while waiting for event '{}': {:?}",
                        event_name, other
                    );
                    continue;
                }
                Ok(Err(e)) => return Err(format!("Reader error: {}", e).into()),
                Err(_) => return Err(format!("Timeout waiting for event '{}'", event_name).into()),
            }
        }
    }

    /// Receive the next message of any type.
    pub fn recv_message(&mut self, timeout: Duration) -> Result<DapMessage, BoxError> {
        match self.rx.recv_timeout(timeout) {
            Ok(Ok(msg)) => Ok(msg),
            Ok(Err(e)) => Err(format!("Reader error: {}", e).into()),
            Err(_) => Err("Timeout waiting for message".into()),
        }
    }

    /// Get recent stderr output from db-backend (last N lines).
    pub fn recent_stderr(&self, max_lines: usize) -> Vec<String> {
        if let Ok(lines) = self.stderr_lines.lock() {
            let start = lines.len().saturating_sub(max_lines);
            lines[start..].to_vec()
        } else {
            vec![]
        }
    }

    fn next_seq(&mut self) -> i64 {
        let current = self.seq;
        self.seq += 1;
        current
    }
}
