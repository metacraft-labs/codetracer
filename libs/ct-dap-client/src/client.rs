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
    pub fn spawn(db_backend_bin: &Path) -> Result<Self, BoxError> {
        let mut child = Command::new(db_backend_bin)
            .arg("dap-server")
            .arg("--stdio")
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

        let resp = self.recv_response(Duration::from_secs(30))?;
        if !resp.success {
            return Err(format!("initialize failed: {:?}", resp.message).into());
        }

        let caps: Capabilities = serde_json::from_value(resp.body)?;
        Ok(caps)
    }

    /// Send launch request with the given arguments.
    pub fn launch(&mut self, args: LaunchRequestArguments) -> Result<(), BoxError> {
        self.send_request("launch", serde_json::to_value(&args)?)?;
        let resp = self.recv_response(Duration::from_secs(30))?;
        if !resp.success {
            return Err(format!("launch failed: {:?}", resp.message).into());
        }
        Ok(())
    }

    /// Send configurationDone request.
    pub fn configuration_done(&mut self) -> Result<(), BoxError> {
        self.send_request("configurationDone", json!({}))?;
        let resp = self.recv_response(Duration::from_secs(30))?;
        if !resp.success {
            return Err(format!("configurationDone failed: {:?}", resp.message).into());
        }
        Ok(())
    }

    /// Wait for a `stopped` event (emitted after configurationDone + runToEntry).
    pub fn wait_for_stopped(&mut self, timeout: Duration) -> Result<(), BoxError> {
        match self.recv_event("stopped", timeout) {
            Ok(_) => Ok(()),
            Err(e) => {
                let stderr = self.recent_stderr(20);
                if stderr.is_empty() {
                    Err(e)
                } else {
                    Err(format!(
                        "{}\n  db-backend stderr (last {} lines):\n    {}",
                        e,
                        stderr.len(),
                        stderr.join("\n    ")
                    )
                    .into())
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
        let resp = self.recv_response(Duration::from_secs(30))?;
        if !resp.success {
            return Err(format!("setBreakpoints failed: {:?}", resp.message).into());
        }
        Ok(resp.body)
    }

    // === DAP continue ===

    /// Send standard DAP "continue", wait for stopped + ct/complete-move.
    /// Returns the MoveState from ct/complete-move.
    ///
    /// Note: db-backend does not send a response for `continue` — only events
    /// (stopped + ct/complete-move), so we skip recv_response here.
    pub fn dap_continue(&mut self) -> Result<MoveState, BoxError> {
        self.send_request("continue", json!({"threadId": 1}))?;
        self.wait_for_stopped(Duration::from_secs(60))?;
        let event = self.recv_event("ct/complete-move", Duration::from_secs(10))?;
        let state: MoveState = serde_json::from_value(event.body)?;
        Ok(state)
    }

    // === Flow ===

    /// Load flow data. Sends ct/load-flow, waits for ct/updated-flow event.
    /// Returns the raw event body (caller parses as needed).
    pub fn load_flow(&mut self, args: LoadFlowArguments) -> Result<Value, BoxError> {
        self.send_request("ct/load-flow", serde_json::to_value(&args)?)?;
        let event = self.recv_event("ct/updated-flow", Duration::from_secs(60))?;
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
        let event = self.recv_event("ct/tracepoint-results", Duration::from_secs(120))?;
        let results: TracepointResultsAggregate = serde_json::from_value(event.body)?;
        Ok(results)
    }

    // === Terminal output ===

    /// Load terminal output.
    pub fn load_terminal(&mut self) -> Result<Vec<ProgramEvent>, BoxError> {
        self.send_request("ct/load-terminal", json!({}))?;
        let event = self.recv_event("ct/loaded-terminal", Duration::from_secs(30))?;
        let events: Vec<ProgramEvent> = serde_json::from_value(event.body)?;
        Ok(events)
    }

    // === Navigation ===

    /// Step in (forward).
    pub fn step_in(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        self.send_step("ct/step", args)
    }

    /// Step over (forward).
    pub fn step_over(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        let mut step_args = args;
        step_args.action = Action::Next;
        self.send_step("ct/step", step_args)
    }

    /// Continue forward.
    pub fn continue_forward(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        let mut step_args = args;
        step_args.action = Action::Continue;
        self.send_step("ct/step", step_args)
    }

    fn send_step(&mut self, command: &str, args: StepArg) -> Result<MoveState, BoxError> {
        self.send_request(command, serde_json::to_value(&args)?)?;
        let event = self.recv_event("ct/complete-move", Duration::from_secs(30))?;
        let state: MoveState = serde_json::from_value(event.body)?;
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
